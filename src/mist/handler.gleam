import gleam/bit_builder.{BitBuilder}
import gleam/bit_string
import gleam/erlang.{Errored, Exited, Thrown, rescue}
import gleam/http/request.{Request}
import gleam/http/response
import gleam/int
import gleam/option.{None, Option, Some}
import gleam/otp/actor
import gleam/otp/process
import gleam/result
import glisten/tcp.{LoopState}
import mist/encoder
import mist/file
import mist/http.{
  BitBuilderBody, Body, DecodeError, DiscardPacket, FileBody, HttpResponseBody,
}
import mist/logger
import mist/websocket

pub type Handler =
  fn(request.Request(BitString)) -> response.Response(BitBuilder)

pub type HandlerResponse {
  Response(response: response.Response(HttpResponseBody))
  Upgrade(websocket.WebsocketHandler)
}

pub type HandlerFunc =
  fn(Request(Body)) -> HandlerResponse

pub type HandlerError {
  InvalidRequest(DecodeError)
  NotFound
}

const stop_normal = actor.Stop(process.Normal)

pub type State {
  State(
    idle_timer: Option(process.Timer),
    upgraded_handler: Option(websocket.WebsocketHandler),
  )
}

pub fn new_state() -> State {
  State(None, None)
}

/// This is a more flexible handler. It will allow you to upgrade a connection
/// to a websocket connection, or deal with a regular HTTP req->resp workflow.
pub fn with_func(handler: HandlerFunc) -> tcp.LoopFn(State) {
  tcp.handler(fn(msg, socket_state: LoopState(State)) {
    let tcp.LoopState(socket, data: state, ..) = socket_state
    case state.upgraded_handler {
      Some(ws_handler) ->
        handle_websocket_message(socket_state, ws_handler, msg)
      None ->
        {
          let _ = case state.idle_timer {
            Some(t) -> process.cancel_timer(t)
            _ -> process.TimerNotFound
          }
          msg
          |> http.parse_request(socket)
          |> result.map_error(fn(err) {
            case err {
              DiscardPacket -> Nil
              _ -> {
                logger.error(err)
                tcp.close(socket)
                Nil
              }
            }
          })
          |> result.replace_error(stop_normal)
          |> result.then(fn(req) {
            rescue(fn() { handler(req) })
            |> result.map(fn(resp) { #(req, resp) })
            |> result.map_error(log_and_error(_, socket_state.socket))
          })
          |> result.map(fn(req_resp) {
            let #(req, response) = req_resp
            case response {
              Response(
                response: response.Response(body: BitBuilderBody(body), ..) as resp,
              ) -> handle_bit_builder_body(resp, body, socket_state)
              Response(
                response: response.Response(body: FileBody(..), ..) as resp,
              ) -> handle_file_body(resp, socket_state)
              Upgrade(with_handler) ->
                handle_upgrade(req, with_handler, socket_state)
            }
          })
        }
        |> result.unwrap_both
    }
  })
}

fn handle_websocket_message(
  state: LoopState(State),
  handler: websocket.WebsocketHandler,
  msg: BitString,
) -> actor.Next(LoopState(State)) {
  case websocket.frame_from_message(state.socket, msg) {
    Ok(websocket.PingFrame(_, _)) -> {
      assert Ok(_) =
        tcp.send(
          state.socket,
          websocket.frame_to_bit_builder(websocket.PongFrame(0, <<>>)),
        )
      actor.Continue(state)
    }
    Ok(websocket.CloseFrame(..) as frame) -> {
      assert Ok(_) =
        tcp.send(state.socket, websocket.frame_to_bit_builder(frame))
      let _ = case handler.on_close {
        Some(func) -> func(state.sender)
        _ -> Nil
      }
      actor.Stop(process.Normal)
    }
    Ok(websocket.PongFrame(..)) -> stop_normal
    Ok(frame) ->
      case frame {
        websocket.TextFrame(_length, payload) -> {
          assert Ok(msg) = bit_string.to_string(payload)
          websocket.TextMessage(msg)
        }
        // NOTE:  this doesn't need to be exhaustive since we already
        // cover the cases above
        _frame -> websocket.BinaryMessage(frame.payload)
      }
      |> fn(ws_msg) { rescue(fn() { handler.handler(ws_msg, state.sender) }) }
      |> result.replace(actor.Continue(state))
      |> result.map_error(fn(err) {
        logger.error(err)
        let _ = case handler.on_close {
          Some(func) -> func(state.sender)
          _ -> Nil
        }
        err
      })
      |> result.replace_error(stop_normal)
      |> result.unwrap_both
    Error(_) -> {
      let _ = case handler.on_close {
        Some(func) -> func(state.sender)
        _ -> Nil
      }
      // TODO:  not normal
      stop_normal
    }
  }
}

fn log_and_error(
  error: erlang.Crash,
  socket: tcp.Socket,
) -> actor.Next(LoopState(State)) {
  case error {
    Exited(msg) | Thrown(msg) | Errored(msg) -> {
      logger.error(error)
      response.new(500)
      |> response.set_body(bit_builder.from_bit_string(<<
        "Internal Server Error":utf8,
      >>))
      |> response.prepend_header("content-length", "21")
      |> encoder.to_bit_builder
      |> tcp.send(socket, _)
      tcp.close(socket)
      actor.Stop(process.Abnormal(msg))
    }
  }
}

fn handle_bit_builder_body(
  resp: response.Response(HttpResponseBody),
  body: BitBuilder,
  state: LoopState(State),
) -> actor.Next(LoopState(State)) {
  resp
  |> response.set_body(body)
  |> encoder.to_bit_builder
  |> tcp.send(state.socket, _)
  |> result.map(fn(_sent) {
    // If the handler explicitly says to close the connection, we should
    // probably listen to them
    case response.get_header(resp, "connection") {
      Ok("close") -> {
        tcp.close(state.socket)
        stop_normal
      }
      _ -> {
        // TODO:  this should be a configuration
        let timer = process.send_after(state.sender, 10_000, tcp.Close)
        actor.Continue(
          LoopState(..state, data: State(..state.data, idle_timer: Some(timer))),
        )
      }
    }
  })
  |> result.replace_error(stop_normal)
  |> result.unwrap_both
}

fn handle_file_body(
  resp: response.Response(HttpResponseBody),
  state: LoopState(State),
) -> actor.Next(LoopState(State)) {
  assert FileBody(file_descriptor, content_type, offset, length) = resp.body
  resp
  |> response.prepend_header("content-length", int.to_string(length - offset))
  |> response.prepend_header("content-type", content_type)
  |> response.set_body(bit_builder.new())
  |> fn(r: response.Response(BitBuilder)) {
    encoder.response_builder(resp.status, r.headers)
  }
  |> tcp.send(state.socket, _)
  |> result.map(fn(_) {
    file.sendfile(file_descriptor, state.socket, offset, length, [])
  })
  |> result.replace(actor.Continue(state))
  // TODO:  not normal
  |> result.replace_error(stop_normal)
  |> result.unwrap_both
}

fn handle_upgrade(
  req: Request(Body),
  handler: websocket.WebsocketHandler,
  state: LoopState(State),
) -> actor.Next(LoopState(State)) {
  req
  |> http.upgrade(state.socket, _)
  |> result.map(fn(_nil) {
    let _ = case handler.on_init {
      Some(func) -> func(state.sender)
      _ -> Nil
    }
  })
  |> result.replace(actor.Continue(
    LoopState(
      ..state,
      data: State(..state.data, upgraded_handler: Some(handler)),
    ),
  ))
  // TODO:  not normal
  |> result.replace_error(stop_normal)
  |> result.unwrap_both
}

/// Creates a standard HTTP handler service to pass to `mist.serve`
pub fn with(handler: Handler, max_body_limit: Int) -> tcp.LoopFn(State) {
  let bad_request =
    response.new(400)
    |> response.set_body(bit_builder.new())
  with_func(fn(req) {
    case
      request.get_header(req, "content-length"),
      request.get_header(req, "transfer-encoding")
    {
      Ok("0"), _ | Error(Nil), Error(Nil) ->
        req
        |> request.set_body(<<>>)
        |> handler
      _, Ok("chunked") ->
        req
        |> http.read_body
        |> result.map(handler)
        |> result.unwrap(bad_request)
      Ok(size), _ ->
        size
        |> int.parse
        |> result.map(fn(size) {
          case size > max_body_limit {
            True ->
              response.new(413)
              |> response.set_body(bit_builder.new())
              |> response.prepend_header("connection", "close")
            False ->
              req
              |> http.read_body
              |> result.map(handler)
              |> result.unwrap(bad_request)
          }
        })
        |> result.unwrap(bad_request)
    }
    |> response.map(BitBuilderBody)
    |> Response
  })
}
