# Retrace frontend

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

Connect capture once and observe each accepted transition with the previous state:

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
