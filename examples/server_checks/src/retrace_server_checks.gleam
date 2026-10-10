//// Separate consumer: fault injection through the public object-store contract.

import envoy
import gleam/erlang/process
import gleam/io
import pog
import retrace
import retrace/wire
import retrace_server as server
import retrace_server/directory

pub fn main() {
  let assert Ok(url) = envoy.get("DATABASE_URL")
  let assert Ok(root) = envoy.get("RETRACE_CHECK_OBJECTS")
  let assert Ok(config) = pog.url_config(process.new_name("checks"), url)
  let assert Ok(started) = pog.start(config)
  let db = started.data
  let assert Ok(_) = server.migrate(db)
  let session =
    wire.Session("fault-check", "example", "counter-v1", "counter-v1", "erlang")
  let assert Ok(#(recorder, checkpoint)) =
    retrace.start(wire.origin(session), "0")
  let assert Ok(#(_, entry)) =
    retrace.record(recorder, wire.Event("Add", "1"), 5)
  let batch = wire.Batch(session, checkpoint, [entry])
  let failing =
    server.ObjectStore(fn(_, _) { Error(server.Unavailable) }, fn(_) {
      Error(server.Unavailable)
    })
  let assert Ok(1) = server.accept(db, batch)
  let assert Error(server.Storage(server.Unavailable)) =
    server.archive_next(db, failing)
  let assert Ok([restored]) = server.read(db, failing, session.id, 0)
  assert restored == batch
  let assert Ok([summary]) = server.sessions(db, "example")
  assert summary.pending == 1 && summary.archived == 0
  let store = directory.store(root)
  let assert Error(server.InvalidObject) = store.get("")
  let assert Ok(True) = server.archive_next(db, store)
  let assert Ok(False) = server.archive_next(db, store)
  let assert Ok([restored]) = server.read(db, store, session.id, 0)
  assert restored == batch
  let assert Error(server.Storage(server.Unavailable)) =
    server.read(db, failing, session.id, 0)
  let corrupt = server.ObjectStore(store.put, fn(_) { Ok(<<1, 2, 3>>) })
  let assert Error(server.CorruptArchive) =
    server.read(db, corrupt, session.id, 0)
  let assert Ok(1) = server.accept(db, batch)
  io.println(
    "PASS upload failure retains database payload, adapter recovery, missing/corrupt archive errors, post-archive retry",
  )
}
