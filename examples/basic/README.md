# Basic: record and replay a Lustre browser app

A small inventory app that uses only public Gleam APIs for capture and replay, provided
IndexedDB persistence and HTTP delivery, and the packaged viewer. It has no handwritten
FFI and no native dependency.

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
node --test replay.test.mjs adoption.test.mjs
# From the repository root, with local services and this app running:
node dev/basic-browser-check.mjs
```

`replay.test.mjs` loads recordings through the application's replay module.
`adoption.test.mjs` runs the application's accepted transitions through capture and
delivery, then replays the delivered batches and compares the result with the live state.
Both run in `bash dev/check.sh`. The [usage topics](../README.md#usage-topics) map each
adoption step to its source and check, and the [replay design](../../docs/design/replay/design.typ)
holds the contracts. The [advanced example](../advanced/README.md) covers replaceable
adapters and immutable builds.
