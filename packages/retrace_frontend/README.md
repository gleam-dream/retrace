# Retrace frontend

One JavaScript package for browser and Tauri recording, Lustre reconstruction,
and the optional inspection UI. It depends on portable `retrace` and Lustre;
PostgreSQL and S3 dependencies remain in `retrace_server`.

## Choose modules for your application

| Module                            | Purpose                                                                          |
| --------------------------------- | -------------------------------------------------------------------------------- |
| `retrace_frontend/capture`        | Observe accepted Lustre transitions and report persistence status                |
| `retrace_frontend/client`         | Configure durable delivery, retries and acknowledgements                         |
| `retrace_frontend/client/adapter` | Supply typed storage and transport operations                                    |
| `retrace_frontend/client/tauri`   | Explicitly select native persistence                                             |
| `retrace_frontend/replay`         | Reconstruct state and mount the historical inert application frame               |
| `retrace_frontend/viewport`       | Read or observe browser/WebView dimensions                                       |
| `retrace_frontend/viewer`         | Mount the default inspection UI with replaceable sources and artifact resolution |

```gleam
import retrace_frontend/capture
import retrace_frontend/client
import retrace_frontend/replay
import retrace_frontend/viewer
```

Import only the modules your entrypoint uses. Capture, replay frames and the viewer
retain separate startup and cleanup functions. Importing this package starts no
queue, viewer, worker or network request. Tauri persistence still requires explicit
selection and the native store plugin; a browser-only build needs no Tauri plugin.
All frontend consumers now resolve the Lustre dependency, including delivery-only
and viewer-only consumers.

Start with the [adoption guide](../../docs/adopting-lustre.md), then consult
[delivery and custom adapters](docs/client.md), [capture and replay](docs/replay.md),
or [viewer configuration](docs/viewer.md).

There are exactly two application examples: [basic](../../examples/basic/README.md)
and [advanced](../../examples/advanced/README.md). Install from the Git subdirectory
`packages/retrace_frontend` following the [installation guide](../../docs/releases.md).
Declare `retrace` directly as well when your application imports the core or wire
modules, using the same Git revision. This package is experimental and is not on Hex.
