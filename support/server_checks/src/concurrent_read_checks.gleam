//// Public server API scenarios using real PostgreSQL and archived filesystem bytes.

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import pog
import retrace
import retrace/wire
import retrace_server as server

pub type Probe

@external(erlang, "concurrent_read_checks_ffi", "probe")
fn probe() -> Probe

@external(erlang, "concurrent_read_checks_ffi", "observed_get")
fn observed_get(
  probe: Probe,
  get: fn(String) -> Result(BitArray, server.StorageError),
  key: String,
) -> Result(BitArray, server.StorageError)

@external(erlang, "concurrent_read_checks_ffi", "peak")
fn peak(probe: Probe) -> Int

@external(erlang, "concurrent_read_checks_ffi", "active")
fn active(probe: Probe) -> Int

@external(erlang, "concurrent_read_checks_ffi", "lifetime_check")
fn lifetime_check(
  run: fn(fn(String) -> Result(BitArray, server.StorageError)) ->
    Result(List(wire.Batch), server.Error),
) -> Nil

@external(erlang, "concurrent_read_checks_ffi", "wrong_digest")
fn wrong_digest() -> BitArray

@external(erlang, "concurrent_read_checks_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

pub fn run(db: pog.Connection, store: server.ObjectStore) -> Nil {
  let session =
    wire.Session(
      "parallel-pages",
      "parallel-reader",
      "counter-v1",
      "counter-v1",
      "erlang",
    )
  let assert Ok(#(recorder, _)) = retrace.start(wire.origin(session), "0")
  let expected = append(db, session, recorder, 513)
  // Keep the final batch pending: a page can combine archived and inline data.
  list.each(list.repeat(Nil, 512), fn(_) {
    let assert Ok(True) = server.archive_next(db, store)
  })
  let observed = probe()
  let measured =
    server.ObjectStore(store.put, fn(key) {
      observed_get(observed, store.get, key)
    })
  let restored = pages(db, measured, session.id, 0)
  assert restored == expected
  assert peak(observed) > 1 && peak(observed) <= 16
  assert active(observed) == 0
  benchmark(db, store, session.id)
  let serial = probe()
  let serial_store =
    server.ObjectStore(store.put, fn(key) {
      observed_get(serial, store.get, key)
    })
  let assert Ok(_) = server.read(db, serial_store, session.id, 0)
  assert peak(serial) == 1 && active(serial) == 0
  let clamped = probe()
  let clamped_store =
    server.ObjectStore(store.put, fn(key) {
      observed_get(clamped, store.get, key)
    })
  let assert Ok(_) = server.read_concurrent(db, clamped_store, session.id, 0, 0)
  assert peak(clamped) == 1 && active(clamped) == 0
  let missing = server.ObjectStore(store.put, fn(_) { Error(server.Missing) })
  let assert Error(server.Storage(server.Missing)) =
    server.read_concurrent(db, missing, session.id, 0, 4)
  let corrupt = server.ObjectStore(store.put, fn(_) { Ok(<<1, 2, 3>>) })
  let assert Error(server.CorruptArchive) =
    server.read_concurrent(db, corrupt, session.id, 0, 4)
  let tampered = server.ObjectStore(store.put, fn(_) { Ok(wrong_digest()) })
  let assert Error(server.CorruptArchive) =
    server.read_concurrent(db, tampered, session.id, 0, 4)
  lifetime_check(fn(get) {
    server.read_concurrent(
      db,
      server.ObjectStore(store.put, get),
      session.id,
      0,
      4,
    )
  })
  deletion_check(db, store)
  // The read never owns these resources: both remain usable after all failures.
  let assert Ok([_]) = server.sessions(db, "parallel-reader")
  let assert Ok(_) = server.read(db, store, session.id, 512)
  io.println(
    "PASS 513-entry ordered concurrent pages, mixed storage, bounds, serial compatibility, corruption/missing, caller death/crash cleanup and in-flight deletion",
  )
}

fn pages(
  db: pog.Connection,
  store: server.ObjectStore,
  id: String,
  after: Int,
) -> List(wire.Batch) {
  // A caller cannot exceed the hard cap by supplying an excessive budget.
  let assert Ok(page) = server.read_concurrent(db, store, id, after, 999)
  case list.last(page) {
    Error(_) -> []
    Ok(batch) -> {
      let assert Ok(last) = list.last(batch.entries)
      list.append(page, pages(db, store, id, last.sequence))
    }
  }
}

fn append(
  db: pog.Connection,
  session: wire.Session,
  recorder: retrace.Recorder,
  remaining: Int,
) -> List(wire.Batch) {
  case remaining {
    0 -> []
    _ -> {
      let checkpoint = retrace.checkpoint(recorder, "0")
      let assert Ok(#(next, entry)) =
        retrace.record(recorder, wire.Event("Add", int.to_string(remaining)), 5)
      let batch = wire.Batch(session, checkpoint, [entry])
      let assert Ok(_) = server.accept(db, batch)
      [batch, ..append(db, session, next, remaining - 1)]
    }
  }
}

fn deletion_check(db: pog.Connection, store: server.ObjectStore) -> Nil {
  let session =
    wire.Session(
      "read-fence-race",
      "parallel-reader",
      "counter-v1",
      "counter-v1",
      "erlang",
    )
  let assert Ok(#(recorder, _)) = retrace.start(wire.origin(session), "0")
  let _ = append(db, session, recorder, 1)
  // Archive the pending tail of the first session, then this scenario's batch.
  let assert Ok(True) = server.archive_next(db, store)
  let assert Ok(True) = server.archive_next(db, store)
  let entered = process.new_subject()
  let completed = process.new_subject()
  let blocking =
    server.ObjectStore(store.put, fn(key) {
      let release = process.new_subject()
      process.send(entered, release)
      let assert Ok(Nil) = process.receive(release, 3000)
      store.get(key)
    })
  let _ =
    process.spawn(fn() {
      process.send(
        completed,
        server.read_concurrent(db, blocking, session.id, 0, 4),
      )
    })
  let assert Ok(release) = process.receive(entered, 3000)
  let assert Ok(_) = server.fence(db, session.id)
  process.send(release, Nil)
  let assert Ok(Error(server.Deleted)) = process.receive(completed, 3000)
  let assert Ok(_) = store.get("sessions/read-fence-race/0.json.gz")
  Nil
}

fn benchmark(db: pog.Connection, store: server.ObjectStore, id: String) -> Nil {
  let delayed =
    server.ObjectStore(store.put, fn(key) {
      process.sleep(40)
      store.get(key)
    })
  let started = monotonic_ms()
  let assert Ok(serial) = server.read(db, delayed, id, 0)
  let serial_ms = monotonic_ms() - started
  let started = monotonic_ms()
  let assert Ok(parallel) = server.read_concurrent(db, delayed, id, 0, 16)
  let parallel_ms = monotonic_ms() - started
  assert parallel == serial && list.length(parallel) == 128
  io.println(
    "BENCHMARK 128 archived batches with 40 ms per-object delay: serial="
    <> int.to_string(serial_ms)
    <> " ms concurrent16="
    <> int.to_string(parallel_ms)
    <> " ms; payloads identical",
  )
}
