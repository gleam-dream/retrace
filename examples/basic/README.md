# Basic: record and replay a Lustre browser app

This small inventory app demonstrates the standard integration. It uses only
public Gleam APIs for capture and replay, provided IndexedDB persistence and HTTP
delivery, and the packaged viewer. There is no handwritten FFI and no Tauri
or native dependency. Vite belongs to this example; it does not borrow tooling
from the advanced example.

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
**Inspect this recording**. The viewer has its own `/viewer.html` entrypoint and
embeds the inert `/frame.html` application. The local collector runs on port 4417;
its shared database/object storage remain under `.local/`.

## Files to adapt

| File                                 | Your responsibility                                                         |
| ------------------------------------ | --------------------------------------------------------------------------- |
| `src/retrace_inventory/domain.gleam` | Safe stock/command types, codecs, pure reducer, full view and replay module |
| `src/retrace_inventory.gleam`        | Existing Lustre update plus capture start/observe/update/stop               |
| `src/retrace_inventory/frame.gleam`  | Mount the application's historical replay module                            |
| `src/retrace_inventory/viewer.gleam` | Configure the default collector reader and artifact resolver                |

The three HTML/JavaScript entrypoint pairs are conventional browser startup and
cleanup. `style.css` is the shared application appearance. `vite.config.mjs`
builds the three entrypoints and rejects native imports. `replay.test.mjs` proves
reconstruction with native application types, partial ranges and typed refusals.
`gleam.toml`/`manifest.toml` and `package.json`/`package-lock.json` own dependencies.

## Composition points

The application supplies codecs and reducer; the library owns sequencing,
persistence feedback and reconstruction. `capture.observe` never runs your
application effects. `viewer.new` composes a source and resolver independently.
Keep those defaults until you need the explicit replacement paths shown in the
[advanced example](../advanced/README.md).

The fixed 900 × 600 viewport makes presentation easy to follow. The development
build ID is mutable and does not preserve old code across source edits. The
advanced example shows immutable application-owned builds and Tauri delivery.

```sh
npm run build
node --test replay.test.mjs
# From repository root, with local services and this app running:
node dev/basic-browser-check.mjs
```
