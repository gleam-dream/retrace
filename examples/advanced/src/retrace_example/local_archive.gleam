//// Advanced consumer: local archive reads and artifact policy in Gleam.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import retrace/wire
import retrace_client
import retrace_viewer as viewer

/// Opt into this example adapter independently of the live and replay domains.
pub fn source() -> viewer.Source {
  viewer.Source(sessions, range)
}

fn sessions(user: String) -> viewer.Task(List(viewer.Summary)) {
  fn(reply) {
    let summaries =
      list.try_map(archive_ids(), fn(id) {
        use rows <- result.try(read_batches(id))
        case list.last(rows) {
          Ok(batch) ->
            case list.last(batch.entries) {
              Ok(entry) -> Ok(viewer.Summary(batch.session, entry.sequence))
              Error(_) -> Error("Empty archive batch")
            }
          Error(_) -> Error("Empty archive")
        }
      })
      |> result.map(fn(rows) {
        list.filter(rows, fn(row) { user == "" || row.session.user_ref == user })
      })
    reply(summaries)
    fn() { Nil }
  }
}

fn read_batches(id: String) -> Result(List(wire.Batch), String) {
  use bodies <- result.try(archive_rows(id))
  list.try_map(bodies, fn(body) {
    wire.decode_batch(body)
    |> result.map_error(fn(_) { "Invalid archive batch" })
  })
}

fn range(id: String, after: Int, limit: Int) -> viewer.Task(viewer.Page) {
  fn(reply) {
    let page =
      read_batches(id)
      |> result.map(fn(rows) {
        let all =
          list.filter(rows, fn(batch) {
            case list.last(batch.entries) {
              Ok(entry) -> entry.sequence > after
              Error(_) -> False
            }
          })
        let selected = list.take(all, limit)
        let next = case list.length(all) > limit, list.last(selected) {
          True, Ok(batch) ->
            case list.last(batch.entries) {
              Ok(entry) -> Some(entry.sequence)
              Error(_) -> None
            }
          _, _ -> None
        }
        viewer.Page(list.map(selected, wire.encode), next)
      })
    reply(page)
    fn() { Nil }
  }
}

@external(javascript, "../local_archive_ffi.mjs", "archiveIds")
fn archive_ids() -> List(String)

@external(javascript, "../local_archive_ffi.mjs", "archiveRows")
fn archive_rows(id: String) -> Result(List(String), String)

@external(javascript, "../local_archive_ffi.mjs", "storage")
pub fn storage() -> retrace_client.Storage

@external(javascript, "../local_archive_ffi.mjs", "transport")
pub fn transport() -> retrace_client.Transport

@external(javascript, "../local_archive_ffi.mjs", "selected")
pub fn selected() -> Bool
