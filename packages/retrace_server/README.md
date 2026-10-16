# Retrace server

BEAM admission, session indexing and object archival for Retrace recordings.
Install the Git subdirectory `packages/retrace_server` using the
[installation guide](../../docs/releases.md). The package is experimental and is
not published to Hex.

The host supplies a `pog.Connection` and an `ObjectStore(put, get)`. Importing the
package starts no HTTP listener, database pool or background process.

| Operation      | Responsibility                                                                     |
| -------------- | ---------------------------------------------------------------------------------- |
| `migrate`      | Create the initial schema; the host chooses when to run it                         |
| `accept`       | Validate and commit a batch atomically before returning its acknowledgement cursor |
| `sessions`     | List the latest 100 sessions, optionally filtered by user reference                |
| `read`         | Read bounded pages from PostgreSQL or archived objects, validating their contents  |
| `archive_next` | Upload one compressed immutable payload, then clear its database copy              |

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
