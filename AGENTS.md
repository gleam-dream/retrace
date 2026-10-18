# Retrace

Read `docs/design/design.typ` and the context designs under `docs/design/`, the glossaries beside them, `docs/COVERAGE.md` and relevant ADRs before changing public contracts. Preserve explicit runtime owners.

- Root `retrace` is portable Gleam; keep Lustre, database and network imports out.
- `retrace_frontend` owns JavaScript delivery, Lustre capture/replay and the viewer; applications own safe data and runtime lifetimes.
- `retrace_server` borrows database and object-store resources; callers own workers.
- Use only this repository's local development services; never read credential files.
- Hex publishing and upstream PRs require an explicit request. Releases follow the Git distribution rules in the design.

## Commands

Run inside `nix develop`. Native builds, browser tests, database tests and remote-cloud tests are distinct evidence, so report which ran.

```sh
nix fmt -- PATH...                        # format touched files
bash dev/check.sh                         # core targets, consumer builds, web bundle, runnable usage examples (scoped gate)
bash dev/git-consumer-check.sh            # independent Git consumers of the committed revision
node dev/progressive-viewer-browser-check.mjs
node --test packages/retrace_frontend/test/*.test.mjs
node --test examples/advanced/dev/*.test.mjs   # build identity, custom archive, history (after gleam build)
(cd examples/basic && node --test *.test.mjs)    # adoption walk-through and replay (after gleam build)
node --test dev/readme.test.mjs           # README snippets are excerpts of compiled source
```

With `bash dev/services.sh` and the advanced app (5190) and viewer (5191) running:

```sh
python3 dev/backend-check.py              # real PostgreSQL with signed local S3 requests
bash dev/server-check.sh                  # isolated database; injected archive failures and recovery
node dev/browser-check.mjs                # offline queue, full view, timing, inert and progressive replay
node dev/basic-browser-check.mjs          # default browser consumer (5193)
node dev/composition-browser-check.mjs    # advanced custom adapters (5190)
node dev/viewer-api-browser-check.mjs     # cancellation, remount, typed viewport (5193)
```

If Playwright's Chromium is missing, run `npx playwright install chromium` in `examples/advanced`. Native runtime and Simulator checks are in `examples/advanced/README.md` and `dev/simulator/README.md`.

## References

- [Usage topics](examples/README.md#usage-topics): usage lives as compiled, runnable examples, each with the check that fails when the API moves. Add or change a topic there, not in prose.
- Retrace has no external oracle and no benchmark suite, so it keeps no `docs/ORACLE.md` or `docs/BENCHMARKS.md`. Concurrent-read timing is an executable check in `support/server_checks`, specified by ADR 0016.

## Design gate

Run sequentially after editing `docs/`, because the commands share the generated `.render` workspace:

```sh
nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf
nix run .#design-gate-check -- docs/design .
nix run .#design-gate-context -- docs/design --estimate
```

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
