# Coverage

| Part                                                                                    | Status   | Owner                                                                                     |
| --------------------------------------------------------------------------------------- | -------- | ----------------------------------------------------------------------------------------- |
| `src/retrace.gleam`, `src/retrace/wire.gleam`                                           | captured | Recording: Session and recording cursor; Batch and wire format                            |
| `test/`                                                                                 | captured | Recording: executable scenarios for the behavior rules                                    |
| `packages/retrace_frontend/src/retrace_frontend/client*`, `client_ffi.mjs`              | captured | Recording: Client delivery; Typed adapters                                                |
| `packages/retrace_frontend/src/retrace_frontend/capture*`, `capture_ffi.mjs`            | captured | Recording: Capture coordination                                                           |
| `packages/retrace_frontend/src/retrace_frontend/replay*`, `viewport*`, `channel.mjs`    | captured | Replay: Replay modules and frames; Isolated frames for hosted viewers                     |
| `packages/retrace_frontend/src/retrace_frontend/viewer*`, `viewer.mjs`, `range.mjs`     | captured | Replay: Viewer; Progressive loading                                                       |
| `packages/retrace_frontend/src/timeline.mjs`, `style.mjs`                               | captured | Replay: Viewer; Example applications                                                      |
| `packages/retrace_frontend/test/`                                                       | captured | Recording and Replay behavior rules                                                       |
| `packages/retrace_server/`                                                              | captured | Archive: Admission; Archival generations; Retrieval; Retention and erasure                |
| `support/collector/`                                                                    | captured | Archive: Collector protocol, hosting and storage ownership                                |
| `support/server_checks/`                                                                | captured | Archive: executable failure and recovery evidence; Retrace: Distribution and verification |
| `support/client_checks/`                                                                | captured | Recording: Typed adapters; separate consumer evidence                                     |
| `examples/basic/`, `examples/advanced/`                                                 | captured | Replay: Example applications; Build identity and replay artifacts                         |
| `examples/README.md`, `examples/*/*.test.mjs`, `examples/advanced/dev/*.test.mjs`       | captured | Retrace: Distribution and verification (runnable usage examples)                          |
| `dev/readme.test.mjs`                                                                   | captured | Retrace: Distribution and verification (README snippets are compiled excerpts)            |
| `dev/check.sh`, `dev/git-consumer-check.sh`                                             | captured | Retrace: Distribution and verification                                                    |
| `dev/*-check.*`, `dev/native-check.js`, `dev/opaque-frame-check.mjs`, `dev/services.sh` | captured | Retrace: Distribution and verification                                                    |
| `dev/simulator/`                                                                        | captured | Retrace: Distribution and verification (Simulator evidence)                               |
| Nix, manifests, locks, hooks, ignore rules, `.envrc`, `.gitattributes`, `.claude/`      | standard | Development and packaging conventions                                                     |
| `LICENSE`, `THIRD_PARTY.md`                                                             | standard | Licensing and attribution                                                                 |
| `README.md`, `AGENTS.md`, per-package, per-example and `support/` `README.md`           | standard | Entry points and agent instructions that point into the design layer                      |
| `docs/design/`, `docs/adr/`, `docs/CONTEXT-MAP.md`                                      | standard | Current contracts, vocabulary and decision rationale                                      |
