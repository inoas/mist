import gleam/bit_builder.{BitBuilder}
import gleam/bit_string
import gleam/list
import gleam/option.{None, Option, Some}
import gleam/otp/process.{Sender}
import gleam/string
import glisten/tcp.{HandlerMessage, Socket}

pub type Message {
  BinaryMessage(data: BitString)
  TextMessage(data: String)
}

pub type Handler =
  fn(Message, Sender(HandlerMessage)) -> Result(Nil, Nil)

// TODO:  there are other message types, AND ALSO will need to buffer across
// multiple frames, potentially
pub type Frame {
  // TODO:  should this include data?
  CloseFrame(payload_length: Int, payload: BitString)
  TextFrame(payload_length: Int, payload: BitString)
  BinaryFrame(payload_length: Int, payload: BitString)
  // We don't care about basicaly everything else for now
  PingFrame(payload_length: Int, payload: BitString)
  PongFrame(payload_length: Int, payload: BitString)
}

external fn crypto_exor(a: BitString, b: BitString) -> BitString =
  "crypto" "exor"

fn unmask_data(
  data: BitString,
  masks: List(BitString),
  index: Int,
  resp: BitString,
) -> BitString {
  case data {
    <<>> -> resp
    <<masked:bit_string-size(8), rest:bit_string>> -> {
      assert Ok(mask_value) = list.at(masks, index % 4)
      let unmasked = crypto_exor(mask_value, masked)
      unmask_data(
        rest,
        masks,
        index + 1,
        <<resp:bit_string, unmasked:bit_string>>,
      )
    }
  }
}

pub fn frame_from_message(
  socket: Socket,
  message: BitString,
) -> Result(Frame, Nil) {
  assert <<_fin:1, rest:bit_string>> = message
  assert <<_reserved:3, rest:bit_string>> = rest
  assert <<opcode:int-size(4), rest:bit_string>> = rest
  case opcode {
    1 | 2 -> {
      // mask
      assert <<1:1, rest:bit_string>> = rest
      assert <<payload_length:int-size(7), rest:bit_string>> = rest
      let #(payload_length, rest) = case payload_length {
        126 -> {
          assert <<length:int-size(16), rest:bit_string>> = rest
          #(length, rest)
        }
        127 -> {
          assert <<length:int-size(64), rest:bit_string>> = rest
          #(length, rest)
        }
        _ -> #(payload_length, rest)
      }
      assert <<
        mask1:bit_string-size(8),
        mask2:bit_string-size(8),
        mask3:bit_string-size(8),
        mask4:bit_string-size(8),
        rest:bit_string,
      >> = rest
      let data = case payload_length - bit_string.byte_size(rest) {
        0 -> unmask_data(rest, [mask1, mask2, mask3, mask4], 0, <<>>)
        need -> {
          assert Ok(needed) = tcp.receive(socket, need)
          rest
          |> bit_string.append(needed)
          |> unmask_data([mask1, mask2, mask3, mask4], 0, <<>>)
        }
      }
      case opcode {
        1 -> TextFrame(payload_length, data)
        2 -> BinaryFrame(payload_length, data)
      }
      |> Ok
    }
    8 -> Ok(CloseFrame(payload_length: 0, payload: <<>>))
  }
}

pub fn frame_to_bit_builder(frame: Frame) -> BitBuilder {
  case frame {
    TextFrame(payload_length, payload) -> make_frame(1, payload_length, payload)
    CloseFrame(payload_length, payload) ->
      make_frame(8, payload_length, payload)
    BinaryFrame(payload_length, payload) ->
      make_frame(2, payload_length, payload)
    PongFrame(payload_length, payload) ->
      make_frame(10, payload_length, payload)
    PingFrame(..) -> bit_builder.from_bit_string(<<>>)
  }
}

fn make_frame(opcode: Int, length: Int, payload: BitString) -> BitBuilder {
  let length_section = case length {
    length if length > 65535 -> <<127:7, length:int-size(64)>>
    length if length >= 126 -> <<126:7, length:int-size(16)>>
    _length -> <<length:7>>
  }

  <<1:1, 0:3, opcode:4, 0:1, length_section:bit_string, payload:bit_string>>
  |> bit_builder.from_bit_string
}

fn to_text_frame(data: BitString) -> BitBuilder {
  let size = bit_string.byte_size(data)
  frame_to_bit_builder(TextFrame(size, data))
}

fn to_binary_frame(data: BitString) -> BitBuilder {
  let size = bit_string.byte_size(data)
  frame_to_bit_builder(BinaryFrame(size, data))
}

const websocket_key = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

pub type ShaHash {
  Sha
}

pub external fn crypto_hash(hash: ShaHash, data: String) -> String =
  "crypto" "hash"

pub external fn base64_encode(data: String) -> String =
  "base64" "encode"

pub fn parse_key(key: String) -> String {
  key
  |> string.append(websocket_key)
  |> crypto_hash(Sha, _)
  |> base64_encode
}

/// Helper to encapsulate the logic to send a provided message over the
/// WebSocket
pub fn send(sender: Sender(HandlerMessage), message: Message) -> Nil {
  case message {
    TextMessage(data) ->
      data
      |> bit_string.from_string
      |> to_text_frame
    BinaryMessage(data) -> to_binary_frame(data)
  }
  |> tcp.SendMessage
  |> process.send(sender, _)

  Nil
}

pub fn echo_handler(
  message: Message,
  sender: Sender(HandlerMessage),
) -> Result(Nil, Nil) {
  let _ = send(sender, message)

  Ok(Nil)
}

pub type WebsocketHandler {
  WebsocketHandler(
    on_close: Option(fn(Sender(tcp.HandlerMessage)) -> Nil),
    on_init: Option(fn(Sender(tcp.HandlerMessage)) -> Nil),
    handler: Handler,
  )
}

pub fn with_handler(func: Handler) -> WebsocketHandler {
  WebsocketHandler(on_close: None, on_init: None, handler: func)
}

pub fn on_init(
  handler: WebsocketHandler,
  func: fn(Sender(tcp.HandlerMessage)) -> Nil,
) -> WebsocketHandler {
  WebsocketHandler(..handler, on_init: Some(func))
}

pub fn on_close(
  handler: WebsocketHandler,
  func: fn(Sender(tcp.HandlerMessage)) -> Nil,
) -> WebsocketHandler {
  WebsocketHandler(..handler, on_close: Some(func))
}
