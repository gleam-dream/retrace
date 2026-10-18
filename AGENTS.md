# Retrace

Read `docs/design/design.typ`, `docs/design/CONTEXT.typ`, `docs/COVERAGE.md` and
relevant ADRs before changing public contracts. Preserve explicit runtime owners.

- Root `retrace` is portable Gleam; keep Lustre, database and network imports out.
- `retrace_frontend` owns JavaScript delivery, Lustre capture/replay and the viewer; applications own safe data and runtime lifetimes.
- `retrace_server` borrows database and object-store resources; callers own workers.
- Use `nix develop`, `nix fmt -- PATH...`, and the scoped `dev/check.sh` gate.
- Design gates: `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`,
  then `nix run .#design-gate-check -- docs/design .`.
- Use only this repository's local development services; never read credential files.
- Native builds, browser tests, database tests and remote-cloud tests are distinct evidence.
- GitHub distribution uses the release checks in `docs/releases.md`. Hex publishing
  and upstream PRs require an explicit request.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(machine-owned; do not edit inside this fence — re-run setup to refresh)

## Agent skills

**Design layer** — `docs/CONTEXT-MAP.md` indexes the design documents:
the root design is `docs/design/design.typ`, each context has its own
`design.typ` and `CONTEXT.typ` under `docs/design/<context>/`, and
`docs/adr/` records decision rationale. The layer renders to one
`docs/design/design-layer.pdf`. `docs/COVERAGE.md` maps repository parts to
their design owners.

**Tracker** — GitHub issues in `gleam-dream/retrace`, accessed with
`gh issue list --repo gleam-dream/retrace` and `gh issue view NUMBER --repo gleam-dream/retrace`.
Labels bind roles as follows: `needs-triage` → `needs-triage`,
`needs-info` → `question`, `ready-for-agent` → `ready-for-agent`,
`ready-for-human` → `ready-for-human`, `in-progress` → `in-progress`,
`done` → `done`, `wontfix` → `wontfix`, `bug` → `bug`,
and `enhancement` → `enhancement`.

**AI disclaimer** — AI-authored tracker comments start with
`AI-assisted contribution.`

**Design gate** — `nix run .#design-gate-check -- docs/design .` checks render freshness,
vocabulary references and layer integrity (exit 0 clean, 1 violation, 2 error).
The gate is supplied by the pinned `design-layer` flake input.
`nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`
rebuilds the rendered document. `nix run .#design-gate-context -- docs/design --estimate`
estimates agent context; the same command without `--estimate` emits ephemeral
Markdown. `--manifest`, `--preview`, and `--section PATH --expect-digest DIGEST`
support loading selected sections. A bare Typst compilation does not run the gate.

**Context verification** — use native semantic blocks for lists, tables,
models and behavior. After authoring, verify context estimation and a selected
section export as well as rendering and the design gate.
Run these commands sequentially for each layer; they share its generated
`.render` workspace.

**Staleness** — source changes since the design last changed require a
conformance review before the layer is treated as current.

<!-- agent-skills:end -->
