//// Local example host. Owns the pool, archive worker and HTTP listener.
//// Bind only to loopback: these example routes have no deployment auth policy.
//// Browsers reach it only from the configured origins, and an optional bearer
//// token closes every route to callers that do not present it.

import bucket
import envoy
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist
import pog
import retrace/wire
import retrace_server.{type ObjectStore}
import retrace_server/directory
import retrace_server/s3

fn env(name: String, fallback: String) -> String {
  envoy.get(name) |> result.unwrap(fallback)
}

fn number(name: String, fallback: Int) -> Int {
  env(name, int.to_string(fallback)) |> int.parse |> result.unwrap(fallback)
}

/// Which browser origins may call the collector and the optional bearer token
/// every route then requires.
pub type Access {
  Access(allowed_origins: List(String), token: Option(String))
}

/// The origins of the maintained example apps, viewers and Tauri builds.
pub const development_origins = [
  "http://127.0.0.1:5190", "http://localhost:5190", "http://127.0.0.1:5191",
  "http://localhost:5191", "http://127.0.0.1:5193", "http://localhost:5193",
  "http://127.0.0.1:5194", "http://localhost:5194", "tauri://localhost",
  "http://tauri.localhost",
]

/// `RETRACE_ALLOWED_ORIGINS` is a comma-separated list of exact origins and
/// replaces `development_origins`. `RETRACE_COLLECTOR_TOKEN` sets the token.
pub fn access_from_env() -> Access {
  let origins = case envoy.get("RETRACE_ALLOWED_ORIGINS") {
    Error(Nil) -> development_origins
    Ok(listed) ->
      string.split(listed, ",")
      |> list.map(string.trim)
      |> list.filter(fn(origin) { origin != "" })
  }
  let token = case envoy.get("RETRACE_COLLECTOR_TOKEN") {
    Ok(token) if token != "" -> Some(token)
    _ -> None
  }
  Access(origins, token)
}

/// The collector's request handler, separated from `main` so that a host or a
/// test can serve it with its own pool, store and listener.
pub fn handler(
  access: Access,
  db: pog.Connection,
  store: ObjectStore,
) -> fn(Request(mist.Connection)) -> Response(mist.ResponseData) {
  fn(req) { guard(access, req, fn() { route(db, store, req) }) }
}

// Loopback binding stops remote hosts, not pages in the developer's browser:
// the Host check refuses DNS-rebound names, the Origin check refuses every
// other site, and the token check refuses callers without the token.
fn guard(
  access: Access,
  req: Request(mist.Connection),
  next: fn() -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  let origin = request.get_header(req, "origin")
  let granted =
    origin
    |> result.try(fn(origin) {
      case list.contains(access.allowed_origins, origin) {
        True -> Ok(origin)
        False -> Error(Nil)
      }
    })
  case loopback_host(req), origin, granted, req.method {
    False, _, _, _ -> refuse(403, "Host is not a loopback name")
    True, Ok(_), Error(Nil), _ -> refuse(403, "Origin is not allowed")
    True, Error(Nil), _, http.Options ->
      refuse(403, "Preflight needs an allowed origin")
    True, _, Ok(origin), http.Options ->
      response.new(204)
      |> response.set_header(
        "access-control-allow-methods",
        "GET, POST, OPTIONS",
      )
      |> response.set_header(
        "access-control-allow-headers",
        "content-type, authorization",
      )
      |> response.set_header("access-control-max-age", "600")
      |> response.set_body(mist.Bytes(bytes_tree.new()))
      |> grant(origin)
    True, _, _, _ -> {
      let reply = case authorized(access.token, req) {
        True -> next()
        False ->
          refuse(401, "Missing or wrong bearer token")
          |> response.set_header("www-authenticate", "Bearer")
      }
      case granted {
        Ok(origin) -> grant(reply, origin)
        Error(Nil) -> reply
      }
    }
  }
}

fn grant(
  reply: Response(mist.ResponseData),
  origin: String,
) -> Response(mist.ResponseData) {
  reply
  |> response.set_header("access-control-allow-origin", origin)
  |> response.set_header("vary", "Origin")
}

