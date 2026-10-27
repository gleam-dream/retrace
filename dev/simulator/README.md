# iOS Simulator regression

[![CI](https://github.com/gleam-dream/retrace/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/retrace/actions/workflows/ci.yml)
[![retrace on Hex](https://img.shields.io/hexpm/v/retrace?label=Hex%3A%20retrace)](https://hex.pm/packages/retrace)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

Runs the `examples/advanced` Tauri app in the iOS Simulator, records native UI input through
the native queue to the loopback collector, and replays that session in the Mac browser.

## Run

From the repository root, start the collector and its storage:

```sh
nix develop --command bash dev/services.sh
```

Start the Mac viewer in another terminal:

```sh
nix develop --command bash -c 'cd examples/advanced && npm ci && npm run build:gleam && npm run viewer'
```

Build, install and launch the Simulator app. This uses the sibling `oversight` mobile Nix
shell for XcodeGen, CocoaPods and native tooling, and requires Xcode with the iOS
Simulator runtime, Rust 1.96.0 with the Apple simulator target and a Simulator named
`iPhone 17 Pro`:

```sh
nix develop ../oversight#mobile --command bash dev/simulator/run.sh
```

In Simulator, choose **Add a point**, **Record an unchanged state** and **Read device
information**, then open **Details** and **Back to card**. Open
http://127.0.0.1:5191/?user=Ada and select the new session.

## Retained checks

`Tests/Capture.swift` taps the real accessible controls through XCTest. Inside the mobile
Nix shell, from the repository root:

```sh
mkdir -p .artifacts/simulator-check
xcodegen generate --spec dev/simulator/project.yml --project .artifacts/simulator-check
xcodebuild test -quiet \
  -project .artifacts/simulator-check/RetraceSimulatorCheck.xcodeproj \
  -scheme RetraceSimulatorCheck \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -derivedDataPath .artifacts/simulator-check/derived
node dev/simulator/check_browser.mjs SESSION_UUID
```

Evidence and limits are specified in the [design](../../docs/design/design-layer.pdf).
