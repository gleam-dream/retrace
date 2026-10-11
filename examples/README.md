# Two ways to compose Retrace

| Example                        | Start here when                                       | Composition                                                                                                                      |
| ------------------------------ | ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| [Basic](basic/README.md)       | Adding recording to a Lustre browser app              | Provided browser storage, HTTP transport, collector reader and default viewer. No handwritten FFI or native dependencies.        |
| [Advanced](advanced/README.md) | Integrating native capabilities or replacing adapters | Tauri storage/native results, immutable replay artifacts, and an optional custom local archive with its own typed viewer source. |

Each example owns its model, codecs, pure reducer, full application view and replay
entrypoint. Both use the same public capture, client, reconstruction and viewer
APIs. The advanced path changes adapters; it does not fork the recording system.

The shared local collector lives in `support/collector`; it is development
infrastructure started by `dev/services.sh`. The backend fault consumer lives in
`support/server_checks`. Neither is an additional application
example. Test runners live under `dev/`.
