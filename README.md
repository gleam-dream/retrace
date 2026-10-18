# Retrace

Record selected application messages, deliver them durably, and reconstruct sessions
for inspection. The same Lustre example runs in a browser and a Tauri shell.

Retrace is experimental and distributed as source from this Git repository. Its APIs
may change before 1.0, and the packages are not published to Hex.

## Packages

| Package            | Owns                                                                      | Application supplies                                                 |
| ------------------ | ------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `retrace`          | Typed recording, checkpoints, reconstruction and wire validation          | Model, event types, safe codecs and pure reducer                     |
| `retrace_frontend` | Browser/Tauri delivery, Lustre capture/replay and optional viewer modules | Safe projections, adapters, full view and explicit runtime lifetimes |
| `retrace_server`   | Atomic admission, indexing, archive and retrieval                         | Database pool, object store and worker lifetime                      |

## Install

Use Gleam 1.16 or later. Declare only the packages your application imports, all at
the same revision. A Lustre browser or Tauri application typically starts with:

```toml
[dependencies]
retrace = { git = "https://github.com/gleam-dream/retrace.git", ref = "v0.1.0" }
retrace_frontend = { git = "https://github.com/gleam-dream/retrace.git", ref = "v0.1.0", path = "packages/retrace_frontend" }
```

A backend uses `retrace_server` with `path = "packages/retrace_server"` instead of
the frontend. Replace the tag with a full commit SHA for an immutable pin.

## Quick usage

The portable core records and reconstructs application-native types. JSON appears only
at the wire boundary.

```gleam
import retrace

pub fn main() {
  let origin = retrace.Origin("git-consumer", "counter-v1")
  let assert Ok(#(recorder, checkpoint)) = retrace.start(origin, 0)
  let assert Ok(#(_, entry)) = retrace.record(recorder, 3, elapsed_ms: 20)
  let assert Ok(player) =
    retrace.replay(checkpoint, "counter-v1", fn(state, message) {
      Ok(state + message)
    })
  let assert Ok(player) = retrace.step(player, entry)
  assert retrace.model(player) == 3
}
```

Choose replay-safe state and events before encoding. The application owns reducer
determinism and purity. The [consumer tests](test/retrace_test.gleam) show
checkpoint resume, typed reducer failure and gap recovery.

For a Lustre application, add `retrace_frontend` and wire capture once:

```gleam
import retrace_frontend/capture
import retrace_frontend/client
// ...
let session =
  capture.session("Warehouse", domain.build, domain.contract, "web")
let assert Ok(#(recording, connect)) =
  capture.start(
    session,
    client.Config("http://127.0.0.1:4417", "basic-outbox", 100, 1_048_576),
    client.browser_storage(),
    client.http_transport("http://127.0.0.1:4417"),
  )
// ...
let #(recording, save) =
  capture.observe(
    model.capture,
    model.stock,
    command,
    domain.encode,
    domain.encode_command,
  )
```

Observe each accepted transition with the previous state, mount a replay module in a
historical entrypoint, and mount `retrace_frontend/viewer` in a separate viewer page.
Every snippet here is an excerpt of code that compiles and runs; the
[usage topics](examples/README.md#usage-topics) map each step to its source and the check
that guards it. The [frontend README](packages/retrace_frontend/README.md) lists the modules.

## Choose an example

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

Open **http://127.0.0.1:5193/**, change inventory, and follow **Inspect this recording**.
Local PostgreSQL and S3-compatible data stays in ignored `.local/`.

## Learn more

- [Design](docs/design/design.typ): contexts for [recording](docs/design/recording/design.typ), [archive](docs/design/archive/design.typ) and [replay](docs/design/replay/design.typ), with the [context map](docs/CONTEXT-MAP.md).
- [Decisions](docs/adr/0001-compose-recording-and-storage.md) and the [coverage map](docs/COVERAGE.md).
- [Usage topics](examples/README.md#usage-topics): runnable code for each step, with its check.
- [Server package](packages/retrace_server/README.md) and [attribution](THIRD_PARTY.md).
- Gate and test commands are listed in [AGENTS.md](AGENTS.md).
