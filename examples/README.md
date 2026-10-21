# Examples

| Example                        | Start here when                                       |
| ------------------------------ | ----------------------------------------------------- |
| [Basic](basic/README.md)       | Adding recording to a Lustre browser app              |
| [Advanced](advanced/README.md) | Integrating native capabilities or replacing adapters |

Both use the same public capture, client, reconstruction and viewer APIs. Start the shared
local collector with `bash dev/services.sh` from the repository root inside `nix develop`.
Its design is in the [replay design](../docs/design/replay/design.typ).

## Usage topics

Usage is shown as code that compiles and runs. Each topic names its source and the check
that fails when the library's API moves. The `check.sh` lane is `bash dev/check.sh`; the
services lane needs `bash dev/services.sh` and the apps running (see [AGENTS.md](../AGENTS.md)).

| Topic                                                  | Code                                                                                                                                         | Verified by                                                                              | Lane     |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | -------- |
| Define what can be replayed                            | [`domain.gleam`](basic/src/retrace_inventory/domain.gleam)                                                                                   | [`replay.test.mjs`](basic/replay.test.mjs)                                               | check.sh |
| Connect capture, observe accepted transitions, deliver | [`retrace_inventory.gleam`](basic/src/retrace_inventory.gleam)                                                                               | [`adoption.test.mjs`](basic/adoption.test.mjs) records, delivers and replays             | check.sh |
| Mount the historical replay frame                      | [`frame.gleam`](basic/src/retrace_inventory/frame.gleam)                                                                                     | `npm run build` and the basic browser check                                              | services |
| Mount the viewer                                       | [`viewer.gleam`](basic/src/retrace_inventory/viewer.gleam), [advanced viewer](advanced/viewer/src/retrace_viewer_example.gleam)              | `npm run build`, `dev/viewer-api-browser-check.mjs`, progressive viewer check            | services |
| Custom storage, upload and viewer source in Gleam      | [`local_archive.gleam`](advanced/src/retrace_example/local_archive.gleam)                                                                    | [`local_archive.test.mjs`](advanced/dev/local_archive.test.mjs), `support/client_checks` | check.sh |
| Build identity and preserved replay artifacts          | [`build.mjs`](advanced/dev/build.mjs), [`identity.mjs`](advanced/dev/identity.mjs)                                                           | [`build.test.mjs`](advanced/dev/build.test.mjs) runs the recipe                          | check.sh |
| Install from Git and release checks                    | [`git-consumer-check.sh`](../dev/git-consumer-check.sh)                                                                                      | the independent consumer compilation and execution                                       | release  |
| Server admission, archive and erasure                  | [`collector`](../support/collector/src/retrace_collector.gleam), [`server_checks`](../support/server_checks/src/retrace_server_checks.gleam) | `bash dev/server-check.sh`, `python3 dev/backend-check.py`                               | services |
| Simulator capture and replay                           | [`dev/simulator`](../dev/simulator/README.md)                                                                                                | the Simulator runbook                                                                    | device   |

The release lane runs against the committed revision: `bash dev/git-consumer-check.sh`.
