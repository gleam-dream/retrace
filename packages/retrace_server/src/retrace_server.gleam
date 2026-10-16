//// Durable admission, session indexing and archival. The caller owns the pool,
//// object store, migrations and worker lifetime; no process starts on import.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import pog
import retrace/wire.{type Batch, type Session}

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
  Conflict
  OutOfOrder(expected: Int, received: Int)
  NotFound
  Storage(StorageError)
  CorruptArchive
  Deleted
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
  )
}

pub fn migrate(db: pog.Connection) -> Result(Nil, Error) {
  [
    "CREATE TABLE IF NOT EXISTS retrace_tombstones (session_id text PRIMARY KEY, fenced_at timestamptz NOT NULL DEFAULT now(), reconciled_at timestamptz)",
    "CREATE TABLE IF NOT EXISTS retrace_deletion_objects (session_id text NOT NULL REFERENCES retrace_tombstones(session_id), object_key text NOT NULL, deleted_at timestamptz, PRIMARY KEY(session_id,object_key))",
    "CREATE TABLE IF NOT EXISTS retrace_sessions (
      id text PRIMARY KEY, user_ref text NOT NULL, metadata text NOT NULL,
      sequence bigint NOT NULL DEFAULT 0, elapsed_ms bigint NOT NULL DEFAULT 0,
      created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now())",
    "CREATE INDEX IF NOT EXISTS retrace_user_sessions ON retrace_sessions(user_ref, updated_at DESC)",
    "CREATE TABLE IF NOT EXISTS retrace_chunks (
      session_id text NOT NULL REFERENCES retrace_sessions(id), start_sequence bigint NOT NULL,
      end_sequence bigint NOT NULL, payload text, digest text NOT NULL, object_key text NOT NULL,
      PRIMARY KEY(session_id, start_sequence))",
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
  decode.success(Chunk(id, start, payload, digest, key))
}

/// Archive at most one pending batch. Concurrent workers may upload the same
/// immutable bytes to the same key; the conditional database update is safe.
pub fn archive_next(
  db: pog.Connection,
  store: ObjectStore,
) -> Result(Bool, Error) {
  use chunks <- result.try(
    pog.query(
      "SELECT c.session_id,c.start_sequence,c.payload,c.digest,c.object_key FROM retrace_chunks c WHERE c.payload IS NOT NULL AND NOT EXISTS (SELECT 1 FROM retrace_tombstones t WHERE t.session_id=c.session_id) ORDER BY c.session_id,c.start_sequence LIMIT 1",
    )
    |> pog.returning(chunk_decoder())
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  case chunks.rows {
    [] -> Ok(False)
    [candidate, ..] ->
      transaction(db, fn(tx) {
        use _ <- result.try(lock_session(tx, candidate.session_id))
        case require_live(tx, candidate.session_id) {
          Error(Deleted) -> Ok(False)
          Error(error) -> Error(error)
          Ok(_) -> {
            use current <- result.try(
              pog.query(
                "SELECT session_id,start_sequence,payload,digest,object_key FROM retrace_chunks WHERE session_id=$1 AND start_sequence=$2",
              )
              |> pog.parameter(pog.text(candidate.session_id))
              |> pog.parameter(pog.int(candidate.start))
              |> pog.returning(chunk_decoder())
              |> pog.execute(tx)
              |> result.map_error(Database),
            )
            case current.rows {
              [Chunk(payload: Some(payload), ..), ..] -> {
                use _ <- result.try(
                  store.put(candidate.object_key, compress(payload))
                  |> result.map_error(Storage),
                )
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
              }
              _ -> Ok(False)
            }
          }
        }
      })
  }
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
    "INSERT INTO retrace_deletion_objects(session_id,object_key) SELECT session_id,object_key FROM retrace_chunks WHERE session_id=$1 ON CONFLICT DO NOTHING",
  )
  |> pog.parameter(pog.text(id))
  |> pog.execute(tx)
  |> result.map(fn(_) { Nil })
  |> result.map_error(Database)
}

