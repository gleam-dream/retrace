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
