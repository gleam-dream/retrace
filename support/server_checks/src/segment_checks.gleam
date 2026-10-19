//// Segment lifecycle scenarios cross only the public API and filesystem store.

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import pog
import retrace
import retrace/wire
import retrace_server as server
import retrace_server/directory

pub type Counter

@external(erlang, "segment_checks_ffi", "counter")
fn counter() -> Counter

@external(erlang, "segment_checks_ffi", "increment")
fn increment(counter: Counter) -> Int

@external(erlang, "segment_checks_ffi", "count")
fn count(counter: Counter) -> Int

@external(erlang, "segment_checks_ffi", "keys")
fn keys(root: String, id: String) -> List(String)

@external(erlang, "segment_checks_ffi", "gzip_bomb")
fn gzip_bomb() -> BitArray

pub fn run(db: pog.Connection, store: server.ObjectStore, root: String) -> Nil {
  drain(db, store)
  reclaim(db, root)
  let session = session("segment-boundaries")
  let assert Ok(#(recorder, _)) = retrace.start(wire.origin(session), "0")
  let #(recorder, first) = append(db, session, recorder, 999, 128, "1")
  let assert Ok(False) = server.archive_segment_next(db, store, 60)
  let assert Ok(True) = server.archive_segment_next(db, store, 0)
  reclaim(db, root)
  assert list.length(keys(root, session.id)) == 1
  let reads = counter()
  let measured =
    server.ObjectStore(store.put, fn(key) {
      let _ = increment(reads)
      store.get(key)
    })
  let assert Ok(restored) =
    server.read_concurrent(db, measured, session.id, 0, 16)
  assert restored == first && count(reads) == 1
  let #(recorder, next) = append(db, session, recorder, 1, 1, "1")
  // Missing a superseded object retries fresh authoritative pointers once.
  let swapped = counter()
  let swap_store =
    server.ObjectStore(store.put, fn(key) {
      case increment(swapped) {
        1 -> {
          let assert Ok(True) = server.archive_segment_next(db, store, 0)
          reclaim(db, root)
        }
        _ -> Nil
      }
      store.get(key)
    })
  let assert Ok(restored) = server.read(db, swap_store, session.id, 0)
  let expected = list.append(first, next)
  assert restored == expected && count(swapped) == 2
  assert list.length(keys(root, session.id)) == 1
  let #(_, last) = append(db, session, recorder, 1, 1, "1")
  let assert Ok(True) = server.archive_segment_next(db, store, 0)
  reclaim(db, root)
  assert list.length(keys(root, session.id)) == 2
  let reads = counter()
  let measured =
    server.ObjectStore(store.put, fn(key) {
      let _ = increment(reads)
      store.get(key)
    })
  let assert Ok(restored) =
    server.read_concurrent(db, measured, session.id, 0, 16)
  assert restored == list.append(expected, last) && count(reads) == 2
  let assert Ok(original) = list.first(first)
  let assert Ok(128) = server.accept(db, original)
  let changed =
    wire.Batch(
      ..original,
      checkpoint: retrace.Checkpoint(..original.checkpoint, model: "changed"),
    )
  let assert Error(server.Conflict) = server.accept(db, changed)
  crossing_batch(db, store, root)
  failed_publication(db, store, root)
  concurrent_publication(db, store, root)
  legacy_upgrade(db, store, root)
  preparation_race(db, store, root)
  inline_integrity(db, store)
  oversized(db, store, root)
  io.println(
    "PASS session objects at 999/1000/1001 events, late replacement/reclaim, read pointer refresh, whole crossing batches, durable publication retry/readback, concurrent workers/fence, legacy compaction and oversized Neon fallback",
  )
}

fn session(id: String) -> wire.Session {
  wire.Session(id, "segment-check", "counter-v1", "counter-v1", "erlang")
}

fn append(
  db: pog.Connection,
  session: wire.Session,
  recorder: retrace.Recorder,
  remaining: Int,
  size: Int,
  payload: String,
) -> #(retrace.Recorder, List(wire.Batch)) {
  case remaining {
    0 -> #(recorder, [])
    _ -> {
      let n = int.min(remaining, size)
      let checkpoint = retrace.checkpoint(recorder, "0")
      let #(next, entries) = record(recorder, n, payload)
      let batch = wire.Batch(session, checkpoint, entries)
      let assert Ok(_) = server.accept(db, batch)
      let #(last, tail) =
        append(db, session, next, remaining - n, size, payload)
      #(last, [batch, ..tail])
    }
  }
}

