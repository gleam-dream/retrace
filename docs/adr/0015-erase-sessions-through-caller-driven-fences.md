# Erase sessions through caller-driven fences and retained tombstones

<a id="adr-0015"></a>

Recorded on 2026-10-17. The behavior is exercised by `support/server_checks` through `dev/server-check.sh`.

## Decision

Erasure has two steps under caller authority. A fence atomically refuses
admission, archival, search and reads for a session and inventories its object
keys, and an idempotent erasure deletes the objects before clearing recording
rows, at most eight keys per pass. Tombstones and object keys are retained.

## Rationale

A PUT with an uncertain remote outcome can finish after its worker died, so a
late object must be deletable again without making the session readable.
Retained keys let repeated deletion reconcile it. The fence and archival share
one transaction-scoped session lock, so archival settles before the fence.

## Consequences

The host owns authorization, deadlines, supervision and retry cadence. It
reapplies tombstones after restoring a backup and separately qualifies provider
versions, snapshots and physical deletion deadlines, because completed erasure
does not establish removal from them. Every worker is upgraded before retention
is enabled, since older workers ignore the fence.
