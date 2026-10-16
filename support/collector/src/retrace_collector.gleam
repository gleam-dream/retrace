//// Local example host. Owns the pool, archive worker and HTTP listener.
//// Bind only to loopback: these example routes have no deployment auth policy.

import bucket
import envoy
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
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
  let assert Ok(_) =
    mist.new(fn(req) { route(db, store, req) })
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
  |> response.set_header("access-control-allow-origin", "*")
  |> response.set_header("access-control-allow-methods", "GET,POST,OPTIONS")
  |> response.set_header("access-control-allow-headers", "content-type")
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

fn route(
  db: pog.Connection,
  store: ObjectStore,
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  case req.method, string.split(req.path, "/") {
    http.Options, _ -> reply(200, json.null())
    http.Get, ["", "health"] ->
      reply(200, json.object([#("ok", json.bool(True))]))
    http.Post, ["", "batches"] ->
      case mist.read_body(req, wire.max_bytes) {
        Error(_) ->
          reply(
            413,
            json.object([#("error", json.string("Batch body exceeds limit"))]),
          )
        Ok(body) ->
          case
            bit_array.to_string(body.body)
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
