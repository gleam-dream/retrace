# Retrace

Read `docs/design/design.typ`, `docs/design/CONTEXT.typ`, `docs/COVERAGE.md` and
relevant ADRs before changing public contracts. Preserve explicit runtime owners.

- Root `retrace` is portable Gleam; keep Lustre, database and network imports out.
- `retrace_client` owns the JavaScript delivery runtime; applications own safe data.
- `retrace_server` borrows database and object-store resources; callers own workers.
- Use `nix develop`, `nix fmt -- PATH...`, and the scoped `dev/check.sh` gate.
- Design gates: `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`,
  then `nix run .#design-gate-check -- docs/design .`.
- Use only this repository's local development services; never read credential files.
- Native builds, browser tests, database tests and remote-cloud tests are distinct evidence.
- No publishing or upstream PR is part of the initial work.