/// Idempotently delete a fenced session's objects before clearing its recording
/// rows. Each pass handles at most 8 keys and returns True only once all keys
/// and recording rows are cleared. Keep the fence and keys for restoration/late-PUT reconciliation. Repeated
/// calls deliberately repeat DELETE: a worker killed during PUT can leave an
/// ambiguous remote operation even after its database transaction is rolled back.
pub fn erase(
  db: pog.Connection,
  remove: fn(String) -> Result(Nil, StorageError),
  id: String,
) -> Result(Bool, Error) {
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
        "UPDATE retrace_tombstones SET reconciled_at=NULL WHERE session_id=$1",
      )
      |> pog.parameter(pog.text(id))
      |> pog.execute(tx)
      |> result.map_error(Database),
    )
    use keys <- result.try(
      pog.query(
        "SELECT object_key FROM retrace_deletion_objects WHERE session_id=$1 AND deleted_at IS NULL ORDER BY object_key LIMIT 8",
      )
      |> pog.parameter(pog.text(id))
      |> pog.returning(decode.field(0, decode.string, decode.success))
      |> pog.execute(tx)
      |> result.map_error(Database),
    )
    use _ <- result.try(
      list.try_each(keys.rows, fn(key) {
        use _ <- result.try(remove(key) |> result.map_error(Storage))
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
    use remaining <- result.try(
      pog.query(
        "SELECT object_key FROM retrace_deletion_objects WHERE session_id=$1 AND deleted_at IS NULL LIMIT 1",
      )
      |> pog.parameter(pog.text(id))
      |> pog.returning(decode.field(0, decode.string, decode.success))
      |> pog.execute(tx)
      |> result.map_error(Database),
    )
    case remaining.rows {
      [_] -> Ok(False)
      _ -> {
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
        |> result.map(fn(_) { True })
        |> result.map_error(Database)
      }
    }
  })
}

/// Reconcile one oldest tombstone. Completed deletions are revisited after the
/// caller-specified interval; this closes ambiguous late remote PUT outcomes.
pub fn erase_next(
  db: pog.Connection,
  remove: fn(String) -> Result(Nil, StorageError),
  interval_seconds: Int,
) -> Result(Bool, Error) {
  use rows <- result.try(
    pog.query(
      "SELECT session_id FROM retrace_tombstones WHERE reconciled_at IS NULL OR reconciled_at < now() - ($1 * interval '1 second') ORDER BY reconciled_at NULLS FIRST, fenced_at LIMIT 1",
    )
    |> pog.parameter(pog.int(int.max(interval_seconds, 1)))
    |> pog.returning(decode.field(0, decode.string, decode.success))
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  case rows.rows {
    [] -> Ok(False)
    [id, ..] -> erase(db, remove, id) |> result.map(fn(_) { True })
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
  use _ <- result.try(require_live(db, id))
  use chunks <- result.try(
    pog.query(
      "SELECT session_id,start_sequence,payload,digest,object_key FROM retrace_chunks WHERE session_id=$1 AND end_sequence>$2 ORDER BY start_sequence LIMIT 128",
    )
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.int(after))
    |> pog.returning(chunk_decoder())
    |> pog.execute(db)
    |> result.map_error(Database),
  )
  list.try_map(chunks.rows, fn(chunk) {
    use payload <- result.try(case chunk.payload {
      Some(payload) -> Ok(payload)
      None -> {
        use body <- result.try(
          store.get(chunk.object_key) |> result.map_error(Storage),
        )
        decompress(body) |> result.map_error(fn(_) { CorruptArchive })
      }
    })
    case digest(payload) == chunk.digest {
      False -> Error(CorruptArchive)
      True -> wire.decode_batch(payload) |> result.map_error(InvalidBatch)
    }
  })
}

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
