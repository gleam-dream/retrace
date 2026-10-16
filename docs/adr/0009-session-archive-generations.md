# Archive sessions through immutable generations

<a id="adr-0009"></a>

## Decision

Keep immutable upload batches as admission receipts and replay page units. Add
opt-in session archival that packs whole batches into at most 1000 events per
segment, after host-configured inactivity. A session at or below 1000 events has
one current object when archivable. Larger sessions use greedy whole-batch
boundaries rather than invented checkpoints. Existing per-batch archival remains
readable and eligible for compaction.

Persist a generation's complete payload and object key before remote upload.
Verify the uploaded object by reading it back before replacing pointers and
clearing inline payloads. Generations only move planned → current → retired;
keep their keys for cleanup and deletion reconciliation. Late arrivals replace
an underfilled segment with a new immutable generation.

## Rationale and consequences

Per-event or per-upload objects make long sessions require many remote requests.
Grouping reduces those requests without changing admission, exact-retry digest
checks or application replay meaning. Mutable object keys would make failed or
concurrent replacements ambiguous. Durable plans inventory even uncertain PUTs
and retain an explicit recovery source after a worker dies.

A decoded envelope is limited to 32 MiB. Oversized groups retain their sources
and defer until further admission; bytes never force a split below 1000 events.
One pending plan can temporarily duplicate up to 32 MiB in PostgreSQL. Hosts
must include this in storage policy. Whole-batch boundaries can leave a segment
underfilled when the next batch would cross the event limit.

Preparation reads objects outside the session lock, in bounded legacy windows,
and rechecks sources before committing a plan. Publication holds the lock while
PUT and verification settle. Adapters must bound I/O and tolerate independent
GETs. Retired objects are deleted only after a locked reference check; missing
old sources permit one pointer refresh, while integrity failures never fall back.

The host owns scheduling, external resources, global capacity, authorization,
retention and provider version/backup policy. Repeated deletion reconciles
ambiguous late writes but does not prove that an unbounded provider request has
stopped. No new hidden worker or stronger remote-quiescence promise is introduced.

## Validation

The public PostgreSQL/directory consumer exercises event boundaries, original
batch equality, exact retry, late replacement, durable upload failure/restart,
readback integrity, concurrent archive workers, admission during remote reads,
fencing, stale source rejection, legacy compaction and oversized inline fallback.
Consumer tests with a caller-owned signed S3 adapter remain separate evidence.
