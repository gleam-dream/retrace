# Try a recording from another device

Use `examples/advanced` for browser/Tauri capture and `examples/advanced/viewer` for replay.
`examples/basic` supplies an independent browser-only consumer using the provided browser and HTTP adapters. The maintained Simulator checks are in `dev/simulator/`.

## Choose where to capture

| Capture source       | What it exercises                                            | Collector connection                                       |
| -------------------- | ------------------------------------------------------------ | ---------------------------------------------------------- |
| Mac browser          | Messages, browser queue, upload and replay                   | Loopback collector on the same Mac                         |
| iOS Simulator on Mac | Tauri WebView, native queue and available iOS commands       | Mac collector; verify reachability in the chosen simulator |
| Physical iPhone      | Real device runtime, native queue, permissions and lifecycle | Reachable development endpoint or hosted HTTPS collector   |

All three produce the same recording envelope. Use the Mac browser to inspect
sessions from any source. The current example records `membership-screen-v2` and
resolves a matching compiled artifact for embedded builds. See
[viewer composition](replay-viewer.md) for the development-build distinction.

```text
Phone: tap → application message → local queue → collector on Mac
                                                   ↓
                                        PostgreSQL → object storage
                                                   ↓
Mac browser: search sessions → select phone session → Play / seek / speed
```

## First exercise on the Mac

Start services and the app using the commands in the [README](../README.md#run-the-example).
Open http://127.0.0.1:5190/?user=Ada.

1. Add a point, change the layout and read device information.
2. Pause for a few seconds, then open Details and return to the card.
3. Open http://127.0.0.1:5191/?user=Ada and select the new session.
4. Play or scrub the timeline. The wait and full application screen are preserved.

Add `&diagnostics` to the browser app URL to show queue status and its session ID.
Every app launch has a distinct session ID. The viewer never starts a recording.

The user reference is a search label, not an authenticated identity. The native
example currently defaults to `Ada`, so use that filter when looking for phone
sessions. The recorded device result distinguishes an iOS session from a browser
or macOS session.

## Run the local Simulator setup

The [Simulator experiment](../dev/simulator/README.md) provides a
launch recipe and a native UI capture check. From the Retrace root, with the
collector and Mac viewer already running:

```sh
nix develop ../oversight#mobile --command bash dev/simulator/run.sh
```

This reuses the sibling Oversight mobile toolchain and the installed iPhone 17 Pro
Simulator. The embedded app connects to the existing collector at loopback, so no
LAN bridge or iOS HTTP exception is required. The native UI check captured an iOS
result and the browser check replayed that exact stored session.

## Repeat on a phone

Install a development build of the Tauri example. Tauri supports physical devices
and the iOS Simulator through its [iOS CLI](https://v2.tauri.app/reference/cli/).
The same Apple signing and device trust requirements used for the earlier mobile
prototype apply to this app's bundle identifier.

The native app must be built with a collector endpoint the phone can reach. Its
`VITE_RETRACE_ENDPOINT` is bundled into the frontend. The default loopback address
points at the phone itself when used on a physical device. The Tauri CSP and iOS
network policy must also permit the selected endpoint.

For a local test, keep the Mac awake and the phone on the same network. A temporary
bridge can expose the required collector routes while leaving PostgreSQL and
object storage bound to loopback. Give that bridge an explicit access policy;
the example collector has no authentication. A hosted HTTPS collector is the
alternative when the phone must work away from the Mac. The current package does
not provide a hosted deployment or a ready-made authenticated phone bridge.

Repeat the four actions above on the phone, then browse its session on the Mac.
Nothing requires capture to originate in a browser. The browser is simply the
convenient inspection surface.

## Try interrupted delivery

After a phone build with embedded frontend assets is connected successfully:

1. Disconnect the phone from the collector's network.
2. Add a point and wait for the local save counter to advance. The queued count
   should remain above zero while the collector is unreachable.
3. Reconnect, keep the app in the foreground, and wait for the queue to drain.
4. Refresh the session list on the Mac and replay the newly delivered events.

A development app that loads its frontend from Vite still needs that server to
start. Use embedded assets for this offline exercise. Do not treat closing the app
before its local save confirmation as a durable recording.

## What replay shows

Replay reconstructs explicitly captured application state and messages. It can
show that a device request completed and the result recorded by the application.
It does not record video, arbitrary taps outside recorded handlers, system
permission dialogs or screens owned by other native applications.

Browser checks, simulator checks and physical-device observations are separate
evidence. A successful build or installation does not establish that a phone
uploaded a session. Confirm that by finding its session ID and replaying its
recorded native result on the Mac.

### Opaque replay frame lifecycle

Run `npm ci` in `examples/advanced`, then run
`CHROME_BIN=/path/to/chrome nix develop --command node dev/opaque-frame-check.mjs`.
Omit `CHROME_BIN` to use Playwright's installed Chromium. This disposable loopback
fixture verifies the real viewer's script-only opaque frame loads and seeks,
creates a new named browsing context for every recording load, and disposes it.
The Node protocol tests cannot certify browser `window.name` navigation behavior.
