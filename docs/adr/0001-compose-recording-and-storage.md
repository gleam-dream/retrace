# Compose portable recording with explicit runtime owners

<a id="adr-0001"></a>

On 2026-10-10 the user accepted a new Retrace project owning client delivery,
collection, indexing, object storage and replay, with web and Tauri examples.
The earlier Time Travel fork proved only recording and inspector composition.

The recording core lives in Retrace so clients and servers need not depend on a
Lustre debugger. Time Travel remains an optional example-viewer dependency,
pinned with provenance and its original MIT license. No upstream PR is part of
this work.

PostgreSQL acknowledges durable batches before asynchronous S3 archival. This
makes object-store outages retryable and keeps the session index immediately
searchable. Object upload and a database commit cannot be one atomic transaction;
deterministic object keys and retaining the database copy until upload succeeds
close the loss window. Orphan cleanup and retention are later operational work.

The local examples establish the data path. Hosted authentication, tenancy,
erasure and production mobile lifecycle guarantees are not claimed by this
initial implementation.
