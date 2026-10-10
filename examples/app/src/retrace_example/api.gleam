import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import retrace/wire

pub type Summary {
  Summary(session: wire.Session, sequence: Int, pending: Int, archived: Int)
}

pub fn summaries(input: String) -> Result(List(Summary), String) {
  let decoder = {
    use session <- decode.field("session", wire.session_decoder())
    use sequence <- decode.field("sequence", decode.int)
    use pending <- decode.field("pending", decode.int)
    use archived <- decode.field("archived", decode.int)
    decode.success(Summary(session, sequence, pending, archived))
  }
  json.parse(input, decode.list(decoder))
  |> result.map_error(fn(_) { "Invalid session response" })
}

pub fn batches(input: String) -> Result(List(wire.Batch), String) {
  use values <- result.try(
    json.parse(input, decode.list(decode.string))
    |> result.map_error(fn(_) { "Invalid recording response" }),
  )
  list.try_map(values, fn(value) {
    wire.decode_batch(value)
    |> result.map_error(fn(_) { "Invalid stored recording" })
  })
}

@external(javascript, "../example_ffi.mjs", "endpoint")
pub fn endpoint() -> String

@external(javascript, "../example_ffi.mjs", "sessionId")
pub fn session_id() -> String

@external(javascript, "../example_ffi.mjs", "userRef")
pub fn user_ref() -> String

@external(javascript, "../example_ffi.mjs", "platform")
pub fn platform() -> String

@external(javascript, "../example_ffi.mjs", "elapsed")
pub fn elapsed() -> Int

@external(javascript, "../example_ffi.mjs", "sessions")
pub fn fetch_sessions(user: String, callback: fn(Bool, String) -> Nil) -> Nil

@external(javascript, "../example_ffi.mjs", "recording")
pub fn fetch_recording(id: String, callback: fn(Bool, String) -> Nil) -> Nil

@external(javascript, "../example_ffi.mjs", "device")
pub fn device(callback: fn(String) -> Nil) -> Nil
