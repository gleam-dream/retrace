# Replay the complete application

Run the application at `http://127.0.0.1:5190/?user=Ada` and the viewer at
`http://127.0.0.1:5191/?user=Ada`. Both use the loopback collector on port 4417.
Start each process from the commands in the root README. Native capture uses the
same viewer; the Simulator app embeds its frontend and needs no Vite app server.

Record a point, wait a few seconds, request device information, then open Details
and return to the card. Find that session in the viewer. Play preserves the wait.
Selecting an event seeks to its timestamp. Dragging the timeline reconstructs the
state at that time. Speed changes affect subsequent elapsed time; hiding the viewer
pauses it. A link includes `session` and `t` in milliseconds so it can reopen the
same point. Reload recording fetches events captured since the previous load.

The timeline represents a fully validated loaded range, through its last event.
It does not claim the user ended the session then. Empty intervals mean no events
were recorded in that range, not that every possible interaction was observed.
Equal-time events retain sequence order and appear together. Previous and Next
move between distinct recorded timestamps. Dense markers are clustered; the event
list retains each entry. The starting checkpoint is reachable at the beginning of the loaded range.

## Ownership

| Part                                                        | Owns                                                             | Does not own                 |
| ----------------------------------------------------------- | ---------------------------------------------------------------- | ---------------------------- |
| `retrace_example/domain.gleam`                              | App model, safe payloads, reducer, presentation observations     | Transport or effects         |
| `retrace_example/screen.gleam`                              | Complete app view, reused in live and historical entrypoints     | Viewer controls              |
| `retrace_lustre`                                            | Build/schema checks, checkpoints, reconstruction and inert frame | Live effects or storage      |
| `retrace_example/replay.gleam`                              | Membership codecs, view, labels and viewport projection          | Generic replay machinery     |
| `retrace_example/frame.gleam`                               | Historical Lustre entrypoint and inert view                      | Native calls or capture      |
| `packages/retrace_viewer/src/timeline.mjs`                  | Time-to-state selection and marker grouping                      | Timers, storage or DOM       |
| `retrace_viewer`                                            | Default interface, frame lifecycle, playback clock               | Collector or artifact policy |
| `examples/advanced/viewer/src/retrace_viewer_example.gleam` | Collector reads and build-to-artifact resolution                 | App model or reducer         |

The application, historical renderer and viewer configuration are Gleam. The
optional `retrace_viewer` package keeps DOM, frame messaging and animation timing
inside its implementation. Its defaults need no application-authored FFI:

```gleam
viewer.new(viewer.collector(endpoint), viewer.artifacts("/artifacts"))
|> viewer.mount("#viewer")
```

Retain and call the returned disposer when removing the viewer. Custom typed
`Source` and `Resolver` functions own storage, authorization and artifact lookup;
the viewer owns cancellation of their pending tasks. Search and session selection
ignore stale replies. See [the package contract](../packages/retrace_viewer/README.md)
for paging, cancellation, customization and development overrides.

## Preserve the matching build

`npm run build` in `examples/advanced` compiles Gleam, then runs the application-owned
`dev/build.mjs`. It chooses one build ID and injects it into both the live bundle
and historical renderer. CI may provide `RETRACE_BUILD_ID` containing letters,
digits, hyphens or underscores. Source Git revision and dirty status go in the
artifact manifest; no source file needs to contain its own future commit hash.

The live output goes to `examples/advanced/dist`. Historical HTML, JS, CSS and manifest
go to `examples/advanced/viewer/public/artifacts/<build>/`. The directory is ignored locally;
retain and deploy it with the application release. Existing build IDs are refused,
so a later local build cannot overwrite a recording's renderer. Each Tauri build
runs this same path. Missing or incompatible artifacts refuse playback; they never
fall back to the current UI. This local build does not sign artifacts or verify a
content digest. The [CI recommendation](application-builds.md) covers durable
publication and integrity policies.

`npm run dev` uses the visibly labelled mutable `membership-screen-v2-dev` build.
It is convenient while editing, but cannot preserve historical code across edits.
Use an embedded Tauri build or serve the production app bundle when testing
historical fidelity. Older `membership-v1` sessions remain stored and show an
unsupported-artifact explanation in this new viewer.

The iframe protocol checks origin, frame identity, a fresh per-load token,
protocol version and application build. Host messages load encoded batches or
seek a validated snapshot. Frame messages report readiness, validated timeline
metadata or failure. These checks prevent stale frame messages being mistaken for
the current session. They do not sandbox hostile artifacts. Only trusted local
same-origin code is supported by this example.

## Fidelity and bounds

The model captures CSS viewport width/height, top/bottom safe-area insets, card
layout, navigation and recorded native results. Resize observations are ordinary
application messages. The iframe uses those dimensions; the outer viewer scales
the frame to fit, preserving its responsive layout. Both entrypoints call the same
root view. The live-only capture diagnostic panel is outside that view.

This is application-state reconstruction. OS status-bar pixels, keyboard and
permission sheets are not replayed. Neither are arbitrary DOM mutations, scroll
positions, theme/locale changes or autonomous CSS animations. The replay document
disables animations and user interaction; adding those features requires explicit
application presentation events and a virtual-time policy. Typography can differ
between browser engines. The decorative phone border is not an iOS simulator.

The example validates the whole range before showing it and retains at most 5,000 event
snapshots plus the initial state. It accepts a nonzero starting checkpoint and rejects missing intermediate ranges, gaps, bad checkpoints, wrong builds,
unknown messages and oversized histories. This favors a clear experiment over
long-session memory efficiency; checkpoint-based lazy seeking is a future option.

## Checks

Run from the repository root inside Nix, with services, app and viewer running:

```sh
node --test packages/retrace_viewer/test/*.test.mjs
node --test examples/advanced/dev/history.test.mjs
node dev/browser-check.mjs
node dev/simulator/check_browser.mjs SESSION_UUID
```

The last check requires the actual Simulator capture produced by the retained
XCTest scenario. It checks the native result, deliberate idle gap, correct artifact,
full viewport, route changes and inert replay. Browser, Simulator and physical-phone
evidence remain distinct; this setup has no physical-phone deployment claim.

## Composition with another application

The experimental `retrace_lustre` companion now owns reconstruction and frame
lifetime. Membership and inventory supply their own typed replay modules. The
viewer gets labels and dimensions from artifact metadata and reads pages through
the typed `Source.read_range(id, after, limit)`; it no longer requires `loadSession` to
return the entire recording. See [the companion contract](../packages/retrace_lustre/README.md)
and [basic consumer](../examples/basic/README.md). It still retains a
bounded range of snapshots. This interface change does not imply lazy seek,
live tailing, or production-scale storage validation.
