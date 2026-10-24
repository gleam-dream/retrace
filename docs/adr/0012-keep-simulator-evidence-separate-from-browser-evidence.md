# Keep Simulator evidence separate from browser evidence

<a id="adr-0012"></a>

Recorded on 2026-10-17. The runbook and its retained check live in `dev/simulator/README.md` and `dev/simulator/check_browser.mjs`.

## Decision

The retained iOS Simulator scenario drives the embedded Tauri build with native
UI input, delivers through the native queue to the loopback collector, and
replays the stored session in a desktop browser. Its result is reported as
Simulator evidence, distinct from browser, backend and physical-device
observations.

## Rationale

A browser test cannot establish native store, IPC or WebView behavior, and a
Simulator run cannot establish device permissions, background delivery, signing
or power-loss durability. A successful build or installation says nothing about
whether a device uploaded a session. Only the session ID found and replayed on
the desktop proves an upload.

## Consequences

The Simulator regression inputs stay under the development directory, and
generated projects, archives and screenshots stay ignored. A physical-device
claim needs a collector endpoint the phone can reach, a network policy that
permits it, and an explicit access policy for any bridge, because the
development collector has no authentication. An opaque replay frame check runs in
a real browser because Node protocol tests cannot verify named browsing-context
behavior.