fn record(
  recorder: retrace.Recorder,
  remaining: Int,
  payload: String,
) -> #(retrace.Recorder, List(retrace.Entry(wire.Event))) {
  case remaining {
    0 -> #(recorder, [])
    _ -> {
      let assert Ok(#(next, entry)) =
        retrace.record(recorder, wire.Event("Add", payload), 5)
      let #(last, rest) = record(next, remaining - 1, payload)
      #(last, [entry, ..rest])
    }
  }
}

fn drain(db: pog.Connection, store: server.ObjectStore) -> Nil {
  let assert Ok(work) = server.archive_segment_next(db, store, 0)
  case work {
    True -> drain(db, store)
    False -> Nil
  }
}

fn reclaim(db: pog.Connection, root: String) -> Nil {
  let assert Ok(work) =
    server.reclaim_next(db, fn(key) { directory.remove(root, key) }, 86_400)
  case work {
    True -> reclaim(db, root)
    False -> Nil
  }
}

fn erase(db: pog.Connection, root: String, id: String) -> Nil {
  let eraser =
    server.Eraser(fn(key) { directory.remove(root, key) }, fn(_) {
      server.MayPublish
    })
  let assert Ok(state) = server.erase(db, eraser, id)
  case state {
    server.Erased -> Nil
    server.Erasing -> erase(db, root, id)
    server.AwaitingWriters(_) -> panic as "an unproven writer remains"
  }
}

fn crossing_batch(
  db: pog.Connection,
  store: server.ObjectStore,
  root: String,
) -> Nil {
  let session = session("crossing-batch")
  let assert Ok(#(recorder, _)) = retrace.start(wire.origin(session), "0")
  let #(recorder, first) = append(db, session, recorder, 999, 128, "1")
  let #(_, tail) = append(db, session, recorder, 128, 128, "1")
  drain(db, store)
  reclaim(db, root)
  assert list.length(keys(root, session.id)) == 2
  let assert Ok(restored) = server.read(db, store, session.id, 0)
  assert restored == list.append(first, tail)
  Nil
}

fn failed_publication(
  db: pog.Connection,
  store: server.ObjectStore,
  root: String,
) -> Nil {
  let session = session("failed-publication")
  let assert Ok(#(recorder, _)) = retrace.start(wire.origin(session), "0")
  let #(_, batches) = append(db, session, recorder, 12, 1, "1")
  let fail =
    server.ObjectStore(
      fn(key, bytes) {
        let assert Ok(_) = store.put(key, bytes)
        Error(server.Unavailable)
      },
      store.get,
    )
  let assert Error(server.Storage(server.Unavailable)) =
    server.archive_segment_next(db, fail, 0)
  let planned = keys(root, session.id)
  assert list.length(planned) == 1
  let unavailable =
    server.ObjectStore(store.put, fn(_) { Error(server.Unavailable) })
  let assert Ok(restored) = server.read(db, unavailable, session.id, 0)
  assert restored == batches
  let broken_readback = server.ObjectStore(store.put, fn(_) { Ok(<<1, 2, 3>>) })
  let assert Error(server.CorruptArchive) =
    server.archive_segment_next(db, broken_readback, 0)
  let assert Ok(restored) = server.read(db, unavailable, session.id, 0)
  assert restored == batches
  // A fresh worker and freshly constructed directory adapter resume the persisted plan.
  let finished = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(
        finished,
        server.archive_segment_next(db, directory.store(root), 0),
      )
    })
  let assert Ok(Ok(True)) = process.receive(finished, 3000)
  reclaim(db, root)
  assert keys(root, session.id) == planned
  let assert Ok(restored) = server.read_concurrent(db, store, session.id, 0, 16)
  assert restored == batches
  let bomb = server.ObjectStore(store.put, fn(_) { Ok(gzip_bomb()) })
  let assert Error(server.CorruptArchive) = server.read(db, bomb, session.id, 0)
  Nil
}

