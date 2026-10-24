# Treat the collector routes as a supported contract

<a id="adr-0018"></a>

Recorded on 2026-10-18.

## Decision

A collector serves three operations: batch submission, session listing and batch paging.
The design states their behavior as boundary rules in the archive context, and the packaged
client and viewer depend on exactly these operations. A collector may add operations. A
change to the behavior of these three, or their removal, is a breaking change.

The development collector stays unauthenticated and loopback-only. Authentication, tenant
isolation, rate limiting and retention for a hosted collector stay with the separate
hosted-deployment ruling.

## Rationale

The client submits to a configurable endpoint, so collectors other than the development one
are intended. The package ships both ends of the protocol, the client that submits and the
viewer that lists and pages. A protocol that two shipped components share needs a stated
contract, or each side can change what the other relies on without a signal.

## Alternatives

Declare the routes development-only with no compatibility promise. This keeps the freedom to
change them, and it leaves any other collector without a specification and the client and
viewer free to drift apart from the development collector.

## Consequences

The archive context holds the rules. `dev/backend-check.py` exercises the collector against
real storage for acknowledgement, concurrent identical submissions, conflict and order
refusal, invalid-batch refusal, listing for one user reference and ordered paging after
archival. `support/server_checks` exercises the 128-batch page at the server level. Four
rules have no collector-level check yet: the oversized refusal, the listing bound and order,
the empty pages and the storage-failure reporting. They are stated from the collector and
server code. A collector that serves a different shape fails the packaged viewer at its first
request.

## Evidence

The submission, listing and paging calls are in `packages/retrace_frontend/src/client_ffi.mjs`
and `viewer_ffi.mjs`. The collector's handlers are in `support/collector/src/retrace_collector.gleam`
and the admission, listing and paging semantics are in `packages/retrace_server`. The size
and entry limits are in `src/retrace/wire.gleam`.