fn refuse(status: Int, message: String) -> Response(mist.ResponseData) {
  reply(status, json.object([#("error", json.string(message))]))
}

fn loopback_host(req: Request(mist.Connection)) -> Bool {
  case request.get_header(req, "host") {
    Error(Nil) -> False
    Ok(host) -> {
      let name = case string.split_once(string.lowercase(host), "]") {
        Ok(#(bracketed, _port)) -> bracketed <> "]"
        Error(Nil) ->
          string.split_once(host, ":")
          |> result.map(fn(pair) { pair.0 })
          |> result.unwrap(host)
          |> string.lowercase
      }
      list.contains(["127.0.0.1", "localhost", "[::1]"], name)
    }
  }
}

fn authorized(token: Option(String), req: Request(mist.Connection)) -> Bool {
  case token {
    None -> True
    Some(expected) ->
      case
        request.get_header(req, "authorization")
        |> result.try(string.split_once(_, " "))
      {
        Ok(#(scheme, given)) ->
          string.lowercase(scheme) == "bearer"
          && same_token(string.trim(given), expected)
        Error(Nil) -> False
      }
  }
}

// Digests first, so the comparison time depends on neither value's length.
fn same_token(given: String, expected: String) -> Bool {
  let digest = fn(value) {
    crypto.hash(crypto.Sha256, bit_array.from_string(value))
  }
  crypto.secure_compare(digest(given), digest(expected))
}

pub fn main() -> Nil {
  let assert Ok(config) =
    pog.url_config(
      process.new_name("retrace-db"),
      env("DATABASE_URL", "postgres://retrace@127.0.0.1:5547/retrace"),
    )
  let assert Ok(started) = config |> pog.pool_size(4) |> pog.start
  let db = started.data
  let assert Ok(_) = retrace_server.migrate(db)
  let store = case env("RETRACE_OBJECT_STORE", "s3") {
    "directory" -> directory.store(env("RETRACE_OBJECT_DIR", ".local/objects"))
    _ -> {
      let credentials =
        bucket.credentials(
          env("S3_HOST", "127.0.0.1"),
          env("S3_ACCESS_KEY", "retrace-local"),
          env("S3_SECRET_KEY", "retrace-local-development-only"),
        )
        |> bucket.with_port(number("S3_PORT", 8337))
        |> bucket.with_region("us-east-1")
        |> bucket.with_scheme(http.Http)
      let name = env("S3_BUCKET", "retrace")
      let assert Ok(_) = s3.create(credentials, name)
      s3.store(credentials, name)
    }
  }
  case env("RETRACE_ARCHIVE_WORKER", "on") {
    "on" -> {
      let _ = process.spawn(fn() { archive_loop(db, store) })
      Nil
    }
    _ -> Nil
  }
  let access = access_from_env()
  case access.token {
    Some(_) -> Nil
    None ->
      io.println(
        "Warning: RETRACE_COLLECTOR_TOKEN is unset; any local process can read and submit recordings",
      )
  }
  let assert Ok(_) =
    mist.new(handler(access, db, store))
    |> mist.bind("127.0.0.1")
    |> mist.port(number("RETRACE_PORT", 4417))
    |> mist.start
  io.println(
    "Retrace collector listening on loopback; local development routes only",
  )
  process.sleep_forever()
}

fn archive_loop(db: pog.Connection, store: ObjectStore) -> Nil {
  case retrace_server.archive_next(db, store) {
    Ok(True) -> archive_loop(db, store)
    Ok(False) | Error(_) -> {
      process.sleep(1000)
      archive_loop(db, store)
    }
  }
}

fn reply(status: Int, data: json.Json) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(
    data |> json.to_string |> bytes_tree.from_string,
  ))
}

fn failed(error: retrace_server.Error) -> Response(mist.ResponseData) {
  let status = case error {
    retrace_server.Conflict | retrace_server.OutOfOrder(_, _) -> 409
    retrace_server.InvalidBatch(_) -> 400
    retrace_server.NotFound | retrace_server.Deleted -> 404
    retrace_server.Database(_)
    | retrace_server.Storage(_)
    | retrace_server.UnsupportedSchema(_)
    | retrace_server.CorruptArchive -> 503
  }
  // Do not expose database diagnostics or storage credentials over HTTP.
  reply(
    status,
    json.object([
      #(
        "error",
        json.string(case status {
          409 -> "Recording conflicts with the stored session"
          400 -> "Invalid recording batch"
          404 -> "Session not found"
          _ -> "Recording storage is unavailable"
        }),
      ),
    ]),
  )
}

fn query(req: Request(mist.Connection), key: String) -> String {
  req
  |> request.get_query
  |> result.unwrap([])
  |> list.key_find(key)
  |> result.unwrap("")
}

type BodyError {
  LengthRequired
  TooLarge
  Unreadable
}

// mist buffers each transfer chunk whole, so a framed body is refused before
// any of it is read; every packaged adapter sends Content-Length. Streaming
// still stops one byte past the limit if the declared length is wrong.
fn read_bounded_body(
  req: Request(mist.Connection),
  limit: Int,
) -> Result(BitArray, BodyError) {
  let framed = result.is_ok(request.get_header(req, "transfer-encoding"))
  let declared =
    request.get_header(req, "content-length") |> result.try(int.parse)
  case framed, declared {
    True, _ | False, Error(Nil) -> Error(LengthRequired)
    False, Ok(length) if length > limit -> Error(TooLarge)
    False, Ok(_) ->
      case mist.stream(req) {
        Error(_) -> Error(Unreadable)
        Ok(consume) -> read_chunks(consume, limit, <<>>)
      }
  }
}

fn read_chunks(
  consume: fn(Int) -> Result(mist.Chunk, mist.ReadError),
  limit: Int,
  body: BitArray,
) -> Result(BitArray, BodyError) {
  let remaining = limit - bit_array.byte_size(body)
  case consume(int.min(65_536, remaining + 1)) {
    Error(_) -> Error(Unreadable)
    Ok(mist.Done) -> Ok(body)
    Ok(mist.Chunk(chunk, next)) ->
      case bit_array.byte_size(chunk) > remaining {
        True -> Error(TooLarge)
        False -> read_chunks(next, limit, bit_array.append(body, chunk))
      }
  }
}

fn route(
  db: pog.Connection,
  store: ObjectStore,
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  case req.method, string.split(req.path, "/") {
    http.Get, ["", "health"] ->
      reply(200, json.object([#("ok", json.bool(True))]))
    http.Post, ["", "batches"] ->
      case read_bounded_body(req, wire.max_bytes) {
        Error(TooLarge) ->
          reply(
            413,
            json.object([#("error", json.string("Batch body exceeds limit"))]),
          )
          |> response.set_header("connection", "close")
        Error(LengthRequired) ->
          reply(
            411,
            json.object([
              #("error", json.string("Batch body needs a Content-Length")),
            ]),
          )
          |> response.set_header("connection", "close")
        Error(Unreadable) ->
          failed(retrace_server.InvalidBatch(wire.MalformedEnvelope))
        Ok(body) ->
          case
            bit_array.to_string(body)
            |> result.map_error(fn(_) { wire.MalformedEnvelope })
            |> result.try(wire.decode_batch)
          {
            Error(reason) -> failed(retrace_server.InvalidBatch(reason))
            Ok(batch) ->
              case retrace_server.accept(db, batch) {
                Error(reason) -> failed(reason)
                Ok(sequence) ->
                  reply(
                    200,
                    json.object([
                      #("session_id", json.string(batch.session.id)),
                      #("ack", json.int(sequence)),
                    ]),
                  )
              }
          }
      }
    http.Get, ["", "sessions"] ->
      case retrace_server.sessions(db, query(req, "user")) {
        Error(reason) -> failed(reason)
        Ok(sessions) ->
          reply(
            200,
            json.array(sessions, fn(summary) {
              json.object([
                #("session", wire.session_json(summary.session)),
                #("sequence", json.int(summary.sequence)),
                #("elapsed_ms", json.int(summary.elapsed_ms)),
                #("pending", json.int(summary.pending)),
                #("archived", json.int(summary.archived)),
              ])
            }),
          )
      }
    http.Get, ["", "sessions", id, "batches"] ->
      case
        retrace_server.read(
          db,
          store,
          id,
          query(req, "after") |> int.parse |> result.unwrap(0),
        )
      {
        Error(reason) -> failed(reason)
        Ok(batches) ->
          reply(
            200,
            json.array(batches, fn(batch) { json.string(wire.encode(batch)) }),
          )
      }
    http.Post, ["", "archive"] ->
      case retrace_server.archive_next(db, store) {
        Error(reason) -> failed(reason)
        Ok(archived) ->
          reply(200, json.object([#("archived", json.bool(archived))]))
      }
    _, _ -> reply(404, json.object([#("error", json.string("Not found"))]))
  }
}