fn concurrent_publication(
  db: pog.Connection,
  store: server.ObjectStore,
  root: String,
) -> Nil {
  let session = session("concurrent-publication")
  let assert Ok(#(recorder, _)) = retrace.start(wire.origin(session), "0")
  let #(_, _) = append(db, session, recorder, 8, 1, "1")
  let entered = process.new_subject()
  let completed = process.new_subject()
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
      process.send(completed, server.archive_segment_next(db, blocking, 0))
    })
  let assert Ok(release) = process.receive(entered, 3000)
  // A second worker neither waits for the in-flight put nor shares its attempt.
  let assert Ok(True) = server.archive_segment_next(db, store, 0)
  // The fence does not wait for the remote call; erasure waits for its attempt.
  let assert Ok(_) = server.fence(db, session.id)
  let assert Error(server.Deleted) = server.read(db, store, session.id, 0)
  let assert Ok(server.AwaitingWriters(1)) =
    server.erase(
      db,
      server.Eraser(fn(key) { directory.remove(root, key) }, fn(_) {
        server.MayPublish
      }),
      session.id,
    )
  process.send(release, Nil)
  let assert Ok(Error(server.Deleted)) = process.receive(completed, 3000)
  let old_keys = keys(root, session.id)
  erase(db, root, session.id)
  assert keys(root, session.id) == []
  // Retained deletion inventory removes a late ambiguous generation PUT again.
  let assert Ok(key) = list.first(old_keys)
  let assert Ok(_) = store.put(key, <<1>>)
  erase(db, root, session.id)
  assert keys(root, session.id) == []
  Nil
}

