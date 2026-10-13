# Retrace

Record selected application messages, deliver them durably, and reconstruct sessions
for inspection. The same Lustre example runs in a browser and a Tauri shell.

Retrace is experimental and distributed through this Git repository. Its APIs
may change before 1.0; deployment policy remains application-owned.
See [installation and release checks](docs/releases.md) for Git dependencies.
The packages are not published to Hex.

For the Gleam capture and viewer integration, see the
[adoption journey](docs/adopting-lustre.md).

## Choose an example

There are exactly two application examples:

| Example                                 | Purpose                                                                                                      |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| [Basic](examples/basic/README.md)       | Browser capture and replay using library defaults, with no handwritten FFI or native dependencies            |
| [Advanced](examples/advanced/README.md) | Tauri/native integration, immutable replay artifacts, and custom storage/transport/viewer-source composition |

Start with basic. From the repository root:

```sh
nix develop
bash dev/services.sh
```

In another terminal inside Nix:

```sh
cd examples/basic
npm ci
npm run dev
```

Open **http://127.0.0.1:5193/**. Change inventory, then follow **Inspect this
recording**. Its live app, viewer and replay frame have separate entrypoints.
The shared collector is development tooling under `support/collector`; its PostgreSQL
and S3-compatible services keep local data in ignored `.local/`.

See the [examples index](examples/README.md) for both paths and the
[adoption guide](docs/adopting-lustre.md) for integrating an existing application.
The [advanced README](examples/advanced/README.md) covers ports 5190/5191, Tauri,
custom adapters and immutable builds. Browser and Simulator evidence are separate;
no physical-phone deployment is claimed by these examples.

## Package boundaries

| Package            | Owns                                                                      | Application supplies                                                 |
| ------------------ | ------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `retrace`          | Typed recording, checkpoints, reconstruction and wire validation          | Model, event types, safe codecs and pure reducer                     |
| `retrace_frontend` | Browser/Tauri delivery, Lustre capture/replay and optional viewer modules | Safe projections, adapters, full view and explicit runtime lifetimes |
| `retrace_server`   | Atomic admission, indexing, archive and retrieval                         | Database pool, object store and worker lifetime                      |

The root package has no Lustre, Tauri, database or network dependency. The frontend depends on core and Lustre; the server depends on core and backend libraries.
Frontend modules compose independently: using capture does not mount a viewer, and
using a viewer does not start capture or upload. The two examples import public APIs;
advanced configuration replaces adapters without forking shared validation.
[Attribution and revision provenance](THIRD_PARTY.md) remain after retiring the
unused Time Travel vendor sources.

```text
Live app → safe message + checkpoint → durable client queue
                                               │ transport + receipt
                                               ▼
Viewer ← source + artifact resolver ← collector / custom archive
```

## Portable core

Install the core from Git using the [installation guide](docs/releases.md).
Application types remain application types; JSON is needed only at the wire boundary.

```gleam
import retrace

let origin = retrace.Origin("session-1", "counter-v1")
let assert Ok(#(recorder, initial)) = retrace.start(origin, 0)
let assert Ok(#(_recorder, entry)) =
  retrace.record(recorder, 3, elapsed_ms: 20)
let assert Ok(player) =
  retrace.replay(initial, "counter-v1", fn(state, message) { Ok(state + message) })
let assert Ok(player) = retrace.step(player, entry)
assert retrace.model(player) == 3
```

See [the consumer tests](test/retrace_test.gleam) for application-native types,
checkpoint resume, typed reducer failure, incompatible contracts and gap recovery.
The shared app's [domain module](examples/advanced/src/retrace_example/domain.gleam)
contains its actual model/message codecs; its [replay module](examples/advanced/src/retrace_example/replay.gleam)
connects them to the frontend replay module. Reconstruction uses the pure reducer. It never invokes application
effects. Native results become ordinary messages before capture.

Choose replay-safe state and events **before** encoding. State formatters in a
debugger cannot redact data already captured. Reducer determinism and purity are
application obligations; Gleam function types cannot prove either.

## Delivery and storage contract

A batch contains immutable session metadata, a checkpoint and 1–128 contiguous
entries; encoded size is at most 1 MiB. Sequence and elapsed-time integers must
fit JavaScript's exact integer range. Session IDs must be unique per recording;
user references are labels for search, not authenticated identities.

The example sends one event and checkpoint per batch so each transition is easy
to inspect. A consuming application can group up to 128 events per batch to reduce
request and object counts, supplying the checkpoint before that group.

The client reports local save separately from upload. Its example queue is capped
at 2,000 batches / 8 MiB and uploads sequentially. Failed requests retain the same
batch. Only an acknowledgement matching its session and ending sequence removes
it. A local persistence failure stops further capture until a new runtime starts;
the live application can continue. An application transition is not atomically
committed with its asynchronous capture, so an abrupt kill before the save callback
can lose the newest transition. Native store durability here means its plugin
save completed, not a guarantee against power loss.

