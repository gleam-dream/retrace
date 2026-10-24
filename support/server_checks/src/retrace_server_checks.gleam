//// Separate consumer: fault injection through the public object-store contract.

import concurrent_read_checks
import envoy
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import pog
import quiescence_checks
import retrace
import retrace/wire
import retrace_server as server
import retrace_server/directory
import segment_checks

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
  let remove = fn(key) { directory.remove(root, key) }
  let eraser = server.Eraser(remove, fn(_) { server.MayPublish })
  let assert Error(server.Conflict) = server.erase(db, eraser, session.id)
  let assert Ok(_) = server.fence(db, session.id)
  let assert Error(server.Deleted) = server.accept(db, batch)
  let assert Error(server.Deleted) = server.read(db, store, session.id, 0)
  let assert Ok([]) = server.sessions(db, "example")
  let assert Ok(False) = server.archive_next(db, store)
  // The first put failed without proof, so erasure waits for that attempt.
  let assert Ok(Some(server.AwaitingWriters(1))) =
    server.erasure_status(db, session.id)
  let assert Ok(server.AwaitingWriters(1)) =
    server.erase(db, eraser, session.id)
  let assert Ok(Some(#(_, server.AwaitingWriters(1)))) =
    server.erase_next(db, eraser, 3600)
  let assert Ok(all) = server.write_attempts(db, session.id, 10)
  let assert [attempt] =
    list.filter(all, fn(found) { found.state != server.Completed })
  assert attempt.object_key == "sessions/fault-check/0.json.gz"
  assert attempt.state == server.Failed
  // The directory adapter proves a returned failure quiescent.
  let proving = server.Eraser(remove, directory.quiesced)
  let assert Error(server.Storage(server.Unavailable)) =
    server.erase(
      db,
      server.Eraser(fn(_) { Error(server.Unavailable) }, directory.quiesced),
      session.id,
    )
  let assert Ok(server.Erased) = server.erase(db, proving, session.id)
  let assert Error(server.Missing) = store.get("sessions/fault-check/0.json.gz")
  // Simulate an uncertain late PUT after the first cleanup. Retained keys permit
  // reconciliation even though the recording rows have already been erased.
  let assert Ok(_) = store.put("sessions/fault-check/0.json.gz", <<1>>)
  let assert Ok(_) = server.erase(db, eraser, session.id)
  let assert Error(server.Missing) = store.get("sessions/fault-check/0.json.gz")
  let assert Ok(_) = server.fence(db, "never-admitted")
  let assert Ok(Some(#("never-admitted", server.Erased))) =
    server.erase_next(db, eraser, 3600)
  let assert Ok(None) = server.erase_next(db, eraser, 3600)
  concurrent_read_checks.run(db, store)
  bounded_check(db, remove)
  race_check(db, store, remove)
  let unadmitted = sample("never-admitted")
  let assert Error(server.Deleted) = server.accept(db, unadmitted)
  let assert Error(pog.TransactionRolledBack(Nil)) =
    pog.transaction(db, fn(tx) {
      let assert Ok(1) = server.accept_in_transaction(tx, sample("rolled-back"))
      Error(Nil)
    })
  let assert Ok([]) = server.read(db, store, "rolled-back", 0)
  segment_checks.run(db, store, root)
  quiescence_checks.run(db)
  io.println(
    "PASS archival failure/recovery, integrity, bounded erasure, deletion retry, active archive fence, pre-admission fence, late PUT reconciliation and caller transaction rollback",
  )
}

fn sample(id: String) -> wire.Batch {
  let session =
    wire.Session(id, "race-principal", "counter-v1", "counter-v1", "erlang")
  let assert Ok(#(recorder, checkpoint)) =
    retrace.start(wire.origin(session), "0")
  let assert Ok(#(_, entry)) =
    retrace.record(recorder, wire.Event("Add", "1"), 5)
  wire.Batch(session, checkpoint, [entry])
}

fn race_check(
  db: pog.Connection,
  store: server.ObjectStore,
  remove: fn(String) -> Result(Nil, server.StorageError),
) -> Nil {
  let batch = sample("racing-archive")
  let assert Ok(1) = server.accept(db, batch)
  let entered = process.new_subject()
  let archived = process.new_subject()
  let blocking =
    server.ObjectStore(
      fn(key, bytes) {
        let release = process.new_subject()
        process.send(entered, release)
        let assert Ok(Nil) = process.receive(release, 3000)
        store.put(key, bytes)
      },
      store.get,
    )
  let _ =
    process.spawn(fn() {
      process.send(archived, server.archive_next(db, blocking))
    })
  let assert Ok(release) = process.receive(entered, 3000)
  // The fence does not wait for the remote call. Erasure waits for its attempt.
  let assert Ok(_) = server.fence(db, batch.session.id)
  let assert Ok(server.AwaitingWriters(1)) =
    server.erase(
      db,
      server.Eraser(remove, fn(_) { server.MayPublish }),
      batch.session.id,
    )
  process.send(release, Nil)
  let assert Ok(Error(server.Deleted)) = process.receive(archived, 3000)
  let assert Ok(server.Erased) =
    server.erase(
      db,
      server.Eraser(remove, fn(_) { server.MayPublish }),
      batch.session.id,
    )
  let assert Error(server.Missing) =
    store.get("sessions/racing-archive/0.json.gz")
  let assert Error(server.Deleted) = server.accept(db, batch)
  Nil
}

fn bounded_check(
  db: pog.Connection,
  remove: fn(String) -> Result(Nil, server.StorageError),
) -> Nil {
  let session =
    wire.Session(
      "many-batches",
      "example",
      "counter-v1",
      "counter-v1",
      "erlang",
    )
  let assert Ok(#(recorder, _)) = retrace.start(wire.origin(session), "0")
  append_batches(db, session, recorder, 9)
  let assert Ok(_) = server.fence(db, session.id)
  let eraser = server.Eraser(remove, fn(_) { server.MayPublish })
  let assert Ok(server.Erasing) = server.erase(db, eraser, session.id)
  let assert Ok(server.Erased) = server.erase(db, eraser, session.id)
  Nil
}

fn append_batches(
  db: pog.Connection,
  session: wire.Session,
  recorder: retrace.Recorder,
  left: Int,
) -> Nil {
  case left {
    0 -> Nil
    _ -> {
      let checkpoint = retrace.checkpoint(recorder, "0")
      let assert Ok(#(next, entry)) =
        retrace.record(recorder, wire.Event("Add", "1"), 5)
      let assert Ok(_) =
        server.accept(db, wire.Batch(session, checkpoint, [entry]))
      append_batches(db, session, next, left - 1)
    }
  }
}
