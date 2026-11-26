# Migrating to 0.2.0

Version 0.2.0 of `retrace`, `retrace_frontend`, `retrace_server` and the development
collector is a breaking release. Upgrade all packages that you use together: a 0.2.0
frontend works only with a 0.2.0 collector or server, and the reverse. Nothing in the core
`retrace` API is removed, so a core-only application needs no change (see
[Core](#core-retrace)).

The guide is ordered by how many applications each change affects. It compares 0.2.0 with
`retrace` 0.1.0, `retrace_frontend` 0.1.1, `retrace_server` 0.1.0 and `retrace_collector` 0.1.1.

## What changed

| Change                                                                                                                                  | Affects                                         |
| --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| [Capture starts from metadata and uploads in batches](#1-capture-starts-from-metadata-and-uploads-in-batches)                           | Lustre applications that use `capture.start`    |
| [Delivery discards rejected sessions, backs off and hands over](#2-delivery-discards-rejected-sessions-backs-off-and-hands-over)        | Every application that uses the frontend client |
| [Transports have two operations and classify rejections](#3-transports-have-two-operations-and-classify-rejections)                     | Applications with a custom or foreign transport |
| [The server opens sessions and accepts uploads with a write token](#4-the-server-opens-sessions-and-accepts-uploads-with-a-write-token) | Hosts that call `retrace_server`                |
| [The collector routes](#5-the-collector-routes)                                                                                         | Anything that calls the collector over HTTP     |
| [Stored data and queued batches](#6-stored-data-and-queued-batches)                                                                     | Existing databases and browsers                 |
| [Core](#core-retrace)                                                                                                                   | Additions only                                  |

## Upgrade order

1. Update `retrace`, then `retrace_server` and the collector, in the host. Run `migrate`
   (see [section 6](#6-stored-data-and-queued-batches)).
2. Deploy the host. A 0.1 frontend bundle gets `400` for every upload, because its
   batches carry no write token.
3. Ship the 0.2.0 frontend bundle.

Run `gleam update` and keep `manifest.toml` under version control so that each
application resolves one set of versions.

## 1. Capture starts from metadata and uploads in batches

**What changed.** The collector now chooses the session id and a write token, so
`capture.session` is removed. `capture.start` and `capture.start_with_clock` take
`wire.Metadata` and a flush window in milliseconds, and return `Result(_, wire.Error)`
(they refuse invalid metadata). Capture uploads only batches: it holds the observations of
one window in memory and saves them as one batch with one checkpoint. `capture.with_batching`
and `capture.Batching` are removed; the entry and byte limits follow the wire format.

**Why.** A client that chose its own id let anyone who could read a session forge the next
batch for it ([section 4](#4-the-server-opens-sessions-and-accepts-uploads-with-a-write-token)).
One batch per message also encoded and uploaded the whole model for every message; for
1,000 observations of a 20 KB model, one per 100 ms, a one-second window sends 100 requests
instead of 1,000.

**Before (0.1.x)**

```gleam
let session =
  capture.session("Warehouse", domain.build, domain.contract, "web")
let assert Ok(#(recording, connect)) =
  capture.start(
    session,
    client.Config("http://127.0.0.1:4417", "basic-outbox", 100, 1_048_576),
    client.browser_storage(),
    client.http_transport("http://127.0.0.1:4417"),
  )
```

**After (0.2.0)**

```gleam
let metadata =
  wire.Metadata("Warehouse", domain.build, domain.contract, "web")
let assert Ok(#(recording, connect)) =
  capture.start(
    metadata,
    client.Config("http://127.0.0.1:4417", "basic-outbox", 100, 1_048_576),
    client.browser_storage(),
    client.http_transport("http://127.0.0.1:4417"),
    // Upload the transitions of each second together, as one batch.
    1000,
  )
```

Steps:

1. Replace `capture.session(user_ref, build, contract, platform)` with
   `wire.Metadata(user_ref, build, contract, platform)` and pass it to `capture.start`.
2. Add the flush window as a new argument after `transport` (before `clock` in
   `capture.start_with_clock`). Pass `1000` for one batch per second, or `0` to close each
   batch at its first observation, which keeps one batch per observation.
3. Replace `capture.with_batching(...)` by deleting it. The window is the only setting.
4. Read the session as `Option(wire.Session)`: `capture.Info.session` is `None` until the
   collector answers. `capture.Info.saved` counts saved entries and rises by a whole
   batch at a time.
5. Expect that `capture.observe` called before the session is open records nothing and no
   longer stops capture. Recording begins with the first transition observed after
   the grant arrives, and that batch's checkpoint is the state before it, so the recording has no gap.
   A page that starts offline records nothing until it can open a session.
6. Call `capture.flush` where the application wants the open batch saved at once. A browser
   client already does this when the page becomes hidden or navigates away, and `capture.stop`
   saves the open batch first. Observations still in the open batch are in memory only, so
   they are lost if the page ends by a path that none of these covers.

Replay ranges start at batch boundaries, so a viewer reconstructs from the nearest earlier
checkpoint, at most 128 entries back.

## 2. Delivery discards rejected sessions, backs off and hands over

These behaviors change without any code change on your side.

- **Rejected sessions are discarded.** After a response that an identical retry cannot change,
  the client discards every saved batch of that session, reports the discard as a status,
  delivers the other sessions, and fails later capture for that session visibly. Before,
  such a batch stayed first in the durable queue for ever and blocked every later session in
  that browser. The packaged transport treats a 4xx response as a rejection except 401, 403, 407,
  408, 425 and 429, which stay retryable because the host can repair them (a collector
  token, an expired login).
- **Failed uploads back off.** The wait starts at 1.5 seconds, doubles with each consecutive
  failure, is capped at 60 seconds, and loses up to half of its length at random. A delivered
  batch resets it and `client.retry` starts a pass at once.
- **An idle client holds no timer.** A pass starts when a batch is saved, on an explicit retry
  and when a wait ends. The client no longer reports a status every 1.5 seconds. A status
  reaches the application only when its queue length, acknowledged count or detail changed.
  An application that used the periodic status as a heartbeat must stop doing so.
- **Unacknowledged batches are handed over when the page leaves.** On `visibilitychange` to
  hidden and on `pagehide`, the client first saves capture's open batch and then sends
  the saved batches that are not yet acknowledged through the transport's `keepalive` send,
  oldest first. Together they must fit in 64,000 bytes, and nothing after the first batch
  that does not fit is sent until the queue has drained. The collector admits a repeated batch
  idempotently, and every batch stays queued until its acknowledgement. Hosts that call
  `client.stop` on `pagehide`, as the examples do, abort only the regular upload, not the
  hand-over.
- **A cross-origin collector** must answer the preflight of the keepalive request as it does
  for the regular upload.

## 3. Transports have two operations and classify rejections

**What changed.** A transport opens a session and sends uploads.
`adapter.transport` takes `open`, `send`, `explain` and `rejected`, all labelled.
`adapter.rejecting_transport` is removed. `client.enqueue` takes a `wire.Upload`, and
`client.open` is new. A foreign (JavaScript) transport is `{ open(metadata, signal), send(body, signal) }`
and may add `keepalive(body)` for the page hand-over; a typed transport built with
`adapter.transport` has no keepalive send and is handed nothing.

**Why.** The client must ask for a session before it can upload, and it must know which errors
a retry cannot cure.

**Before (0.1.x)**

```gleam
adapter.transport(send, explain)
```

**After (0.2.0)** (`open_session`, `send_batch` and `explain` are your own functions)

```gleam
adapter.transport(
  // Receives the encoded metadata (`wire.encode_metadata`) and returns the
  // encoded grant (`wire.encode_grant`) that the collector issued.
  open: open_session,
  // Receives the encoded upload (`wire.encode_upload`) and returns the acknowledgement.
  send: send_batch,
  explain: explain,
  // True only for a refusal that an identical retry cannot change.
  rejected: fn(error) { error.permanent },
)
```

Steps:

1. Implement `open` as `POST /sessions` and `send` as `POST /batches` (see
   [section 5](#5-the-collector-routes)).
2. Pass `rejected: fn(_) { False }` to keep retrying every failure. Classify as rejected
   only permanent refusals; return `False` for failures the host can repair, such as expired credentials.
3. In a foreign transport, throw an `Error` whose `rejected` property is `true` for a permanent refusal.
4. Replace calls to `client.enqueue(client, batch, saved)` by
   `client.enqueue(client, wire.Upload(grant.token, batch), saved)`, with the grant from `client.open`.

## 4. The server opens sessions and accepts uploads with a write token

**What changed.** `retrace_server.open(db, metadata)` is new. It chooses a 22-character
URL-safe session id and a random 256-bit write token, stores only the token's SHA-256 digest,
and returns a `wire.Grant`. `retrace_server.accept` and `accept_in_transaction` take a
`wire.Upload` (the token and the batch) instead of a `wire.Batch`. A batch can no longer create
a session. The new `Unauthorized` error covers an upload whose token does not match its session
and an upload for a session that was never opened; nothing is written. `sessions` no longer
lists a session without an admitted batch.

**Why.** Reading a session reveals everything needed to build its next batch. Before, anyone
who could read a session could append forged history to it, and the real writer's next batch
then failed with `Conflict` or `OutOfOrder`. Now only the writer that opened a session can append.

**Before (0.1.x)**

```gleam
// A client chose the session id; the first batch created the session.
case retrace_server.accept(db, batch) {
  Ok(ack) -> reply_ack(ack)
  Error(reason) -> reply_error(reason)
}
```

**After (0.2.0)** (a sketch: `reply_grant`, `reply_ack`, `reply_not_found` and `reply_error` stand for your HTTP layer)

```gleam
// When a writer starts: authenticate the caller, then open its session.
case retrace_server.open(db, metadata) {
  Ok(grant) -> reply_grant(wire.encode_grant(grant))
  Error(reason) -> reply_error(reason)
}

// For every batch: the writer presents the token it was granted.
case retrace_server.accept(db, upload) {
  Ok(ack) -> reply_ack(ack)
  // Answer as for a missing session so a refusal reveals nothing about other sessions.
  Error(retrace_server.Unauthorized) | Error(retrace_server.NotFound) ->
    reply_not_found()
  Error(reason) -> reply_error(reason)
}
```

Steps:

1. Call `open` when a writer starts, after your own authentication, and choose `user_ref`
   from that authentication where it matters. Whoever opens a session is its only writer.
2. Send the grant to the writer, for example with `wire.encode_grant`. The token is shown
   once; the server cannot recover it.
3. Decode each incoming batch as an upload with `wire.decode_upload` and pass it to `accept`.
4. Add `Unauthorized` to every `case` that matches `retrace_server.Error` exhaustively.
5. Do not log or store the token. It is not part of the batch, so stored and read batches
   do not reveal it.

## 5. The collector routes

Applies to the development collector and to any host that reimplements its protocol.

| Route            | 0.1.x          | 0.2.0                                                                                                   |
| ---------------- | -------------- | ------------------------------------------------------------------------------------------------------- |
| `POST /sessions` | absent         | Body: session metadata (`user_ref`, `build`, `contract`, `platform`). Answers `201` with the grant.     |
| `POST /batches`  | Body: a batch  | Body: an upload, the batch fields plus `token`. The limit is `wire.max_upload_bytes` (1,049,088 bytes). |
| Unproven upload  | not applicable | `404`, as for a missing session. Invalid metadata or upload: `400`.                                     |

The collector's own dependencies on `retrace` and `retrace_server` follow the release.
`RETRACE_ALLOWED_ORIGINS` and `RETRACE_COLLECTOR_TOKEN` are unchanged. With a token set, the
packaged `client.http_transport` still sends none, so use a custom transport as the
[collector README](https://github.com/gleam-dream/retrace/blob/main/support/collector/README.md#access) describes.

## 6. Stored data and queued batches

- **Existing database.** `migrate` adds a nullable `write_digest` column to `retrace_sessions`
  and changes nothing else. Run it before the new host takes uploads. Sessions stored by
  0.1.x have no digest, so they accept no further batches (`Unauthorized`). Their stored
  batches are unchanged. Archive and erasure operations are unchanged.
- **Empty sessions.** An `open` whose reply is lost leaves a session with no batch. Listings omit it.
- **Session ids** are 22-character URL-safe strings, not UUIDs. Code that assumes the UUID format must
  accept any valid id (`wire.valid_id`).
- **Batches queued by a 0.1.x frontend** carry no token. The 0.2.0 collector answers them `400`,
  which the client treats as a rejection, so it discards them. This follows from the
  client and collector code; it was not exercised against a real browser queue. Let
  0.1.x clients drain before the host upgrade where those recordings matter.
- **Browser storage** needs no migration: the IndexedDB schema is unchanged.

## Core (`retrace`)

`retrace` 0.2.0 only adds to `retrace/wire`: `Metadata`, `Grant`, `Upload`,
`max_upload_bytes`, `session`, `metadata`, `validate_metadata`, `encode_upload`,
`encode_metadata`, `decode_metadata`, `encode_grant`, `decode_grant` and `decode_upload`. The
batch envelope, `retrace.record`, `checkpoint`, `resume` and replay are unchanged, so
an application that uses only the core, with its own storage, upgrades by changing the version.
