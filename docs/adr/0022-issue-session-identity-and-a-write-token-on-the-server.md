# Issue session identity and a write token on the server

<a id="adr-0022"></a>

Recorded on 2026-11-25.

## Decision

The server opens every session. It chooses the session id, issues a random write token
with it and stores only the token's digest. Every batch is uploaded with that token, and
admission refuses an upload whose token does not match its session's, or whose session
was never opened, without changing the session. The collector answers such an upload as
it answers a missing session. A client starts capture from session metadata and records
from the first transition after the session is open.

## Rationale

The client used to choose its session id, and admission checked only the cursor and the
metadata. Anyone who could read a session (its id, head sequence, elapsed time and
metadata are all returned by listing and reading) could append a forged batch, after
which the writer's own next batch conflicted. A client could also create sessions under
another person's user reference. A token that only the opener holds removes both: a
forged batch cannot be admitted, and the host decides the user reference when it
authenticates the request that opens the session. Because no other writer can reach a
session, a conflict or gap on a writer's own upload can only come from that writer.

## Alternatives

- An id that is an HMAC of server data. It needs a server secret with its own rotation,
  and an id that proves write access cannot also be shown to readers.
- Binding later batches to the first writer with a hash it chooses. The first batch
  remains forgeable, and the client still chooses ids and user references.
- A host check of `user_ref` before admission. It stops impersonation of a user
  reference but not appends to another reader's session.

## Consequences

Opening needs the collector, so a page that starts offline records nothing until it can
open a session; batches already saved still drain. A transport has two operations, open
and send. Sessions admitted before this change have no digest and accept no further
batches. Each open that is answered but whose reply is lost leaves an empty session,
which listings omit.
