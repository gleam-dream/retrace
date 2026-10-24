# Read archived ranges concurrently under a per-read bound

<a id="adr-0016"></a>

Recorded on 2026-10-17. The timing is an executable check in `support/server_checks/src/concurrent_read_checks.gleam`, run by `dev/server-check.sh`.

## Decision

Concurrent archive reads are opt-in. A read clamps its worker budget to one
through sixteen, returns pages in recording order, verifies every payload, and
fails as a whole when any object is missing, corrupt or unavailable. Serial reads
keep running in the calling process.

## Rationale

Archived objects of one range can be fetched independently, but not every
adapter is safe for independent calls, so concurrency requires an explicit
opt-in. The bound applies to each read, because the package cannot limit all
callers, and the host owns global admission limits.

## Consequences

A read owns a temporary coordinator and workers, waits for them to terminate and
releases them when its caller dies. Cancellation stops local workers and never
a provider operation or an adapter-created resource. Adapters bound their own
external I/O, since the read adds no request deadline.
