//// Erasure coordination for uploads whose remote outcome is uncertain. A
//// controlled provider keeps an accepted PUT pending after the caller saw a
//// failure, so every schedule below is explicit and none depends on timing.
//// The host decides quiescence through the `quiesced` function it supplies.

import envoy
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import pog
import retrace
import retrace/wire
import retrace_server as server
import retrace_server/directory

pub type Provider

@external(erlang, "quiescence_checks_ffi", "provider")
fn provider() -> Provider

@external(erlang, "quiescence_checks_ffi", "pend")
fn pend(provider: Provider, key: String, bytes: BitArray) -> Nil

@external(erlang, "quiescence_checks_ffi", "publish")
fn publish(provider: Provider, key: String, bytes: BitArray) -> Nil

@external(erlang, "quiescence_checks_ffi", "publish_pending")
fn publish_pending(provider: Provider) -> Int

@external(erlang, "quiescence_checks_ffi", "get")
fn get(provider: Provider, key: String) -> Result(BitArray, server.StorageError)

@external(erlang, "quiescence_checks_ffi", "remove")
fn remove(provider: Provider, key: String) -> Result(Nil, server.StorageError)

@external(erlang, "quiescence_checks_ffi", "objects")
fn objects(provider: Provider) -> List(String)

@external(erlang, "quiescence_checks_ffi", "puts")
fn puts(provider: Provider) -> Int

/// put retains a pending provider operation and reports Unavailable.
fn uncertain(provider: Provider) -> server.ObjectStore {
  server.ObjectStore(
    fn(key, bytes) {
      pend(provider, key, bytes)
      Error(server.Unavailable)
    },
    get(provider, _),
  )
}

fn accepting(provider: Provider) -> server.ObjectStore {
  server.ObjectStore(
    fn(key, bytes) {
      publish(provider, key, bytes)
      Ok(Nil)
    },
    get(provider, _),
  )
}

/// A host that holds no proof for any attempt.
fn unproven(provider: Provider) -> server.Eraser {
  server.Eraser(remove(provider, _), fn(_) { server.MayPublish })
}

/// A host whose policy proves every attempt quiescent, for the stated reason.
fn proven(provider: Provider) -> server.Eraser {
  server.Eraser(remove(provider, _), fn(_) {
    server.Quiescent("check: provider confirmed")
  })
}

pub fn run(db: pog.Connection) -> Nil {
  regression(db)
  normal_completion(db)
  worker_dies_after_dispatch(db)
  paused_worker_after_fence(db)
  multiple_attempts_and_keys(db)
  failed_deletion_is_retryable(db)
  idempotent_fence_and_erasure(db)
  rolled_back_fence(db)
  paused_after_admission(db)
  host_decides_from_failure_age(db)
  elapsed_time_is_floored(db)
  legacy_schema_is_refused(db)
  restricted_runtime_role(db)
  io.println(
    "PASS uncertain PUT keeps erasure incomplete until the host proves quiescence, dead and paused workers, multiple attempts and keys, failed deletion, idempotence, caller rollback, a worker paused after admission, host policy over time since failure, floored elapsed time, refusal of a legacy schema and a restricted runtime role",
  )
}

fn session(id: String) -> wire.Session {
  wire.Session(id, "quiescence-check", "counter-v1", "counter-v1", "erlang")
}

