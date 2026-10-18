# Retrace server

BEAM admission, session indexing and object archival for Retrace recordings. The package
is experimental and not on Hex. Importing it starts no HTTP listener, database pool or
background process.

## Install

Declare the package from the Git subdirectory, with `retrace` at the same revision:

```toml
[dependencies]
retrace = { git = "https://github.com/gleam-dream/retrace.git", ref = "v0.1.0" }
retrace_server = { git = "https://github.com/gleam-dream/retrace.git", ref = "v0.1.0", path = "packages/retrace_server" }
```

## Quick usage

The host supplies a `pog.Connection` and an `ObjectStore(put, get)`, then calls the
operations explicitly:

| Operation              | Responsibility                                                                             |
| ---------------------- | ------------------------------------------------------------------------------------------ |
| `migrate`              | Create the initial schema; the host chooses when to run it                                 |
| `accept`               | Validate and commit a batch atomically before returning its acknowledgement cursor         |
| `sessions`             | List the latest 100 sessions, optionally filtered by user reference                        |
| `read`                 | Read bounded pages serially in the calling process, validating their contents              |
| `read_concurrent`      | Read the same ordered pages with an explicitly bounded number of independent adapter calls |
| `archive_next`         | Legacy compatibility: archive one original batch per object                                |
| `archive_segment_next` | Compact one idle session segment into a verified immutable generation                      |
| `reclaim_next`         | Delete at most eight unreferenced retired generations                                      |
| `fence`, `erase`       | Refuse a session and delete its objects and recording rows on caller authority             |

`retrace_server/s3` adapts S3-compatible storage with `bucket.Credentials`, and
`retrace_server/directory` provides local filesystem storage. Supply your own
`ObjectStore` for another provider. The [collector host](../../support/collector/src/retrace_collector.gleam)
shows HTTP wiring and worker ownership, and the
[failure and recovery consumer](../../support/server_checks/src/retrace_server_checks.gleam)
shows executable storage behavior. The contracts are in the
[archive design](../../docs/design/archive/design.typ).
