# Complete erasure only after every admitted upload is quiescent

<a id="adr-0019"></a>

Recorded on 2026-10-18. The behavior is exercised by `support/server_checks` (`quiescence_checks`) through `dev/server-check.sh`. It supersedes the locking and late-PUT statements of [ADR 0009](0009-session-archive-generations.md) and [ADR 0015](0015-erase-sessions-through-caller-driven-fences.md) where they differ.

## Decision

Each upload is a durable write attempt. Archival commits an attempt under the session lock, after checking the fence and before the PUT, then dispatches the PUT and verifies the readback outside the lock, and changes pointers only after a locked recheck of the fence and the plan.

Retrace records only facts about an attempt:

- in flight: admitted, and no outcome recorded. The PUT may not have been sent yet, may be on the wire, or may have been lost with its caller;
- failed: `put` returned an error, and the time of that return is recorded;
- completed: `put` returned success, so the provider finished the write;
- quiesced: the host proved that it cannot publish later.

In flight and failed attempts might still publish. Retrace never infers quiescence from an error, a timeout, an expired lease, a dead process, an absent object, a successful DELETE or a cancellation flag.

The host decides quiescence. Erasure takes an `Eraser`, a record of `remove` and `quiesced`. On every pass Retrace calls `quiesced` once for each attempt that might still publish, passing its state, object key, whole seconds since admission and, once `put` returned an error, whole seconds since that failure, both rounded down. `Quiescent(basis)` records the attempt as quiesced with that basis. `MayPublish` changes nothing, so the next pass asks again. The host answers from local state because the call runs inside the session lock.

Erasure deletes the keys that no attempt which might publish owns and reports `Erasing`, `AwaitingWriters(n)` or `Erased`. Only `Erased` clears the recording rows and sets the tombstone's `reconciled_at`, so that column means definitive completion. `erase` and `erase_next` return the typed `Erasure`, so a host never reads a boolean as completion. A fence refuses new attempt admission, so a retained worker cannot admit or retry an upload. An attempt admitted before the fence may still dispatch, and it blocks completion until the host proves it quiescent.

## Rationale

Holding the lock across the PUT never proved quiescence. A failed PUT rolled its transaction back while the provider could still finish the request, and the fence then reported completion. Recording the attempt before dispatch is the only evidence that survives a timeout, an exception or a dead process.

A pull function puts the decision with the party that holds the facts, such as credential lifetimes, a provider guarantee or an operator's confirmation, and makes it a typed, testable function. It needs no free-text evidence, no adapter flag and no watcher job: each pass re-evaluates, so a host policy resolves attempts as time passes. Time since admission bounds no remote write, because a worker can pause after admission and send its PUT arbitrarily later. Only time since a returned failure, measured against a maximum request lifetime the host has qualified with its provider, covers a failed attempt, and resolving an in-flight attempt needs two facts: that no local dispatch can still happen, and that no already-issued request can publish. Terminating the worker or revoking its credentials establishes at most the first; the second needs a provider-qualified bound or the provider's own evidence.

Moving the PUT out of the lock stops a fence from waiting on a remote call and stops a database connection from being held across remote I/O. Duplicate concurrent PUTs of one immutable key and bytes are safe, and each is its own attempt.

## Consequences

Erasure may remain incomplete indefinitely when the host cannot prove quiescence. That is the intended state. `directory.quiesced` proves a failed local put, since its write finishes inside the calling process, and leaves an in-flight put unproven. The S3 adapter supplies no function: its five-second timeout abandons the wait, not the request, so a host must supply a qualified policy of its own.

Every worker runs this version before retention is enabled, because an older worker records no attempts. The schema has no upgrade path from earlier drafts; a deployment starts from an empty database. `migrate` refuses a database holding tombstones from before write attempts with `UnsupportedSchema` and changes nothing. A restricted runtime role needs select, insert, update and delete on every Retrace table and usage on the attempt sequence. `ObjectStore`, `StorageError` and `Error` keep their constructors. `erase` and `erase_next` change signature and result: they take an `Eraser` and return `Erasure`, so a host written against the boolean contract fails to compile and cannot keep trusting the old signal. `erasure_status` and `write_attempts` are new. A host that polls `reconciled_at` directly still fails closed, because it is set only on `Erased`.

A fence still takes the session lock, but it no longer waits for a PUT in flight. An in-flight PUT that finishes after the fence records its outcome, changes no pointers and returns `Deleted`.

Provider versioning, snapshots, backups and physical deletion deadlines stay with the host.
