# Advanced: native capture and replaceable adapters

A membership app that uses the same public APIs as the [basic example](../basic/README.md)
and adds Tauri, recorded viewport changes, native command results, immutable replay
artifacts and an alternate local archive.

## Run

Start `bash dev/services.sh` in the repository's Nix shell. In another terminal:

```sh
cd examples/advanced
npm ci
npm run dev
```

Open http://127.0.0.1:5190/?user=Ada. Start the viewer in a third terminal inside Nix:

```sh
npm --prefix examples/advanced/viewer run dev
```

Open http://127.0.0.1:5191/?user=Ada. Add `&diagnostics` to the app URL to show capture
status. For desktop Tauri, stop the app's Vite process and run `npm run tauri -- dev`. For
the iOS Simulator, follow [dev/simulator](../../dev/simulator/README.md).

## Custom storage without a collector

With `npm run dev` running, open the live page at
http://127.0.0.1:5190/?user=Ada&storage=local and the viewer at
http://127.0.0.1:5190/viewer/index.html?user=Ada&storage=local. Both share port 5190
because local storage is scoped to an origin.

## Files

- `src/retrace_example.gleam`: live application and adapter selection.
- `src/retrace_example/domain.gleam`, `screen.gleam`, `replay.gleam`: application meaning, shared view and typed replay module.
- `src/retrace_example/local_archive.gleam`: custom typed source plus storage and transport constructors.
- `src/retrace_example/frame.gleam`: inert historical entrypoint.
- `viewer/src/retrace_viewer_example.gleam`: source, resolver and config composition.
- `src-tauri/`: native shell, storage plugin, permissions and Rust command.
- `dev/build.mjs`, `dev/identity.mjs`: application-owned build identity and artifact preservation.

## Build and checks

```sh
npm run build                           # live bundle plus preserved replay artifact
RETRACE_BUILD_ID=membership-ios-482 npm run build
node --test dev/history.test.mjs dev/build.test.mjs dev/local_archive.test.mjs
# From the repository root, with services, app and viewer running:
node dev/browser-check.mjs              # collector path, ports 5190 and 5191
node dev/composition-browser-check.mjs  # custom local path, port 5190
```

## Native smoke check

On macOS arm64 with the local collector running:

```sh
npm run tauri -- build --debug --no-bundle --features native-smoke
RETRACE_NATIVE_SMOKE=1 ./src-tauri/target/debug/retrace-example
```

The opt-in feature drives the real WebView, native store plugin, Rust command and upload.
It is excluded from ordinary builds.

`build.test.mjs` runs the build recipe into scratch locations: one build ID in the live and
replay bundles, source provenance in the manifest, and a refusal to overwrite a published
build. `local_archive.test.mjs` runs the custom storage, upload and viewer source with an
in-memory stand-in for browser storage. Replay output goes to
`viewer/public/artifacts/<build>/`. Build identity, artifact preservation and adapter seams
are specified in the [replay design](../../docs/design/replay/design.typ), and the
[usage topics](../README.md#usage-topics) map each topic to its check.