fn legacy_upgrade(
  db: pog.Connection,
  store: server.ObjectStore,
  root: String,
) -> Nil {
  let session = session("legacy-upgrade")
  let assert Ok(#(recorder, _)) = retrace.start(wire.origin(session), "0")
  let #(_, expected) = append(db, session, recorder, 130, 1, "1")
  list.each(list.repeat(Nil, 130), fn(_) {
    let assert Ok(True) = server.archive_next(db, store)
  })
  assert list.length(keys(root, session.id)) == 130
  let assert Ok(before) = server.read(db, store, session.id, 0)
  assert before == list.take(expected, 128)
  let entered = process.new_subject()
  let complete = process.new_subject()
  let calls = counter()
  let measured =
    server.ObjectStore(store.put, fn(key) {
      case increment(calls) <= 16 {
        True -> {
          let release = process.new_subject()
          process.send(entered, release)
          let assert Ok(Nil) = process.receive(release, 5000)
          Nil
        }
        False -> Nil
      }
      store.get(key)
    })
  let _ =
    process.spawn(fn() {
      process.send(complete, server.archive_segment_next(db, measured, 0))
    })
  let releases =
    list.map(list.repeat(Nil, 16), fn(_) {
      let assert Ok(release) = process.receive(entered, 3000)
      release
    })
  // The first window occupies every worker; no seventeenth GET starts.
  assert count(calls) == 16
  process.sleep(50)
  assert count(calls) == 16
  list.each(releases, fn(release) { process.send(release, Nil) })
  let assert Ok(Ok(True)) = process.receive(complete, 3000)
  // One GET per legacy source, plus the new generation's readback.
  assert count(calls) == 131
  reclaim(db, root)
  assert list.length(keys(root, session.id)) == 1
  let assert Ok(first) = server.read_concurrent(db, store, session.id, 0, 16)
  let assert Ok(last) = server.read_concurrent(db, store, session.id, 128, 16)
  assert list.append(first, last) == expected
  Nil
}

fn oversized(
  db: pog.Connection,
  store: server.ObjectStore,
  root: String,
) -> Nil {
  let session = session("oversized-segment")
  let assert Ok(#(recorder, _)) = retrace.start(wire.origin(session), "0")
  let #(_, expected) =
    append(db, session, recorder, 38, 1, string.repeat("x", 900_000))
  let assert Ok(True) = server.archive_segment_next(db, store, 0)
  assert keys(root, session.id) == []
  let assert Ok(False) = server.archive_segment_next(db, store, 0)
  let unavailable =
    server.ObjectStore(store.put, fn(_) { Error(server.Unavailable) })
  let assert Ok(restored) = server.read(db, unavailable, session.id, 0)
  assert restored == expected
  Nil
}

// The first preparation reads an old segment outside the database lock. New
// admission and a second replacement complete before the first read resumes.
fn preparation_race(
  db: pog.Connection,
  store: server.ObjectStore,
  root: String,
) -> Nil {
  let session = session("preparation-race")
  let assert Ok(#(recorder, _)) = retrace.start(wire.origin(session), "0")
  let #(recorder, first) = append(db, session, recorder, 100, 100, "1")
  let assert Ok(True) = server.archive_segment_next(db, store, 0)
  let #(recorder, second) = append(db, session, recorder, 100, 100, "1")
  let entered = process.new_subject()
  let complete = process.new_subject()
  let calls = counter()
  let blocked =
    server.ObjectStore(store.put, fn(key) {
      case increment(calls) {
        1 -> {
          let release = process.new_subject()
          process.send(entered, release)
          let assert Ok(Nil) = process.receive(release, 5000)
          Nil
        }
        _ -> Nil
      }
      store.get(key)
    })
  let _ =
    process.spawn(fn() {
      process.send(complete, server.archive_segment_next(db, blocked, 0))
    })
  let assert Ok(release) = process.receive(entered, 3000)
  let admitted = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(admitted, append(db, session, recorder, 100, 100, "1"))
    })
  let assert Ok(#(recorder, third)) = process.receive(admitted, 1000)
  let replacement = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(replacement, server.archive_segment_next(db, store, 0))
    })
  let assert Ok(Ok(True)) = process.receive(replacement, 3000)
  reclaim(db, root)
  process.send(release, Nil)
  let assert Ok(Ok(False)) = process.receive(complete, 3000)
  assert list.length(keys(root, session.id)) == 1
  let assert Ok(restored) = server.read(db, store, session.id, 0)
  assert restored == list.flatten([first, second, third])
  let assert Ok(False) = server.archive_segment_next(db, store, 0)
  // A fence also completes while preparation is waiting on a remote read.
  let #(_, _) = append(db, session, recorder, 100, 100, "1")
  let fenced_read = counter()
  let blocked =
    server.ObjectStore(store.put, fn(key) {
      case increment(fenced_read) {
        1 -> {
          let release = process.new_subject()
          process.send(entered, release)
          let assert Ok(Nil) = process.receive(release, 5000)
          Nil
        }
        _ -> Nil
      }
      store.get(key)
    })
  let _ =
    process.spawn(fn() {
      process.send(complete, server.archive_segment_next(db, blocked, 0))
    })
  let assert Ok(release) = process.receive(entered, 3000)
  let fenced = process.new_subject()
  let _ =
    process.spawn(fn() { process.send(fenced, server.fence(db, session.id)) })
  let assert Ok(Ok(_)) = process.receive(fenced, 1000)
  process.send(release, Nil)
  let assert Ok(Error(server.Deleted)) = process.receive(complete, 3000)
  erase(db, root, session.id)
  Nil
}

fn inline_integrity(db: pog.Connection, store: server.ObjectStore) -> Nil {
  let session = session("inline-integrity")
  let assert Ok(#(recorder, _)) = retrace.start(wire.origin(session), "0")
  let #(_, _) = append(db, session, recorder, 1, 1, "1")
  let assert Ok(_) =
    pog.query(
      "UPDATE retrace_chunks SET payload=payload || ' ' WHERE session_id=$1",
    )
    |> pog.parameter(pog.text(session.id))
    |> pog.execute(db)
  let assert Error(server.CorruptArchive) =
    server.read(db, store, session.id, 0)
  let assert Error(server.CorruptArchive) =
    server.archive_segment_next(db, store, 0)
  // Restore the fixture so later tests cannot select its deliberately bad bytes.
  let assert Ok(_) =
    pog.query(
      "UPDATE retrace_chunks SET payload=rtrim(payload) WHERE session_id=$1",
    )
    |> pog.parameter(pog.text(session.id))
    |> pog.execute(db)
  let assert Ok(True) = server.archive_segment_next(db, store, 0)
  Nil
}
