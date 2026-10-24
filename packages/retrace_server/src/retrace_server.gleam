//// Durable admission, session indexing and archival. The caller owns the pool,
//// object store, migrations and worker lifetime; no process starts on import.

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pog
import retrace/wire.{type Batch, type Session}
import retrace_server/internal/archive
import retrace_server/internal/read_worker

pub type StorageError {
  Unavailable
  Missing
  InvalidObject
}

pub type ObjectStore {
  ObjectStore(
    put: fn(String, BitArray) -> Result(Nil, StorageError),
    get: fn(String) -> Result(BitArray, StorageError),
  )
}

pub type Error {
  InvalidBatch(wire.Error)
  Database(pog.QueryError)
  /// The database holds a schema from before write attempts. `migrate` refuses
  /// it unchanged: start from an empty database.
  UnsupportedSchema(String)
  Conflict
  OutOfOrder(expected: Int, received: Int)
  NotFound
  Storage(StorageError)
  CorruptArchive
  Deleted
}

/// Where a recorded upload stands. Only `InFlight` and `Failed` can still
/// publish; neither is proof that it will not.
pub type WriteState {
  /// Admitted, and no outcome recorded. The PUT may not have been sent yet, may
  /// be on the wire, or may have been lost with its caller. No clock bounds it:
  /// a paused worker can still send arbitrarily long after admission. Proving it
  /// quiescent needs two facts: no local dispatch can still happen, and no
  /// request already issued can publish. Stopping the worker or revoking its
  /// credentials establishes at most the first.
  InFlight
  /// `put` returned an error. The provider may still finish the request.
  Failed
  /// `put` returned success, so the provider finished the write.
  Completed
  /// The host's `quiesced` function proved that it cannot publish later.
  Quiesced
}

/// One admitted upload dispatch, retained with its session and immutable key.
pub type WriteAttempt {
  WriteAttempt(
    id: Int,
    session_id: String,
    object_key: String,
    state: WriteState,
    /// The host's stated reason once the attempt is `Quiesced`.
    basis: Option(String),
    /// Whole seconds since admission, rounded down, from the database clock.
    /// Admission precedes the PUT by an unbounded pause, so this is not a bound
    /// on any remote write.
    since_admission_seconds: Int,
    /// Whole seconds, rounded down, since `put` returned its error. The request
    /// was sent before that return, so a provider-qualified maximum request
    /// lifetime elapsed since then covers it. `None` until a failure is recorded.
    since_failure_seconds: Option(Int),
  )
}

/// The host's answer to whether an upload can still publish. Retrace never
/// infers it from errors, time or process liveness.
pub type Quiescence {
  MayPublish
  Quiescent(basis: String)
}

/// What erasure needs from the host: object removal, and the host's own
/// decision on each attempt that might still publish. `quiesced` runs inside
/// the session lock on every pass, so it answers from local state.
pub type Eraser {
  Eraser(
    remove: fn(String) -> Result(Nil, StorageError),
    quiesced: fn(WriteAttempt) -> Quiescence,
  )
}

/// Progress of erasing a fenced session. Only `Erased` is definitive.
pub type Erasure {
  /// No upload can publish later; further passes delete the remaining keys.
  Erasing
  /// This many admitted uploads might still publish. Deletion of their keys
  /// waits, and the session stays incompletely erased.
  AwaitingWriters(unresolved: Int)
  /// Every upload is resolved, every inventoried key is deleted and the
  /// recording rows are cleared.
  Erased
}

pub type Summary {
  Summary(
    session: Session,
    sequence: Int,
    elapsed_ms: Int,
    pending: Int,
    archived: Int,
  )
}

type Head {
  Head(sequence: Int, elapsed_ms: Int, metadata: String)
}

type Chunk {
  Chunk(
    session_id: String,
    start: Int,
    payload: Option(String),
    digest: String,
    object_key: String,
    end: Int,
    format: Int,
    archive_digest: Option(String),
  )
}

/// Create the schema. A database that already holds tombstones from before write
/// attempts is refused with `UnsupportedSchema` before any statement runs.
pub fn migrate(db: pog.Connection) -> Result(Nil, Error) {
  use legacy <- result.try(
    pog.query(
      "SELECT to_regclass('retrace_tombstones') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid=to_regclass('retrace_tombstones') AND attname='checked_at' AND NOT attisdropped)",
    )
    |> pog.returning(decode.field(0, decode.bool, decode.success))
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  case legacy.rows {
    [True] ->
      Error(UnsupportedSchema(
        "retrace_tombstones predates write attempts and has no upgrade path; migrate an empty database",
      ))
    _ -> create_schema(db)
  }
}

fn create_schema(db: pog.Connection) -> Result(Nil, Error) {
  [
    "CREATE TABLE IF NOT EXISTS retrace_tombstones (session_id text PRIMARY KEY, fenced_at timestamptz NOT NULL DEFAULT now(), reconciled_at timestamptz, checked_at timestamptz)",
    "CREATE TABLE IF NOT EXISTS retrace_deletion_objects (session_id text NOT NULL REFERENCES retrace_tombstones(session_id), object_key text NOT NULL, deleted_at timestamptz, PRIMARY KEY(session_id,object_key))",
    "CREATE TABLE IF NOT EXISTS retrace_write_attempts (
      attempt_id bigserial PRIMARY KEY, session_id text NOT NULL, object_key text NOT NULL,
      state text NOT NULL DEFAULT 'in_flight' CHECK(state IN ('in_flight','failed','completed','quiesced')),
      basis text, admitted_at timestamptz NOT NULL DEFAULT clock_timestamp(), failed_at timestamptz,
      resolved_at timestamptz,
      CHECK((state IN ('in_flight','failed'))=(resolved_at IS NULL)), CHECK(state<>'failed' OR failed_at IS NOT NULL))",
    "CREATE INDEX IF NOT EXISTS retrace_write_attempts_session ON retrace_write_attempts(session_id, state)",
    "CREATE TABLE IF NOT EXISTS retrace_sessions (
      id text PRIMARY KEY, user_ref text NOT NULL, metadata text NOT NULL,
      sequence bigint NOT NULL DEFAULT 0, elapsed_ms bigint NOT NULL DEFAULT 0,
      created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now())",
    "CREATE INDEX IF NOT EXISTS retrace_user_sessions ON retrace_sessions(user_ref, updated_at DESC)",
    "CREATE TABLE IF NOT EXISTS retrace_chunks (
      session_id text NOT NULL REFERENCES retrace_sessions(id), start_sequence bigint NOT NULL,
      end_sequence bigint NOT NULL, payload text, digest text NOT NULL, object_key text NOT NULL,
      PRIMARY KEY(session_id, start_sequence))",
    "ALTER TABLE retrace_chunks ADD COLUMN IF NOT EXISTS archive_format smallint NOT NULL DEFAULT 1 CHECK(archive_format IN (1,2))",
    "CREATE TABLE IF NOT EXISTS retrace_archive_objects (
      object_key text PRIMARY KEY, session_id text NOT NULL REFERENCES retrace_sessions(id),
      start_sequence bigint NOT NULL, end_sequence bigint NOT NULL, digest text NOT NULL,
      state text NOT NULL CHECK(state IN ('planned','current','retired')), payload text,
      created_at timestamptz NOT NULL DEFAULT now(), last_deleted_at timestamptz,
      CHECK(end_sequence>start_sequence), CHECK((state='planned')=(payload IS NOT NULL)))",
    "CREATE UNIQUE INDEX IF NOT EXISTS retrace_archive_one_plan ON retrace_archive_objects(session_id) WHERE state='planned'",
    "CREATE UNIQUE INDEX IF NOT EXISTS retrace_archive_current_segment ON retrace_archive_objects(session_id,start_sequence) WHERE state='current'",
    "CREATE TABLE IF NOT EXISTS retrace_archive_deferrals (
      session_id text NOT NULL REFERENCES retrace_sessions(id), start_sequence bigint NOT NULL,
      end_sequence bigint NOT NULL, observed_sequence bigint NOT NULL,
      PRIMARY KEY(session_id,start_sequence))",
  ]
  |> list.try_each(fn(sql) {
    pog.query(sql) |> pog.execute(db) |> result.map_error(Database)
  })
}

