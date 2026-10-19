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
| `fence`, `erase`                   | Refuse a session, then delete its objects and recording rows on caller authority; the result is `Erasing`, `AwaitingWriters` or `Erased` |
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
attempt, committed under the session lock before the PUT is dispatched. Its state is only a fact:

- `InFlight`: admitted, with no outcome recorded. The PUT may not have been sent yet, may be on the wire,
  or may have been lost with its caller;
- `Failed`: `put` returned an error. Retrace records when;
- `Completed`: `put` returned success, so the provider finished the write;
- `Quiesced`: the host proved that it cannot publish later.

The host decides which attempts can no longer publish. `erase` takes an `Eraser(remove, quiesced)`, and on every
pass calls `quiesced` for each attempt that might still publish. It answers `MayPublish`, or
`Quiescent(basis)` with the reason, which Retrace records. The function runs inside the session lock, so it
answers from local state and makes no remote calls. It receives:

- `state` and `object_key`;
- `since_admission_seconds`, rounded down. A worker can pause after admission and send its PUT arbitrarily
  later, so this bounds no remote write;
- `since_failure_seconds`, rounded down, once `put` returned an error. The request was sent before that
  return, so a maximum request lifetime that your provider has qualified, elapsed since the failure,
  covers a `Failed` attempt.

A conservative policy therefore trusts only `Failed` attempts, and only after your qualified bound has elapsed
since the failure. Resolving an `InFlight` attempt needs two facts: no local dispatch can still happen (the worker is stopped,
or fenced out of sending), and no request it already issued can publish (a provider-qualified bound, or the
provider's own evidence). Terminating the worker or revoking its credentials establishes at most the first. No
clock alone supplies either. Retrace ships no S3 policy: its five-second
timeout abandons the wait, not the request. `directory.quiesced` proves a `Failed` local put, whose write
finishes inside the calling process, and leaves an `InFlight` one unproven.

`erase` and `erase_next` return the typed `Erasure`, and `reconciled_at` is set only on `Erased`;
`erasure_status` reads it later. A host that proves nothing leaves the session `AwaitingWriters`, which is
honest and safe.

## Schema and database privileges

`migrate` creates the schema. It has no upgrade path from earlier drafts, and it refuses a database that holds
tombstones from before write attempts with `UnsupportedSchema`, changing nothing. Start from an empty database,
and run every worker on this version before enabling retention, because an older worker records no attempts.

A restricted runtime role needs, on `retrace_tombstones`, `retrace_deletion_objects`, `retrace_sessions`,
`retrace_chunks`, `retrace_archive_objects`, `retrace_archive_deferrals` and `retrace_write_attempts`:
`SELECT`, `INSERT`, `UPDATE` and `DELETE`. It also needs `USAGE` on the sequence
`retrace_write_attempts_attempt_id_seq`, or admitting an attempt fails with `permission denied for sequence`.
The [quiescence checks](../../support/server_checks/src/quiescence_checks.gleam) exercise archival and erasure
under exactly these privileges and are the executable specification;
[ADR 0019](../../docs/adr/0019-complete-erasure-only-after-uploads-quiesce.md) records the decision.
