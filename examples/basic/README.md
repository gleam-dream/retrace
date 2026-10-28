# Basic: record and replay a Lustre browser app

[![CI](https://github.com/gleam-dream/retrace/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/retrace/actions/workflows/ci.yml)
[![retrace on Hex](https://img.shields.io/hexpm/v/retrace?label=Hex%3A%20retrace)](https://hex.pm/packages/retrace)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A small inventory app that uses only public Gleam APIs for capture and replay, provided
IndexedDB persistence and HTTP delivery, and the packaged viewer. It has no handwritten
FFI and no native dependency. The protected topic below adds one live-only HTTP
adapter and uses the same capture, delivery and replay APIs.

From the repository root:

```sh
nix develop
bash dev/services.sh
```

In another terminal, also inside `nix develop`:

```sh
cd examples/basic
npm ci
npm run dev
```

Open http://127.0.0.1:5193/, receive or reserve a notebook, then follow
**Inspect this recording**. The viewer is `/viewer.html` and the inert replay frame is
`/frame.html`.

## Files to adapt

| File                                 | Your responsibility                                                         |
| ------------------------------------ | --------------------------------------------------------------------------- |
| `src/retrace_inventory/domain.gleam` | Safe stock/command types, codecs, pure reducer, full view and replay module |
| `src/retrace_inventory.gleam`        | Existing Lustre update plus capture start/observe/update/stop               |
| `src/retrace_inventory/frame.gleam`  | Mount the application's historical replay module                            |
| `src/retrace_inventory/viewer.gleam` | Configure the default collector reader and artifact resolver                |

## Checks

```sh
npm run build
node --test replay.test.mjs adoption.test.mjs protected.test.mjs
# From the repository root, with local services and this app running:
npm --prefix examples/advanced test -- basic-browser-check
```

`replay.test.mjs` loads recordings through the application's replay module.
`adoption.test.mjs` runs the application's accepted transitions through capture and
delivery, then replays the delivered batches and compares the result with the live state.
Both run in `bash dev/check.sh`. The [usage topics](../README.md#usage-topics) map each
adoption step to its source and check, and the [replay design](../../docs/design/design-layer.pdf)
holds the contracts. The [advanced example](../advanced/README.md) covers replaceable
adapters and immutable builds.

## Protected observation replay

Open [the protected topic](http://127.0.0.1:5193/protected.html) with the same local
collector and development server. Enter `x`, press **Check label**, then follow
**Inspect protected recording**. The shared view shows **Protected content** with
the original invalid decision. Enter a longer label to observe loading and the
external outcome; lock the field or expand details to record those presentation
choices too. The external check fetches a static example result and sends no label.

| Responsibility                                                              | Source                                                         |
| --------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Private label, business validation, accepted transitions, safe projection   | [`live.gleam`](src/protected_example/live.gleam)               |
| Live commands, HTTP interpreter and capture lifetime                        | [`protected_example.gleam`](src/protected_example.gleam)       |
| One view parameterized by field display; no validation or commands          | [`screen.gleam`](src/protected_example/screen.gleam)           |
| Presence-only field, strict codecs, recorded decisions and adoption reducer | [`observation.gleam`](src/protected_example/observation.gleam) |
| Historical entrypoint without live update or interpreter                    | [`frame.gleam`](src/protected_example/frame.gleam)             |

Replacing private input before rerunning validation is insufficient: `x` fails the
minimum of three characters, while **Protected content** passes it. An observation
contains presence and the original validation result. Replay adopts that result
without passing the placeholder into the live validator. The same approach retains
outcomes, loading, locking and expanded details. Checkpoints use the safe state
before the transition; events contain the safe observation after it.

The deterministic strategy remains useful when a safe event stream can reproduce
decisions. The inventory topic shares its pure reducer and view. The
[advanced domain](../advanced/src/retrace_example/domain.gleam) also records
`DeviceReceived` as an external result; only the live interpreter executes
`RequestDevice`. Choose protected observations when excluded inputs prevent
recomputing decisions. Both strategies use the unchanged `ReplayModule` contract.

The concrete integration evidence is Dash at source revision
`1468390b16437a53a727ccd0b55946cddb752bc3`. Its
`frontend/app/src/dash_app/customer_projection.gleam` projects accepted before/after
transitions, `customer_diagnostic.gleam` records finite decisions and adopts the
snapshot, and `customer_frame.gleam` uses Retrace's existing replay module.
`frontend/app/test/customer_diagnostic_test.gleam` checks private sentinels,
explicit decisions, malformed data and build refusal; the owning contract is
`docs/design/diagnostics/design.typ`. That checkout has no `customer_state.gleam`,
`customer_view.gleam` or `protected_field.gleam`, and its diagnostic module still
contains a separate view. This topic demonstrates the requested shared-view
pattern without claiming those absent modules were inspected.

The reusable addition is capture's failure handling for a fallible typed
projection. Dash's customer categories, eligibility and account rules, field
classification, presentation choices, schema invariants and live commands remain
application-owned. Presence and observation adoption need only ordinary application
types and functions; Retrace needs no second view system or customer vocabulary.

Privacy classification, presence policy, allowed decision categories and schema
invariants remain explicit application responsibilities. The example rejects
unknown fields, versions, categories, missing fields and inconsistent decisions.
It stores no raw copy, private sidecar or original label. Annotations alone do not
establish privacy. A poorly chosen projection, codec, label, session metadata or
callback can still disclose private information.

The topic uses a visibly mutable development build identity. Historical production
recordings require the [advanced immutable build recipe](../advanced/README.md)
to retain the exact live/frame pairing, including assets. Build mismatches are
refused; a compatible contract never permits substituting a different build.
The example preserves selected decisions, not excluded text, its line wrapping,
unrecorded presentation, external state or complete business history.

`protected.test.mjs` exercises real capture and queue delivery with in-memory
adapters. It checks private sentinels at persistence and upload boundaries,
malformed observation refusal, checkpoint consistency and nonzero range starts.
For a production-bundle browser check without the collector, run from the root
after `npm --prefix examples/basic run build`:

```sh
npm --prefix examples/advanced ci
npm --prefix examples/advanced exec playwright install chromium
node examples/advanced/node_modules/@playwright/test/cli.js test --config dev/protected-playwright.config.mjs
```

This separate browser check uses real IndexedDB and an intercepted acknowledging
HTTP endpoint. It seeks backwards and forwards, injects malformed data, and installs
traps for HTTP, storage writes and native commands in the historical page. Synthetic
input and clicks also exercise the replay message sink. The traps establish the
behavior of this artifact in Chromium; application callbacks can contain effects,
so hosts still own artifact trust, capability exclusion and isolation. No native
runtime or hosted service qualification is implied.