fn head_decoder() -> decode.Decoder(Head) {
  use sequence <- decode.field(0, decode.int)
  use elapsed <- decode.field(1, decode.int)
  use metadata <- decode.field(2, decode.string)
  decode.success(Head(sequence, elapsed, metadata))
}

fn transaction(
  db: pog.Connection,
  work: fn(pog.Connection) -> Result(value, Error),
) -> Result(value, Error) {
  pog.transaction(db, work)
  |> result.map_error(fn(error) {
    case error {
      pog.TransactionQueryError(error) -> Database(error)
      pog.TransactionRolledBack(error) -> error
    }
  })
}

/// Atomically admit one immutable batch. Exact retries return its end cursor,
/// including after archival; overlapping or differently chunked input conflicts.
pub fn accept(db: pog.Connection, batch: Batch) -> Result(Int, Error) {
  transaction(db, fn(tx) { accept_in_transaction(tx, batch) })
}

/// Compose host authorization/accounting in the same caller-owned transaction.
/// The connection MUST already be inside a transaction; this function does not
/// start or commit one. Never nest pog.transaction (Pog 4 commits nested BEGIN).
pub fn accept_in_transaction(
  tx: pog.Connection,
  batch: Batch,
) -> Result(Int, Error) {
  use _ <- result.try(wire.validate(batch) |> result.map_error(InvalidBatch))
  let payload = wire.encode(batch)
  let digest = digest(payload)
  let metadata = wire.session_json(batch.session) |> json.to_string
  use _ <- result.try(lock_session(tx, batch.session.id))
  use _ <- result.try(require_live(tx, batch.session.id))
  use _ <- result.try(
    pog.query(
      "INSERT INTO retrace_sessions(id,user_ref,metadata) VALUES($1,$2,$3) ON CONFLICT DO NOTHING",
    )
    |> pog.parameter(pog.text(batch.session.id))
    |> pog.parameter(pog.text(batch.session.user_ref))
    |> pog.parameter(pog.text(metadata))
    |> pog.execute(tx)
    |> result.map_error(Database),
  )
  use heads <- result.try(
    pog.query(
      "SELECT sequence,elapsed_ms,metadata FROM retrace_sessions WHERE id=$1 FOR UPDATE",
    )
    |> pog.parameter(pog.text(batch.session.id))
    |> pog.returning(head_decoder())
    |> pog.execute(tx)
    |> result.map_error(Database),
  )
  use head <- result.try(
    list.first(heads.rows) |> result.map_error(fn(_) { NotFound }),
  )
  let duplicate_decoder = {
    use digest <- decode.field(0, decode.string)
    use sequence <- decode.field(1, decode.int)
    decode.success(#(digest, sequence))
  }
  use duplicates <- result.try(
    pog.query(
      "SELECT digest,end_sequence FROM retrace_chunks WHERE session_id=$1 AND start_sequence=$2",
    )
    |> pog.parameter(pog.text(batch.session.id))
    |> pog.parameter(pog.int(batch.checkpoint.sequence))
    |> pog.returning(duplicate_decoder)
    |> pog.execute(tx)
    |> result.map_error(Database),
  )
  case duplicates.rows {
    [#(existing, end), ..] ->
      case existing == digest {
        True -> Ok(end)
        False -> Error(Conflict)
      }
    [] ->
      case head.sequence == batch.checkpoint.sequence {
        False -> Error(OutOfOrder(head.sequence, batch.checkpoint.sequence))
        True ->
          case
            head.metadata == metadata
            && head.elapsed_ms == batch.checkpoint.elapsed_ms
          {
            False -> Error(Conflict)
            True -> {
              let key =
                "sessions/"
                <> batch.session.id
                <> "/"
                <> int.to_string(batch.checkpoint.sequence)
                <> ".json.gz"
              use _ <- result.try(
                pog.query(
                  "INSERT INTO retrace_chunks(session_id,start_sequence,end_sequence,payload,digest,object_key) VALUES($1,$2,$3,$4,$5,$6)",
                )
                |> pog.parameter(pog.text(batch.session.id))
                |> pog.parameter(pog.int(batch.checkpoint.sequence))
                |> pog.parameter(pog.int(wire.end_sequence(batch)))
                |> pog.parameter(pog.text(payload))
                |> pog.parameter(pog.text(digest))
                |> pog.parameter(pog.text(key))
                |> pog.execute(tx)
                |> result.map_error(Database),
              )
              use _ <- result.try(
                pog.query(
                  "UPDATE retrace_sessions SET sequence=$2,elapsed_ms=$3,updated_at=now() WHERE id=$1",
                )
                |> pog.parameter(pog.text(batch.session.id))
                |> pog.parameter(pog.int(wire.end_sequence(batch)))
                |> pog.parameter(pog.int(wire.end_time(batch)))
                |> pog.execute(tx)
                |> result.map_error(Database),
              )
              Ok(wire.end_sequence(batch))
            }
          }
      }
  }
}

fn chunk_decoder() -> decode.Decoder(Chunk) {
  use id <- decode.field(0, decode.string)
  use start <- decode.field(1, decode.int)
  use payload <- decode.field(2, decode.optional(decode.string))
  use digest <- decode.field(3, decode.string)
  use key <- decode.field(4, decode.string)
  use end <- decode.field(5, decode.int)
  use format <- decode.field(6, decode.int)
  use archive_digest <- decode.field(7, decode.optional(decode.string))
  decode.success(Chunk(
    id,
    start,
    payload,
    digest,
    key,
    end,
    format,
    archive_digest,
  ))
}

/// Archive at most one pending batch. The upload is admitted durably before
/// dispatch and outside the lock, so a failed or lost put leaves an attempt that
/// keeps erasure incomplete until the host proves it quiescent.
/// Concurrent workers may upload the same immutable bytes to the same key; the
/// conditional database update is safe.
pub fn archive_next(
  db: pog.Connection,
  store: ObjectStore,
) -> Result(Bool, Error) {
  use chunks <- result.try(
    pog.query(
      "SELECT c.session_id,c.start_sequence,c.payload,c.digest,c.object_key,c.end_sequence,c.archive_format,NULL::text FROM retrace_chunks c WHERE c.payload IS NOT NULL AND NOT EXISTS (SELECT 1 FROM retrace_tombstones t WHERE t.session_id=c.session_id) ORDER BY c.session_id,c.start_sequence LIMIT 1",
    )
    |> pog.returning(chunk_decoder())
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  case chunks.rows {
    [] -> Ok(False)
    [candidate, ..] -> {
      use admitted <- result.try(
        transaction(db, fn(tx) {
          use _ <- result.try(lock_session(tx, candidate.session_id))
          case require_live(tx, candidate.session_id) {
            Error(Deleted) -> Ok(None)
            Error(error) -> Error(error)
            Ok(_) -> {
              use current <- result.try(
                pog.query(
                  "SELECT session_id,start_sequence,payload,digest,object_key,end_sequence,archive_format,NULL::text FROM retrace_chunks WHERE session_id=$1 AND start_sequence=$2",
                )
                |> pog.parameter(pog.text(candidate.session_id))
                |> pog.parameter(pog.int(candidate.start))
                |> pog.returning(chunk_decoder())
                |> pog.execute(tx)
                |> result.map_error(Database),
              )
              case current.rows {
                [Chunk(payload: Some(payload), ..), ..] -> {
                  use attempt <- result.try(admit_write(
                    tx,
                    candidate.session_id,
                    candidate.object_key,
                  ))
                  Ok(Some(#(attempt, payload)))
                }
                _ -> Ok(None)
              }
            }
          }
        }),
      )
      case admitted {
        None -> Ok(False)
        Some(#(attempt, payload)) -> {
          use _ <- result.try(dispatch(
            db,
            store,
            attempt,
            candidate.object_key,
            compress(payload),
          ))
          transaction(db, fn(tx) {
            use _ <- result.try(lock_session(tx, candidate.session_id))
            use _ <- result.try(require_live(tx, candidate.session_id))
            use _ <- result.try(
              pog.query(
                "UPDATE retrace_chunks SET payload=NULL WHERE session_id=$1 AND start_sequence=$2 AND digest=$3",
              )
              |> pog.parameter(pog.text(candidate.session_id))
              |> pog.parameter(pog.int(candidate.start))
              |> pog.parameter(pog.text(candidate.digest))
              |> pog.execute(tx)
              |> result.map_error(Database),
            )
            Ok(True)
          })
        }
      }
    }
  }
}

/// Record, inside the session lock and a committed transaction, that an upload
/// is about to be dispatched. The caller has already checked the fence.
fn admit_write(
  tx: pog.Connection,
  session_id: String,
  key: String,
) -> Result(Int, Error) {
  use rows <- result.try(
    pog.query(
      "INSERT INTO retrace_write_attempts(session_id,object_key) VALUES($1,$2) RETURNING attempt_id",
    )
    |> pog.parameter(pog.text(session_id))
    |> pog.parameter(pog.text(key))
    |> pog.returning(decode.field(0, decode.int, decode.success))
    |> pog.execute(tx)
    |> result.map_error(Database),
  )
  case rows.rows {
    [id] -> Ok(id)
    _ -> Error(Conflict)
  }
}

/// Call put for an admitted attempt, then record what the outcome shows. A
/// returned success means the provider finished the write.
fn dispatch(
  db: pog.Connection,
  store: ObjectStore,
  attempt: Int,
  key: String,
  body: BitArray,
) -> Result(Nil, Error) {
  case store.put(key, body) {
    Ok(_) ->
      settle_write(db, attempt, "completed", Some("put returned success"))
    Error(error) -> {
      // Best effort: if recording fails the attempt stays in flight, which is
      // equally unproven.
      let _ = settle_write(db, attempt, "failed", None)
      Error(Storage(error))
    }
  }
}

/// Move an attempt that might still publish to a state of the given name.
fn settle_write(
  db: pog.Connection,
  attempt: Int,
  state: String,
  basis: Option(String),
) -> Result(Nil, Error) {
  pog.query(
    "UPDATE retrace_write_attempts SET state=$2,basis=$3,resolved_at=CASE WHEN $2 IN ('completed','quiesced') THEN clock_timestamp() END,failed_at=CASE WHEN $2='failed' THEN clock_timestamp() ELSE failed_at END WHERE attempt_id=$1 AND state IN ('in_flight','failed')",
  )
  |> pog.parameter(pog.int(attempt))
  |> pog.parameter(pog.text(state))
  |> pog.parameter(pog.nullable(pog.text, basis))
  |> pog.execute(db)
  |> result.replace(Nil)
  |> result.map_error(Database)
}

fn attempt_decoder() -> decode.Decoder(WriteAttempt) {
  use id <- decode.field(0, decode.int)
  use session <- decode.field(1, decode.string)
  use key <- decode.field(2, decode.string)
  use state <- decode.field(3, decode.string)
  use basis <- decode.field(4, decode.optional(decode.string))
  use admitted <- decode.field(5, decode.int)
  use failed <- decode.field(6, decode.optional(decode.int))
  let state = case state {
    "failed" -> Failed
    "completed" -> Completed
    "quiesced" -> Quiesced
    _ -> InFlight
  }
  decode.success(WriteAttempt(id, session, key, state, basis, admitted, failed))
}

const attempt_select =
  "SELECT attempt_id,session_id,object_key,state,basis,floor(extract(epoch FROM clock_timestamp()-admitted_at))::bigint,floor(extract(epoch FROM clock_timestamp()-failed_at))::bigint FROM retrace_write_attempts"

/// List up to `limit` write attempts of a session, oldest first, with their
/// states and the basis the host gave for each quiescent one.
pub fn write_attempts(
  db: pog.Connection,
  id: String,
  limit: Int,
) -> Result(List(WriteAttempt), Error) {
  pog.query(
    attempt_select <> " WHERE session_id=$1 ORDER BY attempt_id LIMIT $2",
  )
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.int(int.max(limit, 0)))
  |> pog.returning(attempt_decoder())
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.map_error(Database)
}

/// A transaction-scoped lock also exists before first admission, so fencing an
/// unknown session prevents its creation. Hash collisions only serialize work.
fn lock_session(db: pog.Connection, id: String) -> Result(Nil, Error) {
  pog.query(
    "SELECT 1 FROM pg_advisory_xact_lock(hashtextextended('retrace:' || $1, 0))",
  )
  |> pog.parameter(pog.text(id))
  |> pog.execute(db)
  |> result.map(fn(_) { Nil })
  |> result.map_error(Database)
}

fn require_live(db: pog.Connection, id: String) -> Result(Nil, Error) {
  use rows <- result.try(
    pog.query("SELECT session_id FROM retrace_tombstones WHERE session_id=$1")
    |> pog.parameter(pog.text(id))
    |> pog.returning(decode.field(0, decode.string, decode.success))
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  case rows.rows {
    [] -> Ok(Nil)
    _ -> Error(Deleted)
  }
}

/// Commit a permanent admission/read/archive fence and snapshot every known
/// object key. The caller owns authorization and retention deadlines.
pub fn fence(db: pog.Connection, id: String) -> Result(Nil, Error) {
  transaction(db, fn(tx) { fence_in_transaction(tx, id) })
}

/// As fence, within a caller-owned transaction. Does not begin/commit it.
pub fn fence_in_transaction(
  tx: pog.Connection,
  id: String,
) -> Result(Nil, Error) {
  use _ <- result.try(lock_session(tx, id))
  use _ <- result.try(
    pog.query(
      "INSERT INTO retrace_tombstones(session_id) VALUES($1) ON CONFLICT DO NOTHING",
    )
    |> pog.parameter(pog.text(id))
    |> pog.execute(tx)
    |> result.map_error(Database),
  )
  pog.query(
    "INSERT INTO retrace_deletion_objects(session_id,object_key) SELECT session_id,object_key FROM retrace_chunks WHERE session_id=$1 UNION SELECT session_id,object_key FROM retrace_archive_objects WHERE session_id=$1 UNION SELECT session_id,object_key FROM retrace_write_attempts WHERE session_id=$1 ON CONFLICT DO NOTHING",
  )
  |> pog.parameter(pog.text(id))
  |> pog.execute(tx)
  |> result.map(fn(_) { Nil })
  |> result.map_error(Database)
}

fn count(db: pog.Connection, sql: String, id: String) -> Result(Int, Error) {
  use rows <- result.try(
    pog.query(sql)
    |> pog.parameter(pog.text(id))
    |> pog.returning(decode.field(0, decode.int, decode.success))
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  Ok(list.first(rows.rows) |> result.unwrap(0))
}

/// Ask the host about every attempt that might still publish and record each
/// quiescent answer with its basis. A `MayPublish` answer changes nothing.
fn ask_host(
  tx: pog.Connection,
  eraser: Eraser,
  id: String,
) -> Result(Nil, Error) {
  use pending <- result.try(
    pog.query(
      attempt_select
      <> " WHERE session_id=$1 AND state IN ('in_flight','failed') ORDER BY attempt_id",
    )
    |> pog.parameter(pog.text(id))
    |> pog.returning(attempt_decoder())
    |> pog.execute(tx)
    |> result.map_error(Database),
  )
  list.try_each(pending.rows, fn(attempt) {
    case eraser.quiesced(attempt) {
      Quiescent(basis) -> settle_write(tx, attempt.id, "quiesced", Some(basis))
      MayPublish -> Ok(Nil)
    }
  })
}

const unresolved_count =
  "SELECT count(*) FROM retrace_write_attempts WHERE session_id=$1 AND state IN ('in_flight','failed')"

/// Report whether a session is erased, erasing or waiting on uploads that might
/// still publish. `None` means the session has no fence.
pub fn erasure_status(
  db: pog.Connection,
  id: String,
) -> Result(Option(Erasure), Error) {
  use fenced <- result.try(
    pog.query(
      "SELECT reconciled_at IS NOT NULL FROM retrace_tombstones WHERE session_id=$1",
    )
    |> pog.parameter(pog.text(id))
    |> pog.returning(decode.field(0, decode.bool, decode.success))
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  case fenced.rows {
    [] -> Ok(None)
    [True, ..] -> Ok(Some(Erased))
    [False, ..] -> {
      use unresolved <- result.try(count(db, unresolved_count, id))
      case unresolved {
        0 -> Ok(Some(Erasing))
        _ -> Ok(Some(AwaitingWriters(unresolved)))
      }
    }
  }
}

/// Idempotently erase a fenced session and report its definitive state. Each
/// pass first asks the host, through `eraser.quiesced`, about every attempt that
/// might still publish. Keys owned by an attempt not yet proven quiescent are
/// never deleted or counted as done, and the result is `AwaitingWriters`. Each
/// pass deletes at most 8 keys; recording rows are cleared and the tombstone is
/// marked reconciled only once every attempt is completed or quiescent and every
/// key deleted.
/// Repeating a completed session deletes its retained keys again, which also
/// covers a backup restore that brought objects back.
pub fn erase(
  db: pog.Connection,
  eraser: Eraser,
  id: String,
) -> Result(Erasure, Error) {
  transaction(db, fn(tx) {
    use _ <- result.try(lock_session(tx, id))
    use _ <- result.try(case require_live(tx, id) {
      Error(Deleted) -> Ok(Nil)
      Ok(_) -> Error(Conflict)
      Error(error) -> Error(error)
    })
    // A completed tombstone is deliberately swept again; an unfinished one
    // resumes its durable per-object cursor. Every pass handles at most 8 keys.
    use _ <- result.try(
      pog.query(
        "UPDATE retrace_deletion_objects SET deleted_at=NULL WHERE session_id=$1 AND EXISTS (SELECT 1 FROM retrace_tombstones WHERE session_id=$1 AND reconciled_at IS NOT NULL)",
      )
      |> pog.parameter(pog.text(id))
      |> pog.execute(tx)
      |> result.map_error(Database),
    )
    use _ <- result.try(
      pog.query(
        "UPDATE retrace_tombstones SET reconciled_at=NULL,checked_at=clock_timestamp() WHERE session_id=$1",
      )
      |> pog.parameter(pog.text(id))
      |> pog.execute(tx)
      |> result.map_error(Database),
    )
    use _ <- result.try(ask_host(tx, eraser, id))
    use keys <- result.try(
      pog.query(
        "SELECT object_key FROM retrace_deletion_objects d WHERE d.session_id=$1 AND d.deleted_at IS NULL AND NOT EXISTS (SELECT 1 FROM retrace_write_attempts a WHERE a.session_id=d.session_id AND a.object_key=d.object_key AND a.state IN ('in_flight','failed')) ORDER BY object_key LIMIT 8",
      )
      |> pog.parameter(pog.text(id))
      |> pog.returning(decode.field(0, decode.string, decode.success))
      |> pog.execute(tx)
      |> result.map_error(Database),
    )
    use _ <- result.try(
      list.try_each(keys.rows, fn(key) {
        use _ <- result.try(eraser.remove(key) |> result.map_error(Storage))
        pog.query(
          "UPDATE retrace_deletion_objects SET deleted_at=now() WHERE session_id=$1 AND object_key=$2",
        )
        |> pog.parameter(pog.text(id))
        |> pog.parameter(pog.text(key))
        |> pog.execute(tx)
        |> result.replace(Nil)
        |> result.map_error(Database)
      }),
    )
    use unresolved <- result.try(count(tx, unresolved_count, id))
    use remaining <- result.try(count(
      tx,
      "SELECT count(*) FROM retrace_deletion_objects WHERE session_id=$1 AND deleted_at IS NULL",
      id,
    ))
    case unresolved, remaining {
      0, 0 -> {
        use _ <- result.try(
          pog.query("DELETE FROM retrace_archive_objects WHERE session_id=$1")
          |> pog.parameter(pog.text(id))
          |> pog.execute(tx)
          |> result.map_error(Database),
        )
        use _ <- result.try(
          pog.query("DELETE FROM retrace_archive_deferrals WHERE session_id=$1")
          |> pog.parameter(pog.text(id))
          |> pog.execute(tx)
          |> result.map_error(Database),
        )
        use _ <- result.try(
          pog.query("DELETE FROM retrace_chunks WHERE session_id=$1")
          |> pog.parameter(pog.text(id))
          |> pog.execute(tx)
          |> result.map_error(Database),
        )
        use _ <- result.try(
          pog.query("DELETE FROM retrace_sessions WHERE id=$1")
          |> pog.parameter(pog.text(id))
          |> pog.execute(tx)
          |> result.map_error(Database),
        )
        pog.query(
          "UPDATE retrace_tombstones SET reconciled_at=now() WHERE session_id=$1",
        )
        |> pog.parameter(pog.text(id))
        |> pog.execute(tx)
        |> result.map(fn(_) { Erased })
        |> result.map_error(Database)
      }
      0, _ -> Ok(Erasing)
      waiting, _ -> Ok(AwaitingWriters(waiting))
    }
  })
}

/// Advance the least recently checked unfinished tombstone, or one completed
/// longer ago than `interval_seconds`, and report its erasure state. `None`
/// means no tombstone is due.
pub fn erase_next(
  db: pog.Connection,
  eraser: Eraser,
  interval_seconds: Int,
) -> Result(Option(#(String, Erasure)), Error) {
  use rows <- result.try(
    pog.query(
      "SELECT session_id FROM retrace_tombstones WHERE reconciled_at IS NULL OR reconciled_at < now() - ($1 * interval '1 second') ORDER BY checked_at NULLS FIRST, fenced_at LIMIT 1",
    )
    |> pog.parameter(pog.int(int.max(interval_seconds, 1)))
    |> pog.returning(decode.field(0, decode.string, decode.success))
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  case rows.rows {
    [] -> Ok(None)
    [id, ..] ->
      erase(db, eraser, id)
      |> result.map(fn(state) { Some(#(id, state)) })
  }
}

/// Read at most 128 batches after an absolute cursor. Use the last returned
/// entry's sequence for the next page. Archive payload integrity is checked.
pub fn read(
  db: pog.Connection,
  store: ObjectStore,
  id: String,
  after: Int,
) -> Result(List(Batch), Error) {
  read_page(db, store, id, after, None)
}

/// Read the same ordered, verified page as `read`, with independent adapter calls
/// bounded to `concurrency` (clamped to 1..16). The adapter must be safe to invoke
/// from different processes and bound its external I/O. All read-owned workers
/// terminate before return or when the caller dies; borrowed resources are never
/// stopped. An adapter exception becomes `Storage(Unavailable)`. A deletion
/// fence committed while the page was loading refuses the result.
pub fn read_concurrent(
  db: pog.Connection,
  store: ObjectStore,
  id: String,
  after: Int,
  concurrency: Int,
) -> Result(List(Batch), Error) {
  read_page(db, store, id, after, Some(int.clamp(concurrency, min: 1, max: 16)))
}

fn read_concurrent_values(
  values: List(a),
  concurrency: Int,
  read: fn(a) -> Result(b, Error),
) -> Result(List(b), Error) {
  read_worker.run(values, concurrency, read, Storage(Unavailable))
}

fn read_page(
  db: pog.Connection,
  store: ObjectStore,
  id: String,
  after: Int,
  concurrency: Option(Int),
) -> Result(List(Batch), Error) {
  use chunks <- result.try(read_chunks(db, id, after))
  let loaded = load_chunks(store, chunks, concurrency)
  let loaded = case loaded {
    Error(Storage(Missing)) -> {
      use current <- result.try(read_chunks(db, id, after))
      case sources(chunks) != sources(current) {
        True -> load_chunks(store, current, concurrency)
        False -> loaded
      }
    }
    _ -> loaded
  }
  use batches <- result.try(loaded)
  use _ <- result.try(require_live(db, id))
  Ok(batches)
}

fn sources(chunks: List(Chunk)) -> List(#(Int, String, Int)) {
  list.map(chunks, fn(chunk) { #(chunk.start, chunk.object_key, chunk.format) })
}

fn read_chunks(
  db: pog.Connection,
  id: String,
  after: Int,
) -> Result(List(Chunk), Error) {
  use _ <- result.try(require_live(db, id))
  pog.query(
    "SELECT c.session_id,c.start_sequence,c.payload,c.digest,c.object_key,c.end_sequence,c.archive_format,a.digest FROM retrace_chunks c LEFT JOIN retrace_archive_objects a ON a.object_key=c.object_key WHERE c.session_id=$1 AND c.end_sequence>$2 ORDER BY c.start_sequence LIMIT 128",
  )
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.int(after))
  |> pog.returning(chunk_decoder())
  |> pog.execute(db)
  |> result.map(fn(rows) { rows.rows })
  |> result.map_error(Database)
}

fn load_chunks(
  store: ObjectStore,
  chunks: List(Chunk),
  concurrency: Option(Int),
) -> Result(List(Batch), Error) {
  let objects =
    chunks
    |> list.filter(fn(chunk) { chunk.payload == None })
    |> list.map(fn(chunk) { #(chunk.object_key, chunk) })
    |> dict.from_list
    |> dict.values
  let fetch = fn(chunk) {
    use batches <- result.try(read_object(store, chunk))
    Ok(#(chunk.object_key, batches))
  }
  use loaded <- result.try(case concurrency {
    None -> list.try_map(objects, fetch)
    Some(limit) -> read_concurrent_values(objects, limit, fetch)
  })
  let loaded = dict.from_list(loaded)
  list.try_map(chunks, fn(chunk) { batch_for_chunk(chunk, loaded) })
}

fn batch_for_chunk(
  chunk: Chunk,
  loaded: dict.Dict(String, List(Batch)),
) -> Result(Batch, Error) {
  use batch <- result.try(case chunk.payload {
    Some(payload) ->
      case digest(payload) == chunk.digest {
        True -> wire.decode_batch(payload) |> result.map_error(InvalidBatch)
        False -> Error(CorruptArchive)
      }
    None -> {
      use batches <- result.try(
        dict.get(loaded, chunk.object_key)
        |> result.replace_error(CorruptArchive),
      )
      list.find(batches, fn(batch) { batch.checkpoint.sequence == chunk.start })
      |> result.replace_error(CorruptArchive)
    }
  })
  case
    batch.session.id == chunk.session_id
    && wire.end_sequence(batch) == chunk.end
    && digest(wire.encode(batch)) == chunk.digest
  {
    True -> Ok(batch)
    False -> Error(CorruptArchive)
  }
}

fn read_object(store: ObjectStore, chunk: Chunk) -> Result(List(Batch), Error) {
  use body <- result.try(
    store.get(chunk.object_key) |> result.map_error(Storage),
  )
  case chunk.format {
    1 -> {
      use text <- result.try(
        decompress(body) |> result.replace_error(CorruptArchive),
      )
      case digest(text) == chunk.digest {
        True ->
          wire.decode_batch(text)
          |> result.map(fn(batch) { [batch] })
          |> result.map_error(InvalidBatch)
        False -> Error(CorruptArchive)
      }
    }
    2 -> {
      use text <- result.try(
        decompress_bounded(body, archive.max_bytes)
        |> result.replace_error(CorruptArchive),
      )
      case chunk.archive_digest == Some(digest(text)) {
        True -> archive.decode(text) |> result.replace_error(CorruptArchive)
        False -> Error(CorruptArchive)
      }
    }
    _ -> Error(CorruptArchive)
  }
}

@external(erlang, "retrace_server_ffi", "decompress_bounded")
fn decompress_bounded(body: BitArray, limit: Int) -> Result(String, Nil)

/// Exact user-reference filtering; empty filter lists the 100 latest sessions.
/// Authorization and tenant scoping belong to the hosting service.
pub fn sessions(
  db: pog.Connection,
  user_ref: String,
) -> Result(List(Summary), Error) {
  let decoder = {
    use metadata <- decode.field(0, decode.string)
    use sequence <- decode.field(1, decode.int)
    use elapsed <- decode.field(2, decode.int)
    use pending <- decode.field(3, decode.int)
    use archived <- decode.field(4, decode.int)
    case json.parse(metadata, wire.session_decoder()) {
      Ok(session) ->
        decode.success(Summary(session, sequence, elapsed, pending, archived))
      Error(_) ->
        decode.failure(
          Summary(wire.Session("", "", "", "", ""), 0, 0, 0, 0),
          "session metadata",
        )
    }
  }
  pog.query(
    "SELECT s.metadata,s.sequence,s.elapsed_ms,
    (SELECT count(*) FROM retrace_chunks c WHERE c.session_id=s.id AND c.payload IS NOT NULL),
    (SELECT count(*) FROM retrace_chunks c WHERE c.session_id=s.id AND c.payload IS NULL)
    FROM retrace_sessions s WHERE ($1='' OR s.user_ref=$1) AND NOT EXISTS (SELECT 1 FROM retrace_tombstones t WHERE t.session_id=s.id) ORDER BY s.updated_at DESC LIMIT 100",
  )
  |> pog.parameter(pog.text(user_ref))
  |> pog.returning(decoder)
  |> pog.execute(db)
  |> result.map(fn(rows) { rows.rows })
  |> result.map_error(Database)
}

@external(erlang, "retrace_server_ffi", "digest")
fn digest(input: String) -> String

@external(erlang, "retrace_server_ffi", "compress")
fn compress(input: String) -> BitArray

@external(erlang, "retrace_server_ffi", "decompress")
fn decompress(input: BitArray) -> Result(String, Nil)

// The plan payload and every generation key commit before any remote write.
// One plan per session bounds temporary duplicate PostgreSQL storage to 32 MiB.
type ArchivePlan {
  ArchivePlan(
    id: String,
    key: String,
    start: Int,
    end: Int,
    digest: String,
    payload: String,
  )
}

type Prepared {
  Planned(ArchivePlan)
  Deferred
  Skipped
}

fn plan_decoder() -> decode.Decoder(ArchivePlan) {
  use id <- decode.field(0, decode.string)
  use key <- decode.field(1, decode.string)
  use start <- decode.field(2, decode.int)
  use end <- decode.field(3, decode.int)
  use digest <- decode.field(4, decode.string)
  use payload <- decode.field(5, decode.string)
  decode.success(ArchivePlan(id, key, start, end, digest, payload))
}

/// Compact one idle session range into a verified immutable generation containing
/// at most 1000 events in whole original batches. A late arrival replaces its
/// partially filled segment. `True` also reports a durable oversized deferral;
/// sources stay readable and unchanged instead of splitting a small session.
/// Plans are resumed before new work. The host owns scheduling (usually 60s idle).
pub fn archive_segment_next(
  db: pog.Connection,
  store: ObjectStore,
  idle_seconds: Int,
) -> Result(Bool, Error) {
  use plans <- result.try(
    pog.query(
      "SELECT a.session_id,a.object_key,a.start_sequence,a.end_sequence,a.digest,a.payload FROM retrace_archive_objects a WHERE a.state='planned' AND NOT EXISTS(SELECT 1 FROM retrace_tombstones t WHERE t.session_id=a.session_id) ORDER BY a.created_at LIMIT 1",
    )
    |> pog.returning(plan_decoder())
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  case plans.rows {
    [plan, ..] -> publish_plan(db, store, plan)
    [] -> {
      let decoder = {
        use id <- decode.field(0, decode.string)
        use start <- decode.field(1, decode.int)
        use end <- decode.field(2, decode.int)
        use head <- decode.field(3, decode.int)
        decode.success(#(id, start, end, head))
      }
      use candidates <- result.try(
        pog.query(
          "SELECT c.session_id,c.start_sequence,c.end_sequence,s.sequence FROM retrace_chunks c JOIN retrace_sessions s ON s.id=c.session_id WHERE (c.payload IS NOT NULL OR c.archive_format=1) AND s.updated_at<=now()-($1 * interval '1 second') AND NOT EXISTS(SELECT 1 FROM retrace_tombstones t WHERE t.session_id=c.session_id) AND NOT EXISTS(SELECT 1 FROM retrace_archive_deferrals d WHERE d.session_id=c.session_id AND d.observed_sequence=s.sequence AND c.start_sequence>=d.start_sequence AND c.end_sequence<=d.end_sequence) ORDER BY s.updated_at,c.session_id,c.start_sequence LIMIT 1",
        )
        |> pog.parameter(pog.int(int.max(idle_seconds, 0)))
        |> pog.returning(decoder)
        |> pog.execute(db)
        |> result.map_error(Database),
      )
      case candidates.rows {
        [] -> Ok(False)
        [candidate, ..] -> {
          use prepared <- result.try(prepare_segment(db, store, candidate))
          case prepared {
            Planned(plan) -> publish_plan(db, store, plan)
            Deferred -> Ok(True)
            Skipped -> Ok(False)
          }
        }
      }
    }
  }
}

type Snapshot {
  Snapshot(id: String, start: Int, end: Int, head: Int, chunks: List(Chunk))
}

type Preparation {
  Finished(Prepared)
  Gather(Snapshot)
}

fn prepare_segment(
  db: pog.Connection,
  store: ObjectStore,
  candidate: #(String, Int, Int, Int),
) -> Result(Prepared, Error) {
  use preparation <- result.try(snapshot_segment(db, candidate))
  case preparation {
    Finished(prepared) -> Ok(prepared)
    Gather(snapshot) -> {
      // Remote reads never hold the admission lock or a database connection.
      let gathered = gather_archive(store, snapshot.chunks, dict.new(), [], 0)
      transaction(db, fn(tx) {
        use _ <- result.try(lock_session(tx, snapshot.id))
        use _ <- result.try(require_live(tx, snapshot.id))
        use existing <- result.try(planned_for(tx, snapshot.id))
        case existing {
          Some(plan) -> Ok(Planned(plan))
          None -> {
            use unchanged <- result.try(snapshot_unchanged(tx, snapshot))
            case unchanged {
              False -> Ok(Skipped)
              True -> {
                use loaded <- result.try(gathered)
                let encoded = case loaded {
                  None -> Error(Nil)
                  Some(batches) -> archive.encode(batches)
                }
                case encoded {
                  Error(_) ->
                    defer_segment(
                      tx,
                      snapshot.id,
                      snapshot.start,
                      snapshot.end,
                      snapshot.head,
                    )
                  Ok(payload) -> reserve_plan(tx, snapshot, payload)
                }
              }
            }
          }
        }
      })
    }
  }
}

fn planned_for(
  db: pog.Connection,
  id: String,
) -> Result(Option(ArchivePlan), Error) {
  use rows <- result.try(
    pog.query(
      "SELECT session_id,object_key,start_sequence,end_sequence,digest,payload FROM retrace_archive_objects WHERE session_id=$1 AND state='planned'",
    )
    |> pog.parameter(pog.text(id))
    |> pog.returning(plan_decoder())
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  Ok(list.first(rows.rows) |> result.map(Some) |> result.unwrap(None))
}

fn snapshot_segment(
  db: pog.Connection,
  candidate: #(String, Int, Int, Int),
) -> Result(Preparation, Error) {
  let #(id, candidate_start, _, _) = candidate
  transaction(db, fn(tx) {
    use _ <- result.try(lock_session(tx, id))
    use _ <- result.try(require_live(tx, id))
    use existing <- result.try(planned_for(tx, id))
    case existing {
      Some(plan) -> Ok(Finished(Planned(plan)))
      None -> {
        let candidate_decoder = {
          use end <- decode.field(0, decode.int)
          use head <- decode.field(1, decode.int)
          decode.success(#(end, head))
        }
        // A competing worker may already have compacted the selected chunk.
        use pending <- result.try(
          pog.query(
            "SELECT c.end_sequence,s.sequence FROM retrace_chunks c JOIN retrace_sessions s ON s.id=c.session_id WHERE c.session_id=$1 AND c.start_sequence=$2 AND (c.payload IS NOT NULL OR c.archive_format=1)",
          )
          |> pog.parameter(pog.text(id))
          |> pog.parameter(pog.int(candidate_start))
          |> pog.returning(candidate_decoder)
          |> pog.execute(tx)
          |> result.map_error(Database),
        )
        case pending.rows {
          [] -> Ok(Finished(Skipped))
          [#(candidate_end, head), ..] -> {
            use preceding <- result.try(
              pog.query(
                "SELECT start_sequence FROM retrace_archive_objects WHERE session_id=$1 AND state='current' AND end_sequence=$2 AND $3-start_sequence<=1000 ORDER BY start_sequence DESC LIMIT 1",
              )
              |> pog.parameter(pog.text(id))
              |> pog.parameter(pog.int(candidate_start))
              |> pog.parameter(pog.int(candidate_end))
              |> pog.returning(decode.field(0, decode.int, decode.success))
              |> pog.execute(tx)
              |> result.map_error(Database),
            )
            let start =
              list.first(preceding.rows) |> result.unwrap(candidate_start)
            let bounds_decoder = {
              use end <- decode.field(0, decode.int)
              use bytes <- decode.field(1, decode.int)
              decode.success(#(end, bytes))
            }
            use bounds <- result.try(
              pog.query(
                "SELECT coalesce(max(end_sequence),$2),coalesce(sum(octet_length(payload)),0)::bigint FROM retrace_chunks WHERE session_id=$1 AND start_sequence>=$2 AND end_sequence<=$2+1000",
              )
              |> pog.parameter(pog.text(id))
              |> pog.parameter(pog.int(start))
              |> pog.returning(bounds_decoder)
              |> pog.execute(tx)
              |> result.map_error(Database),
            )
            use bound <- result.try(
              list.first(bounds.rows) |> result.replace_error(NotFound),
            )
            case bound.0 <= start, bound.1 > archive.max_bytes - 4096 {
              True, _ -> Ok(Finished(Skipped))
              False, True ->
                defer_segment(tx, id, start, bound.0, head)
                |> result.map(Finished)
              False, False -> {
                use chunks <- result.try(
                  pog.query(
                    "SELECT c.session_id,c.start_sequence,c.payload,c.digest,c.object_key,c.end_sequence,c.archive_format,a.digest FROM retrace_chunks c LEFT JOIN retrace_archive_objects a ON a.object_key=c.object_key WHERE c.session_id=$1 AND c.start_sequence>=$2 AND c.end_sequence<=$3 ORDER BY c.start_sequence LIMIT 1000",
                  )
                  |> pog.parameter(pog.text(id))
                  |> pog.parameter(pog.int(start))
                  |> pog.parameter(pog.int(bound.0))
                  |> pog.returning(chunk_decoder())
                  |> pog.execute(tx)
                  |> result.map_error(Database),
                )
                Ok(Gather(Snapshot(id, start, bound.0, head, chunks.rows)))
              }
            }
          }
        }
      }
    }
  })
}

fn snapshot_unchanged(
  db: pog.Connection,
  snapshot: Snapshot,
) -> Result(Bool, Error) {
  let decoder = {
    use start <- decode.field(0, decode.int)
    use end <- decode.field(1, decode.int)
    use key <- decode.field(2, decode.string)
    use format <- decode.field(3, decode.int)
    use hash <- decode.field(4, decode.string)
    use inline <- decode.field(5, decode.bool)
    decode.success(#(start, end, key, format, hash, inline))
  }
  use current <- result.try(
    pog.query(
      "SELECT start_sequence,end_sequence,object_key,archive_format,digest,payload IS NOT NULL FROM retrace_chunks WHERE session_id=$1 AND start_sequence>=$2 AND end_sequence<=$3 ORDER BY start_sequence LIMIT 1000",
    )
    |> pog.parameter(pog.text(snapshot.id))
    |> pog.parameter(pog.int(snapshot.start))
    |> pog.parameter(pog.int(snapshot.end))
    |> pog.returning(decoder)
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  use overlap <- result.try(
    pog.query(
      "SELECT object_key FROM retrace_archive_objects WHERE session_id=$1 AND state='current' AND start_sequence<$3 AND end_sequence>$2 AND (start_sequence<$2 OR end_sequence>$3) LIMIT 1",
    )
    |> pog.parameter(pog.text(snapshot.id))
    |> pog.parameter(pog.int(snapshot.start))
    |> pog.parameter(pog.int(snapshot.end))
    |> pog.returning(decode.field(0, decode.string, decode.success))
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  let original =
    list.map(snapshot.chunks, fn(c) {
      #(c.start, c.end, c.object_key, c.format, c.digest, c.payload != None)
    })
  Ok(current.rows == original && overlap.rows == [])
}

fn defer_segment(
  db: pog.Connection,
  id: String,
  start: Int,
  end: Int,
  head: Int,
) -> Result(Prepared, Error) {
  use _ <- result.try(
    pog.query(
      "INSERT INTO retrace_archive_deferrals(session_id,start_sequence,end_sequence,observed_sequence) VALUES($1,$2,$3,$4) ON CONFLICT(session_id,start_sequence) DO UPDATE SET end_sequence=EXCLUDED.end_sequence,observed_sequence=EXCLUDED.observed_sequence",
    )
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.int(start))
    |> pog.parameter(pog.int(end))
    |> pog.parameter(pog.int(head))
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  Ok(Deferred)
}

fn reserve_plan(
  db: pog.Connection,
  snapshot: Snapshot,
  payload: String,
) -> Result(Prepared, Error) {
  let hash = digest(payload)
  let key =
    "sessions/"
    <> snapshot.id
    <> "/segments/"
    <> int.to_string(snapshot.start)
    <> "-"
    <> int.to_string(snapshot.end)
    <> "-"
    <> hash
    <> ".ndjson.gz"
  let plan =
    ArchivePlan(snapshot.id, key, snapshot.start, snapshot.end, hash, payload)
  use inserted <- result.try(
    pog.query(
      "INSERT INTO retrace_archive_objects(session_id,object_key,start_sequence,end_sequence,digest,state,payload) VALUES($1,$2,$3,$4,$5,'planned',$6) ON CONFLICT(object_key) DO NOTHING RETURNING object_key",
    )
    |> pog.parameter(pog.text(snapshot.id))
    |> pog.parameter(pog.text(key))
    |> pog.parameter(pog.int(snapshot.start))
    |> pog.parameter(pog.int(snapshot.end))
    |> pog.parameter(pog.text(hash))
    |> pog.parameter(pog.text(payload))
    |> pog.returning(decode.field(0, decode.string, decode.success))
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  case inserted.rows {
    [] -> Ok(Skipped)
    _ -> Ok(Planned(plan))
  }
}

fn gather_archive(
  store: ObjectStore,
  chunks: List(Chunk),
  cached: dict.Dict(String, List(Batch)),
  accumulated: List(Batch),
  bytes: Int,
) -> Result(Option(List(Batch)), Error) {
  case chunks {
    [] -> Ok(Some(list.reverse(accumulated)))
    [chunk, ..rest] -> {
      case chunk.payload == None && chunk.format == 1 {
        True -> {
          // Legacy objects inflate to at most 1 MiB each. Bound each window,
          // then discard its cache before fetching more remote objects.
          let window =
            chunks
            |> list.take(16)
            |> list.take_while(fn(c) { c.payload == None && c.format == 1 })
          use batches <- result.try(
            read_concurrent_values(window, 16, fn(c) {
              use loaded <- result.try(read_object(store, c))
              batch_for_chunk(c, dict.from_list([#(c.object_key, loaded)]))
            }),
          )
          let next_bytes =
            bytes
            + list.fold(batches, 0, fn(total, batch) {
              total + string.byte_size(wire.encode(batch)) + 1
            })
          case next_bytes > archive.max_bytes - 4096 {
            True -> Ok(None)
            False ->
              gather_archive(
                store,
                list.drop(chunks, list.length(window)),
                cached,
                list.append(list.reverse(batches), accumulated),
                next_bytes,
              )
          }
        }
        False -> {
          // A format-2 object may itself be 32 MiB: read one at a time.
          use available <- result.try(
            case chunk.payload, dict.get(cached, chunk.object_key) {
              Some(_), _ -> Ok(cached)
              None, Ok(_) -> Ok(cached)
              None, Error(_) -> {
                use batches <- result.try(read_object(store, chunk))
                Ok(dict.insert(cached, chunk.object_key, batches))
              }
            },
          )
          use batch <- result.try(batch_for_chunk(chunk, available))
          let next_bytes = bytes + string.byte_size(wire.encode(batch)) + 1
          case next_bytes > archive.max_bytes - 4096 {
            True -> Ok(None)
            False ->
              gather_archive(
                store,
                rest,
                available,
                [batch, ..accumulated],
                next_bytes,
              )
          }
        }
      }
    }
  }
}

fn plan_is_planned(
  tx: pog.Connection,
  plan: ArchivePlan,
) -> Result(Bool, Error) {
  use active <- result.try(
    pog.query(
      "SELECT object_key FROM retrace_archive_objects WHERE object_key=$1 AND state='planned'",
    )
    |> pog.parameter(pog.text(plan.key))
    |> pog.returning(decode.field(0, decode.string, decode.success))
    |> pog.execute(tx)
    |> result.map_error(Database),
  )
  Ok(active.rows != [])
}

// Admission commits before the put, and the put and readback run outside the
// lock, so a fence never waits on a remote call and never mistakes an uncertain
// put for a settled one. Pointers change only after a locked recheck.
fn publish_plan(
  db: pog.Connection,
  store: ObjectStore,
  plan: ArchivePlan,
) -> Result(Bool, Error) {
  use admitted <- result.try(
    transaction(db, fn(tx) {
      use _ <- result.try(lock_session(tx, plan.id))
      use _ <- result.try(require_live(tx, plan.id))
      use active <- result.try(plan_is_planned(tx, plan))
      case active {
        False -> Ok(None)
        True -> admit_write(tx, plan.id, plan.key) |> result.map(Some)
      }
    }),
  )
  case admitted {
    None -> Ok(False)
    Some(attempt) -> {
      use _ <- result.try(dispatch(
        db,
        store,
        attempt,
        plan.key,
        compress(plan.payload),
      ))
      use stored <- result.try(store.get(plan.key) |> result.map_error(Storage))
      use verified <- result.try(
        decompress_bounded(stored, archive.max_bytes)
        |> result.replace_error(CorruptArchive),
      )
      use _ <- result.try(
        case digest(verified) == plan.digest && verified == plan.payload {
          True -> Ok(Nil)
          False -> Error(CorruptArchive)
        },
      )
      transaction(db, fn(tx) {
        use _ <- result.try(lock_session(tx, plan.id))
        use _ <- result.try(require_live(tx, plan.id))
        use active <- result.try(plan_is_planned(tx, plan))
        case active {
          False -> Ok(False)
          True -> {
            // Retain every superseded legacy or segment key before changing pointers.
            use _ <- result.try(
              pog.query(
                "INSERT INTO retrace_archive_objects(object_key,session_id,start_sequence,end_sequence,digest,state) SELECT object_key,session_id,min(start_sequence),max(end_sequence),min(digest),'retired' FROM retrace_chunks WHERE session_id=$1 AND start_sequence>=$2 AND end_sequence<=$3 AND object_key<>$4 GROUP BY object_key,session_id ON CONFLICT(object_key) DO NOTHING",
              )
              |> pog.parameter(pog.text(plan.id))
              |> pog.parameter(pog.int(plan.start))
              |> pog.parameter(pog.int(plan.end))
              |> pog.parameter(pog.text(plan.key))
              |> pog.execute(tx)
              |> result.map_error(Database),
            )
            use _ <- result.try(
              pog.query(
                "UPDATE retrace_archive_objects SET state='retired',last_deleted_at=NULL WHERE session_id=$1 AND state='current' AND object_key IN (SELECT object_key FROM retrace_chunks WHERE session_id=$1 AND start_sequence>=$2 AND end_sequence<=$3)",
              )
              |> pog.parameter(pog.text(plan.id))
              |> pog.parameter(pog.int(plan.start))
              |> pog.parameter(pog.int(plan.end))
              |> pog.execute(tx)
              |> result.map_error(Database),
            )
            use _ <- result.try(
              pog.query(
                "UPDATE retrace_chunks SET payload=NULL,archive_format=2,object_key=$4 WHERE session_id=$1 AND start_sequence>=$2 AND end_sequence<=$3",
              )
              |> pog.parameter(pog.text(plan.id))
              |> pog.parameter(pog.int(plan.start))
              |> pog.parameter(pog.int(plan.end))
              |> pog.parameter(pog.text(plan.key))
              |> pog.execute(tx)
              |> result.map_error(Database),
            )
            use _ <- result.try(
              pog.query(
                "UPDATE retrace_archive_objects SET state='current',payload=NULL WHERE object_key=$1 AND state='planned'",
              )
              |> pog.parameter(pog.text(plan.key))
              |> pog.execute(tx)
              |> result.map_error(Database),
            )
            Ok(True)
          }
        }
      })
    }
  }
}

/// Reconcile at most eight retired keys. First cleanup is immediate; the interval
/// only controls repeat DELETE after successful cleanup, covering ambiguous late
/// PUT outcomes. The registry remains available to future fencing and erasure.
pub fn reclaim_next(
  db: pog.Connection,
  remove: fn(String) -> Result(Nil, StorageError),
  interval_seconds: Int,
) -> Result(Bool, Error) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use key <- decode.field(1, decode.string)
    decode.success(#(id, key))
  }
  use candidates <- result.try(
    pog.query(
      "SELECT session_id,object_key FROM retrace_archive_objects WHERE state='retired' AND (last_deleted_at IS NULL OR last_deleted_at<now()-($1 * interval '1 second')) ORDER BY last_deleted_at NULLS FIRST,created_at LIMIT 8",
    )
    |> pog.parameter(pog.int(int.max(interval_seconds, 1)))
    |> pog.returning(decoder)
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  use _ <- result.try(
    list.try_each(candidates.rows, fn(candidate) {
      transaction(db, fn(tx) {
        use _ <- result.try(lock_session(tx, candidate.0))
        use safe <- result.try(
          pog.query(
            "SELECT object_key FROM retrace_archive_objects a WHERE a.object_key=$1 AND a.state='retired' AND NOT EXISTS(SELECT 1 FROM retrace_chunks c WHERE c.object_key=a.object_key) AND NOT EXISTS(SELECT 1 FROM retrace_archive_objects p WHERE p.object_key=a.object_key AND p.state IN ('planned','current'))",
          )
          |> pog.parameter(pog.text(candidate.1))
          |> pog.returning(decode.field(0, decode.string, decode.success))
          |> pog.execute(tx)
          |> result.map_error(Database),
        )
        case safe.rows {
          [] -> Ok(Nil)
          _ -> {
            use _ <- result.try(
              remove(candidate.1) |> result.map_error(Storage),
            )
            pog.query(
              "UPDATE retrace_archive_objects SET last_deleted_at=now() WHERE object_key=$1 AND state='retired'",
            )
            |> pog.parameter(pog.text(candidate.1))
            |> pog.execute(tx)
            |> result.map_error(Database)
            |> result.replace(Nil)
          }
        }
      })
    }),
  )
  Ok(candidates.rows != [])
}
