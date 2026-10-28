# Examples

[![CI](https://github.com/gleam-dream/retrace/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/retrace/actions/workflows/ci.yml)
[![retrace on Hex](https://img.shields.io/hexpm/v/retrace?label=Hex%3A%20retrace)](https://hex.pm/packages/retrace)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

| Example                        | Start here when                                       |
| ------------------------------ | ----------------------------------------------------- |
| [Basic](basic/README.md)       | Adding recording to a Lustre browser app              |
| [Advanced](advanced/README.md) | Integrating native capabilities or replacing adapters |

Both use the same public capture, client, reconstruction and viewer APIs. Start the shared
local collector with `bash dev/services.sh` from the repository root inside `nix develop`.
Its design is in the [replay design](../docs/design/design-layer.pdf).

## Usage topics

Each compiled, runnable topic names its source and the check that fails when the
library's API changes. The `check.sh` lane is `bash dev/check.sh`; the
services lane needs `bash dev/services.sh` and the apps running (see [AGENTS.md](../AGENTS.md)).

| Topic                                                  | Code                                                                                                                                                                           | Verified by                                                                                                                           | Lane     |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| Define what can be replayed                            | [`domain.gleam`](basic/src/retrace_inventory/domain.gleam)                                                                                                                     | [`replay.test.mjs`](basic/replay.test.mjs)                                                                                            | check.sh |
| Protected observations with one shared view            | [`protected_example`](basic/src/protected_example.gleam), [`observation`](basic/src/protected_example/observation.gleam), [`screen`](basic/src/protected_example/screen.gleam) | [`protected.test.mjs`](basic/protected.test.mjs)                                                                                      | check.sh |
| Protected seeking and absence of live effects          | [browser check](../dev/protected-browser-check.mjs)                                                                                                                            | `node examples/advanced/node_modules/@playwright/test/cli.js test --config dev/protected-playwright.config.mjs` after the basic build | browser  |
| Connect capture, observe accepted transitions, deliver | [`retrace_inventory.gleam`](basic/src/retrace_inventory.gleam)                                                                                                                 | [`adoption.test.mjs`](basic/adoption.test.mjs) records, delivers and replays                                                          | check.sh |
| Mount the historical replay frame                      | [`frame.gleam`](basic/src/retrace_inventory/frame.gleam)                                                                                                                       | `npm run build` and the basic browser check                                                                                           | services |
| Mount the viewer                                       | [`viewer.gleam`](basic/src/retrace_inventory/viewer.gleam), [advanced viewer](advanced/viewer/src/retrace_viewer_example.gleam)                                                | `npm run build`, `dev/viewer-api-browser-check.mjs`, progressive viewer check                                                         | services |
| Custom storage, upload and viewer source in Gleam      | [`local_archive.gleam`](advanced/src/retrace_example/local_archive.gleam)                                                                                                      | [`local_archive.test.mjs`](advanced/dev/local_archive.test.mjs), `support/client_checks`                                              | check.sh |
| Build identity and preserved replay artifacts          | [`build.mjs`](advanced/dev/build.mjs), [`identity.mjs`](advanced/dev/identity.mjs)                                                                                             | [`build.test.mjs`](advanced/dev/build.test.mjs) runs the recipe                                                                       | check.sh |
| Git source consumer checks                             | [`git-consumer-check.sh`](../dev/git-consumer-check.sh)                                                                                                                        | the independent consumer compilation and execution                                                                                    | release  |
| Server admission, archive and erasure                  | [`collector`](../support/collector/src/retrace_collector.gleam), [`server_checks`](../support/server_checks/src/retrace_server_checks.gleam)                                   | `bash dev/server-check.sh`, `python3 dev/backend-check.py`                                                                            | services |
| Simulator capture and replay                           | [`dev/simulator`](../dev/simulator/README.md)                                                                                                                                  | the Simulator runbook                                                                                                                 | device   |

The release lane runs against the committed revision: `bash dev/git-consumer-check.sh`.

The protected browser lane also needs the advanced example's test dependencies
and Chromium on a fresh checkout. Run `npm --prefix examples/advanced ci` and
`npm --prefix examples/advanced exec playwright install chromium` before its
Playwright command.
