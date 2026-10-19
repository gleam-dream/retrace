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

| Operation                          | Responsibility                                                                                                                           |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `migrate`                          | Create the initial schema; the host chooses when to run it                                                                               |
| `accept`                           | Validate and commit a batch atomically before returning its acknowledgement cursor                                                       |
| `sessions`                         | List the latest 100 sessions, optionally filtered by user reference                                                                      |
| `read`                             | Read bounded pages serially in the calling process, validating their contents                                                            |
| `read_concurrent`                  | Read the same ordered pages with an explicitly bounded number of independent adapter calls                                               |
| `archive_next`                     | Legacy compatibility: archive one original batch per object                                                                              |
| `archive_segment_next`             | Compact one idle session segment into a verified immutable generation                                                                    |
| `reclaim_next`                     | Delete at most eight unreferenced retired generations                                                                                    |
| `fence`, `erase_session`           | Refuse a session, then delete its objects and recording rows on caller authority; the result is `Erasing`, `AwaitingWriters` or `Erased` |
| `erasure_status`, `write_attempts` | Read erasure progress, and list a session's upload attempts with their states                                                            |

`retrace_server/s3` adapts S3-compatible storage with `bucket.Credentials`, and
`retrace_server/directory` provides local filesystem storage. Supply your own
`ObjectStore` for another provider. The [collector host](../../support/collector/src/retrace_collector.gleam)
shows HTTP wiring and worker ownership, and the
[failure and recovery consumer](../../support/server_checks/src/retrace_server_checks.gleam)
shows executable storage behavior. The contracts are in the
[archive design](../../docs/design/archive/design.typ).

## Erasure and uploads with an unknown outcome

A failed or lost PUT does not prove that the provider stopped. Each upload is recorded as a write
attempt before it is dispatched, with a state that is only a fact: `InFlight` (no outcome seen),
`Failed` (`put` returned an error), `Completed` (`put` returned success) or `Quiesced`.

The host decides which attempts can no longer publish. `erase_session` takes an `Eraser(remove, quiesced)`,
and on every pass calls `quiesced` for each attempt that might still publish. It answers `MayPublish`,
or `Quiescent(basis)` with the reason, which Retrace records. The function receives the attempt's
state, object key and age, so a qualified host policy such as "no request outlives fifteen minutes" resolves
attempts as time passes with no separate job. It runs inside the session lock, so it answers from local state.

- `directory.quiesced` proves a `Failed` local put and leaves an `InFlight` one unproven.
- No S3 function is supplied. A timeout abandons the wait, not the request, so supply a policy you
  have qualified with your provider.

`erase` and `erase_next` return the typed `Erasure`, and `reconciled_at` is set only on `Erased`;
`erasure_status` reads it later. A host that proves nothing leaves the
session `AwaitingWriters`, which is honest and safe.

Run `migrate` on an empty database: this schema has no upgrade path from earlier drafts. Every worker must run this
version before retention is enabled, because an older worker records no attempts.
The [quiescence checks](../../support/server_checks/src/quiescence_checks.gleam) are the executable specification;
[ADR 0019](../../docs/adr/0019-complete-erasure-only-after-uploads-quiesce.md) records the decision.