The server locks each session cursor in a database transaction. Identical retries
return the original receipt, including after archival. Conflicting content and
out-of-order batches are rejected. PostgreSQL commits before acknowledgement.
The archive worker uploads compressed bytes to a deterministic object key and
only then clears the database payload. Failed uploads leave the payload readable.
Retrieval checks its digest and wire structure. A crash after upload can leave an
orphan object; uploading the same immutable key is retryable.

The server borrows a `pog.Connection` and an `ObjectStore(put, get)`. Call
`migrate`, `accept`, `sessions`, `read`, and `archive_next` explicitly. The caller
owns migration timing and background workers. The supplied `s3.store` accepts
`bucket.Credentials`; production callers can use HTTPS and a different region.
The directory adapter provides another implementation without changing admission.
The collector example is a separate host, not an implicit server started by a
library import.

Local HTTP routes:

| Route                               | Result                                                        |
| ----------------------------------- | ------------------------------------------------------------- |
| `POST /batches`                     | `{session_id, ack}` after commit                              |
| `GET /sessions?user=Ada`            | Latest 100 summaries, optional exact user filter              |
| `GET /sessions/:id/batches?after=0` | Up to 128 encoded batch strings; continue after last sequence |
| `POST /archive`                     | Attempt one archive; example worker also calls this operation |
| `GET /health`                       | Listener liveness                                             |

## Preserve replay across application releases

The [application build guide](docs/application-builds.md) documents how to inject
build identity after Git checkout, preserve replay artifacts, and associate them
with recordings. It links the maintained application build recipe and a recommended CI
release sequence. Build scripts remain application-owned; no builder package or
new public API is introduced.

## Checks

Inside the Nix shell:

```sh
bash dev/check.sh                 # both core targets, consumer builds, web bundle
# With dev/services.sh, app (5190) and viewer (5191) running:
python3 dev/backend-check.py      # real PostgreSQL + signed local S3 requests
bash dev/server-check.sh          # isolated DB; injected archive failures/recovery
node dev/browser-check.mjs        # offline queue, full view, timing, inert replay
node dev/basic-browser-check.mjs       # default browser consumer (5193)
node dev/composition-browser-check.mjs # advanced custom adapters (5190)
node dev/viewer-api-browser-check.mjs  # cancellation, remount, typed viewport (5193)
node --test packages/retrace_frontend/test/*.test.mjs
node --test examples/advanced/dev/history.test.mjs
```

If Playwright's Chromium is missing, install it from `examples/advanced` with
`npx playwright install chromium`. Browser checks retain screenshots in
`.artifacts/` and create disposable example sessions in the development backend.

Native runtime check (macOS arm64, local collector running):

```sh
cd examples/advanced
npm run tauri -- build --debug --no-bundle --features native-smoke
RETRACE_NATIVE_SMOKE=1 ./src-tauri/target/debug/retrace-example
```

The opt-in feature drives the real WebView, native store plugin, Rust command and
upload. The test supplies render frames because a hidden automation WebView pauses
`requestAnimationFrame`; native IPC, storage and network calls remain real. It is
excluded from ordinary builds. This is desktop runtime evidence;
it does not establish mobile lifecycle or signing behavior.

Tooling/design checks:

```sh
nix fmt
nix flake check
nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf
nix run .#design-gate-check -- docs/design .
nix run .#design-gate-context -- docs/design --estimate
```

## Current limits

This implementation records semantic state and messages, not video or arbitrary
screens. The default viewer preserves recorded elapsed time and retains at most
5,000 entries plus the starting checkpoint. Range reads are paged, but snapshots
within the selected range are retained eagerly. Live tailing, lazy seeking,
event-payload search and analytics are not implemented.

The initial client uses fixed retry delays and one upload loop. A permanently
rejected batch blocks later uploads in that queue. Applications need a policy
for quarantine, backoff, consent and lifecycle handling before production use.
Tauri assumes one writing window per queue; cross-process locking is not provided.
The backend has no built-in tenant isolation, identity checks, retention, deletion,
rate limiting or archive repair. Its initial schema helper is not a versioned
migration framework. Object decompression assumes a trusted storage boundary.
The local S3 test is not an AWS deployment or power-failure durability test.

See the [design](docs/design/design.typ), [rendered design](docs/design/design-layer.pdf),
[vocabulary](docs/design/CONTEXT.typ) and [decision](docs/adr/0001-compose-recording-and-storage.md).

## Compose capture and replay

The frontend [replay API](packages/retrace_frontend/docs/replay.md) supplies a typed
replay module and disposable inert frame. The [inventory consumer](examples/basic/README.md)
proves fixed desktop presentation, custom labels, application-native errors and
the default browser/HTTP adapters without importing membership code.
The advanced example additionally proves replaceable local archive adapters. The existing membership
app uses the same module with recorded viewport changes.

The [client adapter contract](packages/retrace_frontend/docs/client.md) documents explicit
Tauri selection, custom transport/storage and bounded pending capture. The viewer
now requests bounded pages by absolute cursor; it still retains its selected
range and is not a million-event UI.
