# Retrace

Read `docs/design/design.typ` and the context designs under `docs/design/`, the glossaries beside them, `docs/COVERAGE.md` and relevant ADRs before changing public contracts. Preserve explicit runtime owners.

- Root `retrace` is portable Gleam; keep Lustre, database and network imports out.
- `retrace_frontend` owns JavaScript delivery, Lustre capture/replay and the viewer; applications own safe data and runtime lifetimes.
- `retrace_server` borrows database and object-store resources; callers own workers.
- Use only this repository's local development services; never read credential files.
- Hex publishing and upstream PRs require an explicit request. Releases follow the Git distribution rules in the design.

## Commands

CI runs on pushes and pull requests: `nix flake check`, the imported design check, and `nix develop --command bash dev/check.sh`, including the example packages.

Run inside `nix develop`. Native builds, browser tests, database tests and remote-cloud tests are distinct evidence, so report which ran.

```sh
nix fmt -- PATH...                        # format touched files
bash dev/check.sh                         # core targets, consumer builds, web bundle, runnable usage examples (scoped gate)
bash dev/git-consumer-check.sh            # independent Git consumers of the committed revision
node dev/progressive-viewer-browser-check.mjs
node --test packages/retrace_frontend/test/*.test.mjs
node --test examples/advanced/dev/*.test.mjs   # build identity, custom archive, history (after gleam build)
(cd examples/basic && node --test *.test.mjs)    # adoption walk-through and replay (after gleam build)
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

## Optional design rendering

When rendering or exporting design documentation, run commands sequentially because they share the generated `.render` workspace:

```sh
nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf
nix run .#design-gate-context -- docs/design --estimate
```

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(Repository validation policy overrides the framework defaults below.)

## Agent skills

**Design layer** — `docs/CONTEXT-MAP.md` indexes the design documents:
the root design is `docs/design/design.typ`, each context has its own
`design.typ` and `CONTEXT.typ` under `docs/design/<context>/`, and
`docs/adr/` records decision rationale. The layer renders to one
`docs/design/design-layer.pdf`. `docs/COVERAGE.md` maps repository parts to
their design owners.

**Tracker** — local markdown under `issues/`: one directory per feature
(`issues/<feature-slug>/`), the PRD at `issues/<feature-slug>/PRD.md`, issue
files at `issues/<feature-slug>/issues/<NN>-<slug>.md` numbered from 01. Each
issue file carries two header lines near the top — `Status: <state>`,
`Category: <category>`. Conversation appends to the bottom
of the file under a `## Comments` heading. Labels (canonical strings, adopted
verbatim): states `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `in-progress`, `done`, `wontfix`; categories `bug`,
`enhancement`.

**AI disclaimer** — AI-authored tracker comments start with
`AI-assisted contribution.`

**Design tools** — rendering and context export are optional authoring tools:
`nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf` and
`nix run .#design-gate-context -- docs/design --estimate`.
Validation requires formatting, compilation and behavioral unit/integration tests.
Run the pinned shared design validator with `nix run .#design-gate-check -- docs/design`.
Do not implement repository-local shape, documentation equality or checker self-tests.

**Staleness** — source changes since the design last changed require a
conformance review before the layer is treated as current.

<!-- agent-skills:end -->

## README snippets

Keep README Gleam examples in compiled example or consumer source. Use named
`snips-start` / `snips-end` regions (or include a whole example module), and retain
Prettier ignore ranges around generated README blocks. Format the source first,
then run `nix run .#snips -- --commands deny README.md packages/retrace_frontend/README.md`. CI runs
`nix run .#snips -- --check --commands deny README.md packages/retrace_frontend/README.md` using the shared pinned
package. Snips checks synchronization; existing example tests check behavior.
