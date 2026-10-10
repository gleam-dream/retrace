# Coverage

| Part                                                 | Status       | Owner                                             |
| ---------------------------------------------------- | ------------ | ------------------------------------------------- |
| `src/retrace.gleam`, `src/retrace/`                  | captured     | Recording and replay                              |
| `packages/retrace_client/`                           | captured     | Client delivery                                   |
| `packages/retrace_server/`                           | captured     | Ingestion and archival                            |
| `examples/collector/`                                | captured     | Ingestion and archival; runtime ownership         |
| `examples/app/`                                      | captured     | Example application and viewer                    |
| `vendor/timetravel/`                                 | out-of-scope | Pinned upstream debugger; provenance retained     |
| `test/`, `dev/`, `examples/server_checks/`           | captured     | Executable scenarios for the behavior rules above |
| Nix, manifests, locks, hooks, licenses, ignore rules | standard     | Development and packaging conventions             |
| `docs/design/`, `docs/adr/`                          | standard     | Current contracts and decision rationale          |
