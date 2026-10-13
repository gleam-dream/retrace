//// Advanced consumer: local storage, upload policy and viewer reads in Gleam.
//// Browser IO remains a thin binding. The archive is single-writer demo storage.

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import retrace/wire
import retrace_frontend/client
import retrace_frontend/client/adapter
import retrace_frontend/viewer

const archive_prefix = "retrace:advanced:archive:"

fn read_rows(key: String) -> Result(dict.Dict(String, String), String) {
  use body <- result.try(read(key))
  json.parse(body, decode.dict(decode.string, decode.string))
  |> result.map_error(fn(_) { "Invalid local storage rows" })
}

fn write_rows(
  key: String,
  rows: dict.Dict(String, String),
) -> Result(Nil, String) {
  rows
  |> dict.to_list
  |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) })
  |> json.object
  |> json.to_string
  |> write(key, _)
}

fn insert(
  rows: dict.Dict(String, String),
  key: String,
  body: String,
) -> Result(dict.Dict(String, String), String) {
  case dict.get(rows, key) {
    Ok(existing) if existing != body -> Error("Conflicting local batch")
    Ok(_existing) | Error(_) -> Ok(dict.insert(rows, key, body))
  }
}

pub fn storage() -> client.Storage {
  adapter.storage(
    fn(queue) {
      adapter.defer(fn() {
        let key = "retrace:" <> queue.name
        Ok(
          adapter.Store(
            all: fn() {
              adapter.defer(fn() {
                read_rows(key)
                |> result.map(fn(rows) {
                  dict.to_list(rows)
                  |> list.map(fn(pair) { adapter.Row(pair.0, pair.1) })
                })
              })
            },
            put: fn(row) {
              adapter.defer(fn() {
                use rows <- result.try(read_rows(key))
                use next <- result.try(insert(rows, row.key, row.body))
                let bytes =
                  list.fold(dict.values(next), 0, fn(n, body) {
                    n + string.byte_size(body)
                  })
                case
                  dict.size(next) > queue.max_items || bytes > queue.max_bytes
                {
                  True -> Error("Recording queue is full")
                  False -> write_rows(key, next)
                }
              })
            },
            remove: fn(id) {
              adapter.defer(fn() {
                use rows <- result.try(read_rows(key))
                write_rows(key, dict.delete(rows, id))
              })
            },
          ),
        )
      })
    },
    fn(error) { error },
  )
}

pub fn transport() -> client.Transport {
  adapter.transport(
    fn(body) {
      adapter.defer(fn() {
        use batch <- result.try(
          wire.decode_batch(body)
          |> result.map_error(fn(_) { "Invalid archive batch" }),
        )
        let key = archive_prefix <> batch.session.id
        use rows <- result.try(read_rows(key))
        use next <- result.try(insert(
          rows,
          int.to_string(batch.checkpoint.sequence),
          body,
        ))
        use _ <- result.try(write_rows(key, next))
        Ok(
          json.object([
            #("session_id", json.string(batch.session.id)),
            #("ack", json.int(wire.end_sequence(batch))),
          ])
          |> json.to_string,
        )
      })
    },
    fn(error) { error },
  )
}

/// Independently select the source; it does not start a delivery runtime.
pub fn source() -> viewer.Source {
  viewer.Source(sessions, range)
}

fn sessions(user: String) -> viewer.Task(List(viewer.Summary)) {
  adapter.defer(fn() {
    use keys <- result.try(keys())
    keys
    |> list.filter(fn(key) { string.starts_with(key, archive_prefix) })
    |> list.try_map(fn(key) {
      use rows <- result.try(
        read_batches(string.drop_start(key, string.length(archive_prefix))),
      )
      use last <- result.try(
        list.last(rows) |> result.map_error(fn(_) { "Empty archive" }),
      )
      Ok(viewer.Summary(last.session, wire.end_sequence(last)))
    })
    |> result.map(fn(rows) {
      list.filter(rows, fn(row) { user == "" || row.session.user_ref == user })
    })
  })
}

fn read_batches(id: String) -> Result(List(wire.Batch), String) {
  use rows <- result.try(read_rows(archive_prefix <> id))
  use batches <- result.try(
    list.try_map(dict.values(rows), fn(body) {
      wire.decode_batch(body)
      |> result.map_error(fn(_) { "Invalid archive batch" })
    }),
  )
  Ok(
    list.sort(batches, fn(a, b) {
      int.compare(a.checkpoint.sequence, b.checkpoint.sequence)
    }),
  )
}

fn range(id: String, after: Int, limit: Int) -> viewer.Task(viewer.Page) {
  adapter.defer(fn() {
    use rows <- result.try(read_batches(id))
    let all = list.filter(rows, fn(batch) { wire.end_sequence(batch) > after })
    let selected = list.take(all, limit)
    let next = case list.length(all) > limit, list.last(selected) {
      True, Ok(batch) -> Some(wire.end_sequence(batch))
      _, _ -> None
    }
    Ok(viewer.Page(list.map(selected, wire.encode), next))
  })
}

@external(javascript, "../local_archive_ffi.mjs", "read")
fn read(key: String) -> Result(String, String)

@external(javascript, "../local_archive_ffi.mjs", "write")
fn write(key: String, value: String) -> Result(Nil, String)

@external(javascript, "../local_archive_ffi.mjs", "keys")
fn keys() -> Result(List(String), String)

@external(javascript, "../local_archive_ffi.mjs", "selected")
pub fn selected() -> Bool
