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

/// What a writer states about a session before the server issues its id.
pub type Metadata {
  Metadata(user_ref: String, build: String, contract: String, platform: String)
}

/// A session the server opened, with the capability to append to it. Only the
/// writer that opened the session holds the token; a batch must present it.
pub type Grant {
  Grant(session: Session, token: String)
}

/// One batch presented with its session's write token. The token is never part
/// of the batch, so stored and read batches cannot reveal it.
pub type Upload {
  Upload(token: String, batch: Batch)
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

/// The largest encoded upload: a full batch plus its write token.
pub const max_upload_bytes = 1_049_088

pub fn session(id: String, metadata: Metadata) -> Session {
  Session(
    id,
    metadata.user_ref,
    metadata.build,
    metadata.contract,
    metadata.platform,
  )
}

pub fn metadata(session: Session) -> Metadata {
  Metadata(session.user_ref, session.build, session.contract, session.platform)
}

pub fn validate_metadata(metadata: Metadata) -> Result(Nil, Error) {
  case
    valid_text(metadata.user_ref)
    && valid_text(metadata.build)
    && valid_text(metadata.contract)
    && valid_text(metadata.platform)
  {
    True -> Ok(Nil)
    False -> Error(InvalidSession)
  }
}

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
    && validate_metadata(metadata(batch.session)) == Ok(Nil)
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
  json.object(batch_fields(batch)) |> json.to_string
}

pub fn encode_upload(upload: Upload) -> String {
  json.object([
    #("token", json.string(upload.token)),
    ..batch_fields(upload.batch)
  ])
  |> json.to_string
}

fn batch_fields(batch: Batch) -> List(#(String, json.Json)) {
  [
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
  ]
}

pub fn encode_metadata(metadata: Metadata) -> String {
  json.object([
    #("user_ref", json.string(metadata.user_ref)),
    #("build", json.string(metadata.build)),
    #("contract", json.string(metadata.contract)),
    #("platform", json.string(metadata.platform)),
  ])
  |> json.to_string
}

pub fn decode_metadata(input: String) -> Result(Metadata, Error) {
  let decoder = {
    use user_ref <- decode.field("user_ref", decode.string)
    use build <- decode.field("build", decode.string)
    use contract <- decode.field("contract", decode.string)
    use platform <- decode.field("platform", decode.string)
    decode.success(Metadata(user_ref, build, contract, platform))
  }
  use metadata <- result.try(
    json.parse(input, decoder) |> result.map_error(fn(_) { MalformedEnvelope }),
  )
  use _ <- result.try(validate_metadata(metadata))
  Ok(metadata)
}

pub fn encode_grant(grant: Grant) -> String {
  json.object([
    #("session", session_json(grant.session)),
    #("token", json.string(grant.token)),
  ])
  |> json.to_string
}

/// Decode a grant and check that its id and token are well formed.
pub fn decode_grant(input: String) -> Result(Grant, Error) {
  let decoder = {
    use session <- decode.field("session", session_decoder())
    use token <- decode.field("token", decode.string)
    decode.success(Grant(session, token))
  }
  use grant <- result.try(
    json.parse(input, decoder) |> result.map_error(fn(_) { MalformedEnvelope }),
  )
  case
    valid_id(grant.session.id)
    && valid_id(grant.token)
    && validate_metadata(metadata(grant.session)) == Ok(Nil)
  {
    True -> Ok(grant)
    False -> Error(InvalidSession)
  }
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
      use batch <- result.try(
        json.parse(input, batch_decoder())
        |> result.map_error(fn(_) { MalformedEnvelope }),
      )
      use _ <- result.try(validate(batch))
      Ok(batch)
    }
  }
}

/// Decode an upload. The batch is validated as `decode_batch` does, and a token
/// that is not a well-formed capability is malformed.
pub fn decode_upload(input: String) -> Result(Upload, Error) {
  case string.byte_size(input) > max_upload_bytes {
    True -> Error(TooLarge)
    False -> {
      let decoder = {
        use token <- decode.field("token", decode.string)
        use batch <- decode.then(batch_decoder())
        decode.success(Upload(token, batch))
      }
      use upload <- result.try(
        json.parse(input, decoder)
        |> result.map_error(fn(_) { MalformedEnvelope }),
      )
      use _ <- result.try(case valid_id(upload.token) {
        True -> Ok(Nil)
        False -> Error(MalformedEnvelope)
      })
      use _ <- result.try(validate(upload.batch))
      Ok(upload)
    }
  }
}

fn batch_decoder() -> decode.Decoder(Batch) {
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
    _ -> decode.failure(Batch(session, checkpoint, []), "retrace format 1")
  }
}
