# Advanced: native capture and replaceable adapters

The membership application uses the same public capture and replay APIs as the
[basic example](../basic/README.md). It adds Tauri, recorded viewport changes,
native command results, immutable release artifacts and an alternate local
archive. Application types and effects remain application-owned.

## Collector and Tauri path

Start `bash dev/services.sh` in the repository's Nix shell. In another terminal:

```sh
cd examples/advanced
npm ci
npm run dev
```

Open http://127.0.0.1:5190/?user=Ada. Start the separate inspection endpoint in a
third terminal inside Nix:

```sh
npm --prefix examples/advanced/viewer run dev
```

Open http://127.0.0.1:5191/?user=Ada. This viewer belongs to the advanced example;
it is not another adoption example. Add `&diagnostics` to the live app URL to
inspect capture and delivery status.

Browser capture selects IndexedDB; Tauri selects `retrace_client/tauri.storage()`.
Both use HTTP delivery and the default collector reader. Device information
comes from a real Rust command in Tauri; its result becomes a recorded message.
Replay displays the stored result without invoking the command again.

For desktop Tauri, stop the app's Vite process and run `npm run tauri -- dev`.
For the tested iOS Simulator workflow, follow
[dev/simulator](../../dev/simulator/README.md). Platform SDKs remain host tools.

## Custom storage without a collector

With `npm run dev` running, open:

- Live: http://127.0.0.1:5190/?user=Ada&storage=local
- Viewer: http://127.0.0.1:5190/viewer/index.html?user=Ada&storage=local

Both pages intentionally share port 5190: localStorage is scoped to an origin.
The local mode stores its outbox and accepted archive separately, acknowledges
saved ranges and implements session search/paging in Gleam. It is a browser,
single-writer development adapter, not a production storage recommendation.
It does not require the collector. Its mutable development renderer uses the
current application code.

The same `capture.observe` and `ReplayModule` are used in both modes. The adapter
selection changes only storage, transport and the viewer's source. Native Tauri
runs retain the normal collector path by default.

## Public seams you can replace independently

| Seam              | Advanced example                                               | Library retains                                      |
| ----------------- | -------------------------------------------------------------- | ---------------------------------------------------- |
| `Storage`         | Tauri store or custom localStorage outbox                      | Pending admission, ordering and queue delivery       |
| `Transport`       | HTTP or local archive acknowledgement                          | Receipt checking, deadlines and retry                |
| `viewer.Source`   | Collector reader or Gleam archive search/ranges                | Cancellation, range checks and retained-entry bounds |
| `viewer.Resolver` | Build manifest lookup with explicit development override       | Frame/build/origin checks                            |
| `ReplayModule`    | Membership model, pure reducer, complete view and event labels | Checkpoint verification and inert reconstruction     |
| `viewer.Config`   | Explicit 2,000-entry budget                                    | Playback controls and resource cleanup               |

Custom storage must enforce durable limits and idempotent writes. Custom
transports must honor cancellation. Viewer tasks return a cancellation function;
synchronous archive reads return a no-op. Applications own safe projections and
callback lifetimes, and can use the lower-level packages without the Lustre hook.

## Files

- `src/retrace_example.gleam`: live application and adapter selection.
- `src/retrace_example/domain.gleam`, `screen.gleam`, `replay.gleam`: application
  meaning, shared view and typed replay module.
- `src/retrace_example/local_archive.gleam`: custom typed source plus storage and
  transport access. `src/local_archive_ffi.mjs` is the browser-storage boundary.
- `src/retrace_example/api.gleam` and `src/example_ffi.mjs`: application-specific
  environment/build values, typed viewport translation and native command access.
- `src/retrace_example/frame.gleam`: inert historical application entrypoint.
- `viewer/src/retrace_viewer_example.gleam`: source/resolver/config composition.
- `src-tauri/`: native shell, storage plugin, permissions and Rust command.
- `dev/build.mjs`: application-owned live/replay build identity and preservation.
- `dev/history.test.mjs`: reconstruction and compatibility checks.

`npm run build` builds the live application and preserves its historical renderer
under `viewer/public/artifacts/<build>/`. Existing IDs cannot be overwritten.
This directory contains generated historical executables, not additional examples.
The [build guide](../../docs/application-builds.md) explains CI/deployment ownership.

Tests from the repository root inside Nix:

```sh
node dev/browser-check.mjs              # collector path; ports 5190 and 5191
node dev/composition-browser-check.mjs  # custom local path; port 5190
```
