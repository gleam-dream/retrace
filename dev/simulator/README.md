# iOS Simulator regression

This harness checks that the Tauri application records real Simulator interactions
through the native queue, uploads to the loopback collector, and replays that exact
session in the Mac browser.

This uses the maintained `examples/advanced` application. There is no LAN listener, HTTP-policy change,
physical-device installation or new package API.

## Play

The setup has three processes. From the Retrace repository root, start the local
collector and its storage in one terminal:

```sh
nix develop --command bash dev/services.sh
```

Start the Mac viewer in another terminal:

```sh
nix develop --command bash -c 'cd examples/advanced && npm ci && npm run build:gleam && npm run viewer'
```

Build, install and launch the Simulator app:

```sh
nix develop ../oversight#mobile --command bash dev/simulator/run.sh
```

The launch recipe reuses this workspace's sibling Oversight mobile Nix shell for
XcodeGen, CocoaPods and native tooling. It requires Xcode with the iOS Simulator
runtime, Rust 1.96.0 with the Apple simulator target, and an available Simulator
named `iPhone 17 Pro`. It resolves that name through `simctl`, so it cannot select
a physical phone. It leaves the installed app open after the command exits.

The app embeds its frontend. `tauri ios dev --no-dev-server` did not activate
bundled asset handling in the tested setup; this recipe instead uses
`tauri ios build --debug --target aarch64-sim --no-sign --archive-only`, then
`simctl install` and `simctl launch`. No Apple development signing is needed.

1. In Simulator, choose **Add a point**, wait a few seconds, then choose
   **Record an unchanged state** and **Read device information**.
2. Open **Details**, then **Back to card**. The device result is `ios / aarch64`.
3. On your Mac, open http://127.0.0.1:5191/?user=Ada and select the new session.
4. Play, scrub or select event timestamps. The viewport and idle gap are preserved.

Keep the collector running. The Simulator uses the Tauri store plugin and defaults
to user reference `Ada`. Each embedded build creates and retains its matching
replay artifact in `examples/advanced/viewer/public/artifacts/`. Do not delete that directory
while testing historical sessions. See [viewer composition](../../docs/replay-viewer.md).

To open the already installed app again without rebuilding, open Simulator and
choose **Retrace Example**, or use `xcrun simctl launch SIMULATOR_UDID
dev.gleamdream.retrace.example`.

## Retained checks

`Tests/Capture.swift` launches the installed app, taps its real accessible UI
controls and checks the native iOS result. It uses XCTest rather than replacing
the WebView, native store, IPC or network calls. `project.yml` defines a separate
UI test runner.

Inside the mobile Nix shell, from the Retrace root:

```sh
mkdir -p .artifacts/simulator-check
xcodegen generate --spec dev/simulator/project.yml --project .artifacts/simulator-check
xcodebuild test -quiet \
  -project .artifacts/simulator-check/RetraceSimulatorCheck.xcodeproj \
  -scheme RetraceSimulatorCheck \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -derivedDataPath .artifacts/simulator-check/derived
```

Find the new session in the collector or viewer. Then check cross-device replay:

```sh
node dev/simulator/check_browser.mjs SESSION_UUID
```

The browser check expects six application events, plus any startup viewport
observations. It verifies the native result, a gap of at least three seconds,
original-speed playback, shared full-screen rendering, navigation, zero replay
uploads and unchanged history. Screenshot and JSON evidence are written to ignored
`.artifacts/simulator-check/`.

## Evidence and limits

The retained scenario uses native XCTest input on iPhone 17 Pro Simulator, then
reads that stored session in Chromium on the Mac. It exercises an embedded Tauri
build and its separately compiled historical renderer. Physical-device behavior,
background delivery and power-loss durability remain outside this experiment.

This directory contains the maintained Simulator regression inputs. Generated Xcode
projects, archives, screenshots and check outputs remain ignored.
