//// Versioned, application-neutral delivery envelopes.
//// Payloads are application-encoded strings. This module checks transport and
//// sequence invariants; it does not interpret the application's model.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import retrace

pub type Session {
  Session(
    id: String,
    user_ref: String,
    build: String,
    contract: String,
    platform: String,
  )
}

pub type Event {
  Event(kind: String, payload: String)
}

pub type Batch {
  Batch(
    session: Session,
    checkpoint: retrace.Checkpoint(String),
    entries: List(retrace.Entry(Event)),
  )
}

pub type Error {
  MalformedEnvelope
  InvalidSession
  EmptyBatch
  TooManyEntries
  TooLarge
  InvalidHistory(retrace.Error(Nil))
}

pub const max_bytes = 1_048_576

pub const max_entries = 128

pub fn origin(session: Session) -> retrace.Origin {
  retrace.Origin(session.id, session.contract)
}

pub fn valid_id(id: String) -> Bool {
  string.byte_size(id) > 0
  && string.byte_size(id) <= 128
  && list.all(string.to_graphemes(id), fn(c) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_",
      c,
    )
  })
}

fn valid_text(value: String) -> Bool {
  string.byte_size(value) > 0 && string.byte_size(value) <= 256
}

pub fn validate(batch: Batch) -> Result(Nil, Error) {
  case
    valid_id(batch.session.id)
    && valid_text(batch.session.user_ref)
    && valid_text(batch.session.build)
    && valid_text(batch.session.contract)
    && valid_text(batch.session.platform)
    && batch.checkpoint.origin == origin(batch.session)
  {
    False -> Error(InvalidSession)
    True -> {
      use player <- result.try(
        retrace.replay(
          batch.checkpoint,
          batch.session.contract,
          fn(model: String, _: Event) -> Result(String, Nil) { Ok(model) },
        )
        |> result.map_error(InvalidHistory),
      )
      case batch.entries {
        [] -> Error(EmptyBatch)
        entries ->
          case list.length(entries) > max_entries {
            True -> Error(TooManyEntries)
            False -> {
              use _ <- result.try(
                list.try_fold(entries, player, fn(player, entry) {
                  case valid_text(entry.event.kind) {
                    False -> Error(InvalidSession)
                    True ->
                      retrace.step(player, entry)
                      |> result.map_error(InvalidHistory)
                  }
                }),
              )
              case string.byte_size(encode(batch)) <= max_bytes {
                True -> Ok(Nil)
                False -> Error(TooLarge)
              }
            }
          }
      }
    }
  }
}

pub fn end_sequence(batch: Batch) -> Int {
  batch.checkpoint.sequence + list.length(batch.entries)
}

pub fn end_time(batch: Batch) -> Int {
  case list.last(batch.entries) {
    Ok(entry) -> entry.elapsed_ms
    Error(Nil) -> batch.checkpoint.elapsed_ms
  }
}

pub fn session_json(session: Session) -> json.Json {
  json.object([
    #("id", json.string(session.id)),
    #("user_ref", json.string(session.user_ref)),
    #("build", json.string(session.build)),
    #("contract", json.string(session.contract)),
    #("platform", json.string(session.platform)),
  ])
}

pub fn encode(batch: Batch) -> String {
  json.object([
    #("format", json.int(1)),
    #("session", session_json(batch.session)),
    #(
      "checkpoint",
      json.object([
        #("sequence", json.int(batch.checkpoint.sequence)),
        #("elapsed_ms", json.int(batch.checkpoint.elapsed_ms)),
        #("model", json.string(batch.checkpoint.model)),
      ]),
    ),
    #(
      "entries",
      json.array(batch.entries, fn(entry) {
        json.object([
          #("sequence", json.int(entry.sequence)),
          #("elapsed_ms", json.int(entry.elapsed_ms)),
          #("kind", json.string(entry.event.kind)),
          #("payload", json.string(entry.event.payload)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

pub fn session_decoder() -> decode.Decoder(Session) {
  use id <- decode.field("id", decode.string)
  use user_ref <- decode.field("user_ref", decode.string)
  use build <- decode.field("build", decode.string)
  use contract <- decode.field("contract", decode.string)
  use platform <- decode.field("platform", decode.string)
  decode.success(Session(id, user_ref, build, contract, platform))
}

fn checkpoint_decoder(
  origin: retrace.Origin,
) -> decode.Decoder(retrace.Checkpoint(String)) {
  use sequence <- decode.field("sequence", decode.int)
  use elapsed <- decode.field("elapsed_ms", decode.int)
  use model <- decode.field("model", decode.string)
  decode.success(retrace.Checkpoint(origin, sequence, elapsed, model))
}

fn entry_decoder(
  origin: retrace.Origin,
) -> decode.Decoder(retrace.Entry(Event)) {
  use sequence <- decode.field("sequence", decode.int)
  use elapsed <- decode.field("elapsed_ms", decode.int)
  use kind <- decode.field("kind", decode.string)
  use payload <- decode.field("payload", decode.string)
  decode.success(retrace.Entry(origin, sequence, elapsed, Event(kind, payload)))
}

pub fn decode_batch(input: String) -> Result(Batch, Error) {
  case string.byte_size(input) > max_bytes {
    True -> Error(TooLarge)
    False -> {
      let decoder = {
        use format <- decode.field("format", decode.int)
        use session <- decode.field("session", session_decoder())
        use checkpoint <- decode.field(
          "checkpoint",
          checkpoint_decoder(origin(session)),
        )
        use entries <- decode.field(
          "entries",
          decode.list(entry_decoder(origin(session))),
        )
        case format {
          1 -> decode.success(Batch(session, checkpoint, entries))
          _ ->
            decode.failure(Batch(session, checkpoint, []), "retrace format 1")
        }
      }
      use batch <- result.try(
        json.parse(input, decoder)
        |> result.map_error(fn(_) { MalformedEnvelope }),
      )
      use _ <- result.try(validate(batch))
      Ok(batch)
    }
  }
}