/// Admit one more batch of a session and return its recorder.
fn admit(
  db: pog.Connection,
  session: wire.Session,
  recorder: retrace.Recorder,
) -> retrace.Recorder {
  let checkpoint = retrace.checkpoint(recorder, "0")
  let assert Ok(#(next, entry)) =
    retrace.record(recorder, wire.Event("Add", "1"), 5)
  let assert Ok(_) = server.accept(db, wire.Batch(session, checkpoint, [entry]))
  next
}

fn admitted(
  db: pog.Connection,
  id: String,
) -> #(wire.Session, retrace.Recorder) {
  let session = session(id)
  let assert Ok(#(recorder, _)) = retrace.start(wire.origin(session), "0")
  #(session, admit(db, session, recorder))
}

/// The old signal a host polled. It means definitive completion only.
fn reconciled(db: pog.Connection, id: String) -> Bool {
  let assert Ok(returned) =
    pog.query(
      "SELECT reconciled_at IS NOT NULL FROM retrace_tombstones WHERE session_id=$1",
    )
    |> pog.parameter(pog.text(id))
    |> pog.returning(decode.field(0, decode.bool, decode.success))
    |> pog.execute(db)
  let assert [flag] = returned.rows
  flag
}

fn attempts(db: pog.Connection, id: String) -> List(server.WriteAttempt) {
  let assert Ok(found) = server.write_attempts(db, id, 100)
  found
}

fn erase_until_erased(
  db: pog.Connection,
  eraser: server.Eraser,
  id: String,
) -> Nil {
  let assert Ok(state) = server.erase(db, eraser, id)
  case state {
    server.Erased -> Nil
    server.Erasing -> erase_until_erased(db, eraser, id)
    server.AwaitingWriters(_) -> panic as "an unproven writer remains"
  }
}

// The reproduced schedule: PUT fails while the provider retains it, a DELETE
// succeeds, then the PUT publishes. Erasure must not have reported completion.
fn regression(db: pog.Connection) -> Nil {
  let provider = provider()
  let #(session, _) = admitted(db, "uncertain-put")
  let assert Error(server.Storage(server.Unavailable)) =
    server.archive_segment_next(db, uncertain(provider), 0)
  assert objects(provider) == []
  // The failed return is recorded as a fact and is not proof of quiescence.
  let assert [server.WriteAttempt(state: server.Failed, ..)] =
    attempts(db, session.id)
  let assert Ok(_) = server.fence(db, session.id)
  let assert Ok(server.AwaitingWriters(1)) =
    server.erase(db, unproven(provider), session.id)
  assert !reconciled(db, session.id)
  assert publish_pending(provider) == 1
  assert list.length(objects(provider)) == 1
  // The late PUT landed after that DELETE, and erasure is still not complete.
  let assert Ok(server.AwaitingWriters(1)) =
    server.erase(db, unproven(provider), session.id)
  assert !reconciled(db, session.id)
  assert list.length(objects(provider)) == 1
  let assert Ok(Some(server.AwaitingWriters(1))) =
    server.erasure_status(db, session.id)
  // The host later proves quiescence; the next pass records its basis and
  // deletes the late object.
  erase_until_erased(db, proven(provider), session.id)
  assert objects(provider) == []
  assert reconciled(db, session.id)
  let assert [
    server.WriteAttempt(
      state: server.Quiesced,
      basis: Some("check: provider confirmed"),
      ..,
    ),
  ] = attempts(db, session.id)
  let assert Ok(Some(server.Erased)) = server.erasure_status(db, session.id)
  Nil
}

fn normal_completion(db: pog.Connection) -> Nil {
  let provider = provider()
  let #(session, _) = admitted(db, "normal-archive")
  let assert Ok(True) = server.archive_segment_next(db, accepting(provider), 0)
  assert list.length(objects(provider)) == 1
  let assert [server.WriteAttempt(state: server.Completed, ..)] =
    attempts(db, session.id)
  let assert Ok(_) = server.fence(db, session.id)
  // A completed attempt needs no host decision.
  let asked = process.new_subject()
  let eraser =
    server.Eraser(remove(provider, _), fn(attempt) {
      process.send(asked, attempt)
      server.MayPublish
    })
  let assert Ok(server.Erased) = server.erase(db, eraser, session.id)
  let assert Error(Nil) = process.receive(asked, 0)
  assert objects(provider) == []
  assert reconciled(db, session.id)
  Nil
}

fn worker_dies_after_dispatch(db: pog.Connection) -> Nil {
  let provider = provider()
  let #(session, _) = admitted(db, "dead-worker")
  let entered = process.new_subject()
  let hanging =
    server.ObjectStore(
      fn(key, bytes) {
        pend(provider, key, bytes)
        process.send(entered, Nil)
        process.sleep_forever()
        Error(server.Unavailable)
      },
      get(provider, _),
    )
  let worker =
    process.spawn_unlinked(fn() {
      let _ = server.archive_segment_next(db, hanging, 0)
      Nil
    })
  let assert Ok(Nil) = process.receive(entered, 3000)
  // Dispatched and not returned: in flight, whether alive or dead.
  let assert [server.WriteAttempt(state: server.InFlight, ..)] =
    attempts(db, session.id)
  process.kill(worker)
  // A restart sees the same durable schema and the same attempt.
  let assert Ok(_) = server.migrate(db)
  let assert [server.WriteAttempt(state: server.InFlight, ..)] =
    attempts(db, session.id)
  let assert Ok(_) = server.fence(db, session.id)
  let assert Ok(server.AwaitingWriters(1)) =
    server.erase(db, unproven(provider), session.id)
  assert publish_pending(provider) == 1
  let assert Ok(server.AwaitingWriters(1)) =
    server.erase(db, unproven(provider), session.id)
  erase_until_erased(db, proven(provider), session.id)
  assert objects(provider) == []
  Nil
}

fn paused_worker_after_fence(db: pog.Connection) -> Nil {
  let provider = provider()
  let #(session, _) = admitted(db, "paused-worker")
  let assert Error(server.Storage(server.Unavailable)) =
    server.archive_segment_next(db, uncertain(provider), 0)
  let first = puts(provider)
  // The worker reads the persisted plan, then waits on the session lock that
  // the uncommitted fence holds. It resumes only after the fence commits.
  let result = process.new_subject()
  let assert Ok(Nil) =
    pog.transaction(db, fn(tx) {
      let assert Ok(_) = server.fence_in_transaction(tx, session.id)
      let _ =
        process.spawn(fn() {
          process.send(
            result,
            server.archive_segment_next(db, uncertain(provider), 0),
          )
        })
      wait_for_lock_waiter(db, 200)
      Ok(Nil)
    })
  let assert Ok(Error(server.Deleted)) = process.receive(result, 3000)
  assert puts(provider) == first
  let assert Ok(False) = server.archive_segment_next(db, uncertain(provider), 0)
  assert puts(provider) == first
  let assert [_] = attempts(db, session.id)
  Nil
}

fn wait_for_lock_waiter(db: pog.Connection, left: Int) -> Nil {
  let assert Ok(returned) =
    pog.query(
      "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted",
    )
    |> pog.returning(decode.field(0, decode.int, decode.success))
    |> pog.execute(db)
  case returned.rows, left {
    [0], 0 -> panic as "the worker never reached the session lock"
    [0], _ -> {
      process.sleep(10)
      wait_for_lock_waiter(db, left - 1)
    }
    _, _ -> Nil
  }
}

// Two attempts on a planned key plus a current and retired generation: every
// key stays accounted for and is deleted once its own attempts are proven.
fn multiple_attempts_and_keys(db: pog.Connection) -> Nil {
  let provider = provider()
  let #(session, recorder) = admitted(db, "many-keys")
  let assert Ok(True) = server.archive_segment_next(db, accepting(provider), 0)
  let recorder = admit(db, session, recorder)
  let assert Ok(True) = server.archive_segment_next(db, accepting(provider), 0)
  let _ = admit(db, session, recorder)
  let assert Error(server.Storage(_)) =
    server.archive_segment_next(db, uncertain(provider), 0)
  let assert Error(server.Storage(_)) =
    server.archive_segment_next(db, uncertain(provider), 0)
  assert list.length(objects(provider)) == 2
  let assert Ok(_) = server.fence(db, session.id)
  let assert Ok(server.AwaitingWriters(2)) =
    server.erase(db, unproven(provider), session.id)
  // Only the planned key is held back: both published generations are gone.
  assert objects(provider) == []
  assert publish_pending(provider) == 2
  assert list.length(objects(provider)) == 1
  // The host proves only the older attempt; the key stays until both are proven.
  let assert [first, second] =
    list.filter(attempts(db, session.id), fn(a) { a.state == server.Failed })
  assert first.object_key == second.object_key
  let oldest_only =
    server.Eraser(remove(provider, _), fn(attempt) {
      case attempt.id == first.id {
        True -> server.Quiescent("first only")
        False -> server.MayPublish
      }
    })
  let assert Ok(server.AwaitingWriters(1)) =
    server.erase(db, oldest_only, session.id)
  assert list.length(objects(provider)) == 1
  erase_until_erased(db, proven(provider), session.id)
  assert objects(provider) == []
  Nil
}

fn failed_deletion_is_retryable(db: pog.Connection) -> Nil {
  let provider = provider()
  let #(session, _) = admitted(db, "failed-delete")
  let assert Ok(True) = server.archive_segment_next(db, accepting(provider), 0)
  let assert Ok(_) = server.fence(db, session.id)
  let failing =
    server.Eraser(fn(_) { Error(server.Unavailable) }, fn(_) {
      server.MayPublish
    })
  let assert Error(server.Storage(server.Unavailable)) =
    server.erase(db, failing, session.id)
  assert !reconciled(db, session.id)
  let assert Ok(Some(server.Erasing)) = server.erasure_status(db, session.id)
  assert list.length(objects(provider)) == 1
  erase_until_erased(db, unproven(provider), session.id)
  assert objects(provider) == []
  Nil
}

fn idempotent_fence_and_erasure(db: pog.Connection) -> Nil {
  let provider = provider()
  let #(session, _) = admitted(db, "idempotent")
  let assert Ok(True) = server.archive_segment_next(db, accepting(provider), 0)
  let assert Ok(_) = server.fence(db, session.id)
  let assert Ok(_) = server.fence(db, session.id)
  erase_until_erased(db, unproven(provider), session.id)
  let assert Ok(_) = server.fence(db, session.id)
  let assert Ok(server.Erased) =
    server.erase(db, unproven(provider), session.id)
  let assert Ok(server.Erased) =
    server.erase(db, unproven(provider), session.id)
  let assert Ok(Some(server.Erased)) = server.erasure_status(db, session.id)
  assert list.length(attempts(db, session.id)) == 1
  let assert Ok(False) = server.archive_segment_next(db, accepting(provider), 0)
  assert objects(provider) == []
  Nil
}

fn rolled_back_fence(db: pog.Connection) -> Nil {
  let provider = provider()
  let #(session, _) = admitted(db, "rolled-back-fence")
  let assert Error(pog.TransactionRolledBack(Nil)) =
    pog.transaction(db, fn(tx) {
      let assert Ok(_) = server.fence_in_transaction(tx, session.id)
      Error(Nil)
    })
  let assert Ok(None) = server.erasure_status(db, session.id)
  // The rolled-back fence left no tombstone, so archival still proceeds.
  let assert Ok(True) = server.archive_segment_next(db, accepting(provider), 0)
  let assert Ok(_) = server.read(db, accepting(provider), session.id, 0)
  Nil
}

// A worker can pause after its attempt is admitted and before it sends the
// PUT, so no time since admission bounds a remote write. The conservative
// recipe only trusts time since a failure that was actually returned.
fn paused_after_admission(db: pog.Connection) -> Nil {
  let provider = provider()
  let #(session, _) = admitted(db, "paused-after-admission")
  let entered = process.new_subject()
  let finished = process.new_subject()
  let paused =
    server.ObjectStore(
      fn(key, bytes) {
        let release = process.new_subject()
        process.send(entered, release)
        let assert Ok(Nil) = process.receive(release, 3000)
        pend(provider, key, bytes)
        Error(server.Unavailable)
      },
      get(provider, _),
    )
  let _ =
    process.spawn(fn() {
      process.send(finished, server.archive_segment_next(db, paused, 0))
    })
  // The attempt is admitted and the PUT is not sent yet.
  let assert Ok(release) = process.receive(entered, 3000)
  let assert [
    server.WriteAttempt(state: server.InFlight, since_failure_seconds: None, ..),
  ] = attempts(db, session.id)
  assert objects(provider) == [] && puts(provider) == 0
  let assert Ok(_) = server.fence(db, session.id)
  let recipe = fn(limit) {
    server.Eraser(remove(provider, _), fn(attempt) {
      case attempt.state, attempt.since_failure_seconds {
        server.Failed, Some(elapsed) if elapsed >= limit ->
          server.Quiescent("the failure returned long enough ago")
        _, _ -> server.MayPublish
      }
    })
  }
  let assert Ok(server.AwaitingWriters(1)) =
    server.erase(db, recipe(0), session.id)
  // The worker resumes after the fence and sends the PUT it had admitted.
  process.send(release, Nil)
  let assert Ok(Error(server.Storage(server.Unavailable))) =
    process.receive(finished, 3000)
  assert puts(provider) == 1
  let assert [
    server.WriteAttempt(
      state: server.Failed,
      since_failure_seconds: Some(_),
      ..,
    ),
  ] = attempts(db, session.id)
  assert publish_pending(provider) == 1
  // Just after the failure a long qualified bound still proves nothing.
  let assert Ok(server.AwaitingWriters(1)) =
    server.erase(db, recipe(3600), session.id)
  assert list.length(objects(provider)) == 1
  erase_until_erased(db, recipe(0), session.id)
  assert objects(provider) == []
  Nil
}

// Quiescence is the host's policy over typed facts: whether the PUT returned
// an error, and how long ago. Retrace infers nothing from either.
fn host_decides_from_failure_age(db: pog.Connection) -> Nil {
  // The directory adapter finishes writes inside the calling process, so a
  // returned failure is quiescent and a call that never returned is not.
  let at = fn(state) {
    server.WriteAttempt(
      id: 1,
      session_id: "s",
      object_key: "k",
      state: state,
      basis: None,
      since_admission_seconds: 0,
      since_failure_seconds: None,
    )
  }
  let assert server.Quiescent(_) = directory.quiesced(at(server.Failed))
  let assert server.MayPublish = directory.quiesced(at(server.InFlight))

  let provider = provider()
  let #(session, _) = admitted(db, "host-failure-age-policy")
  let assert Error(_) = server.archive_segment_next(db, uncertain(provider), 0)
  let assert Ok(_) = server.fence(db, session.id)
  let failed_for = fn(limit) {
    server.Eraser(remove(provider, _), fn(attempt) {
      case attempt.since_failure_seconds {
        Some(elapsed) if elapsed >= limit ->
          server.Quiescent("the provider bound has elapsed")
        _ -> server.MayPublish
      }
    })
  }
  let assert Ok(server.AwaitingWriters(1)) =
    server.erase(db, failed_for(3600), session.id)
  let assert Ok(server.Erased) = server.erase(db, failed_for(0), session.id)
  Nil
}

// Elapsed time never rounds up: 899.6 seconds is 899, so a 900 second bound
// has not yet passed.
fn elapsed_time_is_floored(db: pog.Connection) -> Nil {
  let provider = provider()
  let #(session, _) = admitted(db, "floored-time")
  let assert Error(_) = server.archive_segment_next(db, uncertain(provider), 0)
  let assert Ok(_) =
    pog.query(
      "UPDATE retrace_write_attempts SET admitted_at=clock_timestamp()-interval '899.6 seconds', failed_at=clock_timestamp()-interval '899.6 seconds' WHERE session_id=$1",
    )
    |> pog.parameter(pog.text(session.id))
    |> pog.execute(db)
  let assert [
    server.WriteAttempt(
      since_admission_seconds: 899,
      since_failure_seconds: Some(899),
      ..,
    ),
  ] = attempts(db, session.id)
  // Leave no pending plan for the global archive worker of later checks.
  let assert Ok(_) = server.fence(db, session.id)
  erase_until_erased(db, proven(provider), session.id)
  Nil
}

// A schema from before write attempts cannot be adopted in place: migrate must
// refuse it before changing anything.
fn legacy_schema_is_refused(db: pog.Connection) -> Nil {
  let exists = fn(tx, name) {
    let assert Ok(returned) =
      pog.query("SELECT to_regclass($1) IS NOT NULL")
      |> pog.parameter(pog.text(name))
      |> pog.returning(decode.field(0, decode.bool, decode.success))
      |> pog.execute(tx)
    returned.rows == [True]
  }
  let assert Error(pog.TransactionRolledBack(Nil)) =
    pog.transaction(db, fn(tx) {
      let exec = fn(sql) {
        let assert Ok(_) = pog.query(sql) |> pog.execute(tx)
        Nil
      }
      exec("CREATE SCHEMA legacy_check")
      exec("SET LOCAL search_path TO legacy_check")
      exec(
        "CREATE TABLE retrace_tombstones (session_id text PRIMARY KEY, fenced_at timestamptz NOT NULL DEFAULT now(), reconciled_at timestamptz)",
      )
      let assert Error(server.UnsupportedSchema(_)) = server.migrate(tx)
      assert !exists(tx, "retrace_write_attempts")
      assert !exists(tx, "retrace_sessions")
      Error(Nil)
    })
  Nil
}

// The documented runtime privileges are enough, and the attempt sequence is
// one of them.
fn restricted_runtime_role(db: pog.Connection) -> Nil {
  let exec = fn(sql) {
    let assert Ok(_) = pog.query(sql) |> pog.execute(db)
    Nil
  }
  exec(
    "DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='retrace_runtime') THEN CREATE ROLE retrace_runtime LOGIN; END IF; END $$",
  )
  exec(
    "GRANT SELECT,INSERT,UPDATE,DELETE ON retrace_tombstones,retrace_deletion_objects,retrace_sessions,retrace_chunks,retrace_archive_objects,retrace_archive_deferrals,retrace_write_attempts TO retrace_runtime",
  )
  let assert Ok(url) = envoy.get("DATABASE_URL")
  let assert Ok(config) =
    pog.url_config(
      process.new_name("restricted"),
      string.replace(url, "retrace@", "retrace_runtime@"),
    )
  let assert Ok(started) = pog.start(config)
  let runtime = started.data
  let provider = provider()
  let #(session, _) = admitted(db, "restricted-runtime")
  // Without sequence USAGE the attempt cannot be admitted.
  let assert Error(server.Database(_)) =
    server.archive_segment_next(runtime, accepting(provider), 0)
  exec(
    "GRANT USAGE ON SEQUENCE retrace_write_attempts_attempt_id_seq TO retrace_runtime",
  )
  let assert Ok(True) =
    server.archive_segment_next(runtime, accepting(provider), 0)
  let assert Ok(_) = server.fence(runtime, session.id)
  erase_until_erased(runtime, proven(provider), session.id)
  assert objects(provider) == []
  Nil
}
