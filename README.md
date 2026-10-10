# Retrace

Record selected application messages, deliver them durably, and reconstruct sessions
for inspection. The same Lustre example runs in a browser and a Tauri shell.

This is a new local project on `feat/initial-replay`. Nothing is published to Hex
or submitted upstream. It is an initial working implementation, with deployment
policy still owned by the application.

## Run the example

From this repository, enter the development shell:

```sh
nix develop
lefthook install
```

The flake and basic tooling follow the sibling `sinal` repository. The shell adds
Node, Rustup, PostgreSQL and SeaweedFS for these examples. Tauri also requires the
host platform tools: Xcode on macOS; Android SDK/NDK for Android. Rustup uses your
installed default Rust toolchain; the Nix lock does not pin that toolchain.

In terminal one:

```sh
bash dev/services.sh
```

This starts repository-owned PostgreSQL on `127.0.0.1:5547`, an S3-compatible
SeaweedFS service on `127.0.0.1:8337`, and a Mist collector on
`127.0.0.1:4417`. Data survives restarts in ignored `.local/`. Ctrl-C stops the
services started by the script. The local fixture credentials are in the script;
no AWS account or existing database is used.

In terminal two, also inside `nix develop`:

```sh
cd examples/app
npm ci
npm run build:gleam
npm run dev
```

Open **http://127.0.0.1:5190/?user=Ada**. Add points, change the layout, or read
device information. “Record an unchanged state” demonstrates that recording tracks
messages even when application state is unchanged. Browse sessions, filter by
user reference, select a recording, and step through it. A page reload starts a
new session while delivering any saved batches from previous sessions.

For Tauri desktop, stop the Vite command and use:

```sh
npm run tauri -- dev
```

For an embedded frontend build:

```sh
npm run tauri -- build --debug --no-bundle
./src-tauri/target/debug/retrace-example
```

The native app uses the Tauri store plugin for its queue and a real Rust command
for device information. The browser uses IndexedDB and labels its browser result.
Both send the same format to the same collector and use the same session viewer.

### iOS and Android

The Rust entry point supports Tauri mobile, but this new example has not yet been
installed or validated on a phone. Generate the platform projects on a suitably
configured host with `npm run tauri -- ios init` or `npm run tauri -- android init`,
then use the corresponding `ios dev` or `android dev` command. Signing and the
platform SDKs are required separately.

`127.0.0.1` on a physical phone is the phone itself. Device deployment needs a
reachable HTTPS collector URL via `VITE_RETRACE_ENDPOINT`, matching Tauri CSP
configuration, and a host with authentication and authorization. The supplied
collector deliberately binds to loopback and is for local development. Simulator
and device runs are separate evidence from the desktop example.

## Package boundaries

| Location                  | Responsibility                                                | Runtime owner                                           |
| ------------------------- | ------------------------------------------------------------- | ------------------------------------------------------- |
| `src/retrace.gleam`       | Typed sequence, checkpoint, deterministic replay and recovery | Application supplies state, messages, reducer and clock |
| `src/retrace/wire.gleam`  | Versioned JSON envelope, limits and validation                | Application supplies safe payload codecs                |
| `packages/retrace_client` | Bounded local persistence, retry, exact acknowledgement       | Host starts/stops the JavaScript client                 |
| `packages/retrace_server` | PostgreSQL admission/indexing, archive and retrieval          | Host supplies pool, store and worker lifetime           |
| `examples/collector`      | Mist HTTP routes and archive loop                             | Local service script                                    |
| `examples/app`            | Shared Lustre live app, viewer and Tauri shell                | Browser or native shell                                 |
| `examples/server_checks`  | Separate consumer exercising storage failure/recovery         | Disposable test database                                |
| `vendor/timetravel`       | Pinned optional viewer inspector                              | Example only                                            |

The root package has no Lustre, Tauri, PostgreSQL or network dependency. Clients
and collectors do not depend on Time Travel. Its fork supplies inspection and
navigation in the example viewer; [provenance](vendor/timetravel/PROVENANCE.md)
records the revision and license. Retrace owns the recording protocol and delivery.

```text
Live app → projected message + checkpoint → durable client queue
                                              │ HTTP batch / durable receipt
                                              ▼
Viewer ← session search / stored batches ← Mist + PostgreSQL
                                              │ retryable gzip upload
                                              ▼
                                         S3-compatible store
```

## Portable core

Use local path dependencies until a release is published. Application types remain
application types; JSON is needed only at the wire boundary.

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
The shared app's [domain module](examples/app/src/retrace_example/domain.gleam)
contains its actual model/message codecs; [viewer](examples/app/src/retrace_example/viewer.gleam)
reconstructs the model using only the pure reducer. It never invokes application
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

## Checks

Inside the Nix shell:

```sh
bash dev/check.sh                 # both core targets, consumer builds, web bundle
# With dev/services.sh and Vite running:
python3 dev/backend-check.py      # real PostgreSQL + signed local S3 requests
bash dev/server-check.sh          # isolated DB; injected archive failures/recovery
node dev/browser-check.mjs        # offline reload, queue recovery, search, inert replay
```

If Playwright's Chromium is missing, install it from `examples/app` with
`npx playwright install chromium`. Browser checks retain screenshots in
`.artifacts/` and create disposable example sessions in the development backend.

Native runtime check (macOS arm64, local collector running):

```sh
cd examples/app
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

This first implementation records semantic state and messages, not video or
arbitrary screens. The inspector retains the newest 200 transitions; it verifies
the loaded history first, and plays fixed-duration steps rather than recorded
wall-clock timing. The example caps retrieval at 5,000 batches. Event payload
search, aggregation and analytics are not implemented.

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
