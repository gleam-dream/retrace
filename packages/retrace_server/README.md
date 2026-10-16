# Retrace server

BEAM admission, session indexing and object archival for Retrace recordings.
Install the Git subdirectory `packages/retrace_server` using the
[installation guide](../../docs/releases.md). The package is experimental and is
not published to Hex.

The host supplies a `pog.Connection` and an `ObjectStore(put, get)`. Importing the
package starts no HTTP listener, database pool or background process.

| Operation              | Responsibility                                                                             |
| ---------------------- | ------------------------------------------------------------------------------------------ |
| `migrate`              | Create the initial schema; the host chooses when to run it                                 |
| `accept`               | Validate and commit a batch atomically before returning its acknowledgement cursor         |
| `sessions`             | List the latest 100 sessions, optionally filtered by user reference                        |
| `read`                 | Read bounded pages serially in the calling process, validating their contents              |
| `read_concurrent`      | Read the same ordered pages with an explicitly bounded number of independent adapter calls |
| `archive_next`         | Legacy compatibility: archive one original batch per object                                |
| `archive_segment_next` | Compact one idle session segment into a verified immutable generation                      |
| `reclaim_next`         | Delete at most eight unreferenced retired generations, retaining reconciliation inventory  |

`retrace_server/s3` adapts S3-compatible storage using `bucket.Credentials`.
`retrace_server/directory` provides local filesystem storage. Supply your own
`ObjectStore` to use another provider; the host owns resource and worker lifetimes.

See the [collector host](../../support/collector/src/retrace_collector.gleam) for
HTTP wiring and worker ownership, and the
[failure/recovery consumer](../../support/server_checks/src/retrace_server_checks.gleam)
for executable storage behavior. The [basic and advanced examples](../../examples/README.md)
share this collector.

Authentication, tenant isolation, retention, erasure, rate limits and archive
repair belong to the deployment. `migrate` is an initial schema helper, not a
versioned migration system. The development collector is not a hardened public
service. See the root [limits](../../README.md#current-limits).

## Caller-owned retention

`fence(db, session_id)` atomically prevents new admission, archive work, search
and subsequent reads, including for an ID not yet admitted. It snapshots object
keys under the same transaction-scoped session lock used by admission and archive.
`erase(db, remove, session_id)` idempotently deletes those objects before clearing
recording rows. Each pass handles at most 8 keys and returns whether the session
finished erasing. `erase_next(db, remove, interval_seconds)` processes an unfinished
fence or reconciles the oldest completed deletion after the supplied interval.
Supply `s3.remove(credentials, bucket, _)` or `directory.remove(root, _)` separately;
existing `ObjectStore` values keep their put/get contract.

The host owns authorization, deadlines, worker supervision, retry cadence and
backup restoration. Tombstones and object keys are deliberately retained: a PUT
with an uncertain remote outcome can finish after a worker dies. Repeated DELETE
reconciles that object without making its session readable again. The host must
reapply tombstones after restoring backups, and separately qualify versioned
objects, provider snapshots and physical deletion deadlines. This API does not
promise immediate erasure from backups or an unbounded provider request.

Upgrade every ingestion/archive worker before enabling retention. Older workers
do not honor the fence. `Deleted` is a new error variant. Run `migrate` before new
workers start. For atomic host authorization/accounting, use
`accept_in_transaction` and `fence_in_transaction` **only inside a caller-owned
PostgreSQL transaction**. They do not begin or commit; nesting `pog.transaction`
with Pog 4.1 would otherwise commit the outer transaction unexpectedly.

## Concurrent archive reads

`read_concurrent(db, store, id, after, concurrency)` returns the same ordered page
of at most 128 batches as `read`. The concurrency budget is clamped to 1–16.
A page fails as a whole if an object is missing, corrupt, or unavailable. Both
read APIs recheck the deletion fence after retrieving their page. The last
returned entry's absolute sequence remains the next-page cursor.

Opt in only when `store.get` can run independently in different processes. The
adapter must bound its own external I/O; this API adds no request deadline.
Use `read` for adapters requiring calling-process state or serial execution.
Concurrent reads may complete out of order, but returned batches never do.

A concurrent call owns its temporary coordinator and read workers. Success or
failure waits for those workers to terminate; caller death also terminates them.
An adapter exception is returned as `Storage(Unavailable)`. No borrowed database
pool, object store, or transport is stopped. Cancellation terminates local read
workers, not an independently running provider operation or a resource created
by an adapter. Hosts still own authorization, global admission limits, and
external transport lifetimes; the cap applies to each read, not all callers.

`dev/server-check.sh` exercises 513-entry pagination through PostgreSQL and local
archived bytes, mixed inline/archive pages, delayed out-of-order reads, worker
bounds, missing/corrupt objects, caller death, adapter crashes, and deletion while
a read is blocked. It does not establish production-provider latency.

## Session archive generations

`archive_segment_next(db, store, idle_seconds)` selects one idle session segment,
resuming persisted plans first. Use an inactivity threshold such as 60 seconds.
It greedily packs whole original batches into at most 1000 events per segment;
a session with at most 1000 events occupies one current object when archivable.
A crossing batch starts the next segment. Original checkpoints, batch digests,
exact retries and the 128-batch read cursor remain unchanged. A late batch replaces
its preceding segment if it fits. Existing per-batch archives compact automatically.
Do not run legacy `archive_next` workers when adopting grouped storage if every
new session must avoid temporary per-batch objects.

Preparation reads a locked snapshot, fetches objects without the admission lock,
and verifies unchanged sources before reserving a plan. Legacy GETs run in windows
of at most 16; the adapter must support independent calls. The plan's complete
payload and immutable key commit before PUT. Publication holds the session lock
through PUT, GET verification, pointer replacement and removal of inline payloads.
Bound adapter I/O so publication cannot indefinitely block admission or fencing.
A restart resumes a plan; any failed PUT or verification preserves old sources.

The format-2 object is gzip-compressed newline-delimited JSON: a versioned session
and range header followed by the unchanged encoded batches. Inflation and decoded
content are bounded to 32 MiB. An oversized group keeps its current sources;
it is durably deferred until that session advances, never split early by byte size.
`True` reports publication **or** that durable deferral; `False` means no work or a
snapshot invalidated by a competing worker. One plan per session can temporarily
duplicate up to 32 MiB in the database. Include planned payload bytes as well as
inline batch bytes in host capacity and admission policy.

Call `reclaim_next(db, remove, interval_seconds)` regularly. Each call handles at
most eight retired keys; first deletion is immediate, and the interval controls
repeat deletion after success. Old generations may therefore coexist physically
until cleanup runs, while only one is authoritative per segment. Missing objects
on a read trigger one fresh pointer lookup only when a concurrent replacement
changed those sources; corruption never falls back. Each page GETs a shared object
once. Every planned, current and retired key participates in deletion fencing and
repeated erasure; provider versions and backups remain a host responsibility.

Run `migrate` before starting upgraded workers. It adds `archive_format` to
`retrace_chunks`, plus `retrace_archive_objects` and `retrace_archive_deferrals`.
The runtime needs SELECT/INSERT/UPDATE/DELETE on those tables; no sequence grants
are added. Retain receipt rows and registry inventory. `dev/server-check.sh`
covers 999/1000/1001 events, late replacement, restart after ambiguous upload,
readback failure, oversized fallback, concurrent preparation/publication/fencing,
legacy compaction and source-pointer refresh through PostgreSQL and directory storage.
