# Coverage

| Part                                                 | Status       | Owner                                                          |
| ---------------------------------------------------- | ------------ | -------------------------------------------------------------- |
| `src/retrace.gleam`, `src/retrace/`                  | captured     | Recording and replay                                           |
| `packages/retrace_frontend/`                         | captured     | Client delivery; Lustre replay composition; Viewer composition |
| `packages/retrace_server/`                           | captured     | Ingestion and archival                                         |
| `support/client_checks/`                             | captured     | Client delivery; separate typed adapter consumer evidence      |
| `support/server_checks/`                             | captured     | Executable server failure and recovery evidence                |
| `support/collector/`                                 | captured     | Ingestion and archival; development runtime ownership          |
| `examples/basic/`, `examples/advanced/`              | captured     | Lustre replay composition; Example application and viewer      |
| `test/`, remaining `dev/`                            | captured     | Executable scenarios for the behavior rules above              |
| Nix, manifests, locks, hooks, licenses, ignore rules | standard     | Development and packaging conventions                          |
| `docs/ui-style.md`                                   | standard     | Example presentation conventions                               |
| `docs/adopting-lustre.md`                            | out-of-scope | Adoption guidance                                              |
| `docs/design/`, `docs/adr/`                          | standard     | Current contracts and decision rationale                       |

`docs/application-builds.md` describes the advanced application's retained build
recipe. `docs/testing-devices.md` and `dev/simulator/` distinguish Simulator
runtime evidence from browser tests. `docs/replay-viewer.md` documents the shared
viewer and fidelity limits. The examples index gives the two adoption paths.
