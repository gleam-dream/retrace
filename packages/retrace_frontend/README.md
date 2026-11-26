# Retrace frontend

> **Version 0.2.0 is a breaking release.** It works only with `retrace` 0.2.0 and a 0.2.0
> collector or `retrace_server`; see the [migration guide](https://github.com/gleam-dream/retrace/blob/main/docs/MIGRATION.md).
>
> - `capture.start` takes `wire.Metadata` and a flush window; `capture.session` and
>   `capture.with_batching` are removed, and capture uploads only in batches.
> - The collector opens the session and issues the write token; `client.enqueue` takes a
>   `wire.Upload`, and a transport has `open` and `send` operations.
> - A rejected session is discarded and failed uploads back off; `adapter.transport` takes `rejected`.
> - Unacknowledged batches are handed over when the page is hidden or closed.

[![CI](https://github.com/gleam-dream/retrace/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/retrace/actions/workflows/ci.yml)
[![retrace_frontend on Hex](https://img.shields.io/hexpm/v/retrace_frontend?label=Hex%3A%20retrace_frontend)](https://hex.pm/packages/retrace_frontend)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

One JavaScript package for browser and Tauri recording, Lustre reconstruction, and the
optional inspection UI. It depends on portable `retrace` and Lustre. PostgreSQL and S3
dependencies stay in `retrace_server`. The package is experimental.

## Modules

| Module                            | Purpose                                                                          |
| --------------------------------- | -------------------------------------------------------------------------------- |
| `retrace_frontend/capture`        | Observe accepted Lustre transitions and report persistence status                |
| `retrace_frontend/client`         | Configure durable delivery, retries and acknowledgements                         |
| `retrace_frontend/client/adapter` | Supply typed storage and transport operations                                    |
| `retrace_frontend/client/tauri`   | Explicitly select native persistence                                             |
| `retrace_frontend/replay`         | Reconstruct state and mount the historical inert application frame               |
| `retrace_frontend/viewport`       | Read or observe browser/WebView dimensions                                       |
| `retrace_frontend/viewer`         | Mount the default inspection UI with replaceable sources and artifact resolution |

Import only the modules an entrypoint uses. Importing the package starts no queue,
viewer, worker or network request, and a browser-only build needs no Tauri plugin.

## Install

Add the frontend and core packages from Hex:

```sh
gleam add retrace retrace_frontend
```

Commit `gleam.toml` and `manifest.toml` to retain the resolved versions.

## Quick usage

Start capture from session metadata. Its connection effect asks the collector to
open a session; the collector chooses the session id and issues the write token
every upload carries. Recording begins with the first transition observed after
the session is open. Capture uploads batches: the last argument of `capture.start`
is the flush window in milliseconds, and a window of zero sends each observation
as its own batch. When the page becomes hidden or navigates away, the client saves
the open batch and hands it over with the other unacknowledged batches;
`capture.flush` and `capture.stop` also save it. A transport has two operations,
`open` and `send`, and may add a `keepalive` send for that hand-over. Connect
capture once and observe each accepted transition with the previous state:

<!-- prettier-ignore-start -->

<!-- snips: ../../examples/basic/src/retrace_inventory.gleam#capture-observe -->
```gleam
let #(recording, save) =
  capture.observe(
    model.capture,
    model.stock,
    command,
    domain.encode,
    domain.encode_command,
  )
```

<!-- prettier-ignore-end -->

For a fallible safe projection, use `capture.observe_projected`. Its successful
pair contains the safe **previous** state and the safe event. Projection failure
stops capture without calling codecs or copying the application's error into
diagnostics; the live application still owns its transition and effects.

<!-- prettier-ignore-start -->

<!-- snips: ../../examples/basic/src/protected_example.gleam#protected-capture -->
```gleam
let #(recording, save) =
  capture.observe_projected(
    model.recording,
    live.transition(model.application, after),
    observation.encode,
    observation.encode_event,
  )
```

<!-- prettier-ignore-end -->

The [protected example](../../examples/basic/README.md#protected-observation-replay)
records field presence and accepted decisions, then adopts the observations through
the existing `ReplayModule`. It shares the live view and never validates protected
placeholder text. `observe` and the wire and replay contracts remain unchanged.
Neither helper infers privacy: classification, projection, codecs and callback
purity remain application responsibilities.

Mount a replay module in the historical entrypoint and retain its disposer:

<!-- prettier-ignore-start -->

<!-- snips: ../../examples/basic/src/retrace_inventory/frame.gleam -->
```gleam
import retrace_frontend/replay
import retrace_inventory/domain

pub fn mount() -> fn() -> Nil {
  let assert Ok(dispose) =
    replay.mount(domain.replay_module(), domain.build, "#app", 5000)
  dispose
}

```

<!-- prettier-ignore-end -->

Mount the viewer from a separate page, and retain and call the returned disposer:

<!-- prettier-ignore-start -->

<!-- snips: ../../examples/basic/src/retrace_inventory/viewer.gleam -->
```gleam
import retrace_frontend/viewer
import retrace_inventory/domain

pub fn main() -> fn() -> Nil {
  let resolver =
    viewer.artifacts("/artifacts")
    |> viewer.with_development(domain.build, domain.contract, "/frame.html")
  let assert Ok(dispose) =
    viewer.new(viewer.collector("http://127.0.0.1:4417"), resolver)
    |> viewer.mount("#viewer")
  dispose
}

```

<!-- prettier-ignore-end -->

These excerpts come from the [basic example](../../examples/basic/README.md), which compiles
and runs them. Custom storage and upload build from typed cold tasks with `client/adapter`,
and custom sources and resolvers return typed tasks to the viewer; the
[advanced example](../../examples/advanced/README.md) runs both. The
[usage topics](../../examples/README.md#usage-topics) list every topic with its check.
Module contracts are in the [design](../../docs/design/design-layer.pdf) for capture and
delivery and the [replay design](../../docs/design/design-layer.pdf) for replay and the viewer.
