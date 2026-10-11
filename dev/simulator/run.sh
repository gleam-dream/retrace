#!/usr/bin/env bash
# Maintained regression: capture real iOS Simulator interactions and replay them on the Mac.
# Run inside the workspace's Nix mobile shell, with dev/services.sh already running.
set -euo pipefail
root=$(CDPATH="" cd -- "$(dirname -- "$0")/../.." && pwd)
export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.96.0}"
unset SDKROOT
cd "$root/examples/advanced"
if [[ ! -d node_modules ]]; then npm ci; fi
if [[ ! -d src-tauri/gen/apple ]]; then npm run tauri -- ios init --skip-targets-install --ci; fi
# Resolve only an available Simulator. Never select a physical phone.
simulator_id=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
matches = [device for devices in json.load(sys.stdin)["devices"].values()
           for device in devices if device["name"] == "iPhone 17 Pro"]
if len(matches) != 1:
    sys.exit("Expected one available iPhone 17 Pro simulator; select its UDID in this experiment")
print(matches[0]["udid"])
')
npm run tauri -- ios build --debug --target aarch64-sim --no-sign --archive-only --ci
app="src-tauri/gen/apple/build/retrace-example_iOS.xcarchive/Products/Applications/Retrace Example.app"
# bootstatus boots a shutdown device and waits until it is usable.
xcrun simctl bootstatus "$simulator_id" -b
xcrun simctl install "$simulator_id" "$app"
xcrun simctl terminate "$simulator_id" dev.gleamdream.retrace.example >/dev/null 2>&1 || true
xcrun simctl launch "$simulator_id" dev.gleamdream.retrace.example
open -a Simulator
