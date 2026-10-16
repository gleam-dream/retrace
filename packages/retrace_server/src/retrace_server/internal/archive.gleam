//// Versioned archive framing. Original delivery batches are never rechunked.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import retrace/wire

pub const max_bytes = 33_554_432

pub const max_events = 1000

pub fn encode(batches: List(wire.Batch)) -> Result(String, Nil) {
  use bounds <- result.try(validate(batches))
  let header =
    json.object([
      #("archive_format", json.int(2)),
      #("session", wire.session_json(bounds.0)),
      #("start", json.int(bounds.1)),
      #("end", json.int(bounds.2)),
      #("batches", json.int(list.length(batches))),
    ])
    |> json.to_string
  let text = string.join([header, ..list.map(batches, wire.encode)], "\n")
  case string.byte_size(text) <= max_bytes {
    True -> Ok(text)
    False -> Error(Nil)
  }
}

pub fn decode(text: String) -> Result(List(wire.Batch), Nil) {
  use _ <- result.try(case string.byte_size(text) <= max_bytes {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  case string.split(text, "\n") {
    [header, ..lines] -> {
      let decoder = {
        use format <- decode.field("archive_format", decode.int)
        use session <- decode.field("session", wire.session_decoder())
        use start <- decode.field("start", decode.int)
        use end <- decode.field("end", decode.int)
        use count <- decode.field("batches", decode.int)
        decode.success(#(format, session, start, end, count))
      }
      use info <- result.try(
        json.parse(header, decoder) |> result.replace_error(Nil),
      )
      use _ <- result.try(
        case
          info.0 == 2 && info.4 == list.length(lines) && info.4 <= max_events
        {
          True -> Ok(Nil)
          False -> Error(Nil)
        },
      )
      use batches <- result.try(
        list.try_map(lines, fn(line) {
          wire.decode_batch(line) |> result.replace_error(Nil)
        }),
      )
      use bounds <- result.try(validate(batches))
      case bounds == #(info.1, info.2, info.3) {
        True -> Ok(batches)
        False -> Error(Nil)
      }
    }
    [] -> Error(Nil)
  }
}

fn validate(
  batches: List(wire.Batch),
) -> Result(#(wire.Session, Int, Int), Nil) {
  use first <- result.try(list.first(batches))
  use last <- result.try(list.last(batches))
  let start = first.checkpoint.sequence
  let end = wire.end_sequence(last)
  use _ <- result.try(case end > start && end - start <= max_events {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use _ <- result.try(
    list.try_fold(
      batches,
      #(start, first.checkpoint.elapsed_ms),
      fn(cursor, batch) {
        case
          batch.session == first.session
          && batch.checkpoint.sequence == cursor.0
          && batch.checkpoint.elapsed_ms == cursor.1
        {
          True -> Ok(#(wire.end_sequence(batch), wire.end_time(batch)))
          False -> Error(Nil)
        }
      },
    ),
  )
  Ok(#(first.session, start, end))
}
