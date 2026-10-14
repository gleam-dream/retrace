# Adopt Retrace in a Lustre application

The standard workflow is configured in Gleam. The packages own capture
coordination, durable delivery, reconstruction and the default viewer. Your
application owns safe data, codecs, reducer, view, identity and deployment.
No application-authored telemetry FFI is required. Normal HTML, styles, bundler
entrypoints and build metadata remain application setup.

## 1. Define what can be replayed

Choose a safe model and safe event type. Reuse application types when appropriate;
otherwise project them. Supply a model encoder/decoder, event encoder/decoder,
and pure reducer. Never serialize secrets merely because they are in the model.
Omit only transitions that cannot affect the replay model. An omitted meaningful
transition makes later checkpoints inconsistent.

Record results of effects, such as `DeviceReceived(value)`, as ordinary events.
Replay must not reissue HTTP requests, native calls or permission prompts. Values
from time and randomness that affect application state belong in recorded events.
The replay contract names compatible schema and reducer semantics; build identity
selects the historical executable and styles.

## 2. Connect capture once

Add the frontend from Git (see [installation](releases.md) for core and server):

```toml
[dependencies]
retrace_frontend = { git = "https://github.com/gleam-dream/retrace.git", ref = "v0.1.0", path = "packages/retrace_frontend" }
```

Keep direct `retrace`, `lustre` and codec dependencies where your application imports them.
The frontend package contains delivery, capture, replay and viewer modules; choose
modules per entrypoint. The core and server remain separate packages.
Keep a `capture.State` field in your Lustre model and a
`Recording(capture.Message)` variant in its message type.

```gleam
import retrace_frontend/client as client
import retrace_frontend/capture

let session = capture.session(user_ref, build_id, contract, "web")
let assert Ok(#(recording, connect)) = capture.start(
  session,
  client.Config(endpoint, "my-app-recordings", 2000, 8_388_608),
  client.browser_storage(),
  client.http_transport(endpoint),
)
// Store recording in the model; return effect.map(connect, Recording) from init.
```

The helper creates a session ID and monotonic clock. `start_with_clock` accepts
an explicit clock for deterministic consumers. Tauri uses `tauri.storage()` from
`retrace_frontend/client/tauri` instead of browser storage, with the normal npm plugin and
Tauri permission setup. Browser consumers need no native dependencies.

## 3. Observe accepted transitions

In the application-message branch of update, reduce the application state and
pass the **previous** state and approved message to the capture hook:

```gleam
let #(recording, save) = capture.observe(
  model.recording,
  model.live,
  message,
  domain.encode_model,
  domain.encode_message,
)
#(
  Model(..model, live: next_live, recording: recording),
  effect.batch([effect.map(save, Recording), application_effect]),
)
```

In the `Recording(message)` branch, call
`capture.update(model.recording, message)` and return `effect.none()`. Do not feed
those delivery messages back through `observe`. This is an explicit hook, so your
update and effects remain yours. Rejected domain transitions can remain unrecorded
when they do not change the safe model.

`capture.info` exposes session, captured count, locally saved count, delivery
status and optional failure. Local save and upload acknowledgement are different.
A capture error stops subsequent recording but does not suppress live updates.
The adapter emits one checkpoint/event batch per observation. Use the lower-level
core/client directly if your workload needs grouped batches.

Run `connect` before accepting recorded messages. Observing before connection
fails visibly instead of silently introducing a history gap. On unmount, execute
`capture.stop(state)` and discard that capture state. `retry` retries delivery;
it does not repair a failed recording. Start a fresh session after capture failure.
A crash before local save confirmation can still lose the newest transition.

See the actual [membership update](../examples/advanced/src/retrace_example.gleam) and
[independent inventory update](../examples/basic/src/retrace_inventory.gleam).
Both retain their application-native message/model types. Start with basic for defaults; advanced replaces adapters.

## 4. Expose one historical replay module

Import `retrace_frontend/replay` and construct `replay.ReplayModule` with codecs, pure reducer, equality, full
view, viewport projection and event labels. The application supplies this small
adapter; its live and replay entrypoints share the same view.

```gleam
import my_app/replay_adapter
import retrace_frontend/replay

replay.mount(replay_adapter.module(), build_id, "#app", 5000)
```

Retain the returned disposer. A fixed desktop viewport is a constant projection.
For responsive screens, `retrace_frontend/viewport.read()` and `.observe(callback)`
supply typed `Viewport(width, height, top, bottom)` observations. Translate them
into your own model and event schema, and call the observer's disposer on unmount.
Presentation fields never enter the portable core.

## 5. Mount the separate viewer

Use `retrace_frontend/viewer` from the same frontend dependency. A separate viewer
application also declares `retrace_frontend`. This is a complete standard host:

```gleam
import retrace_frontend/viewer as viewer

pub fn main() -> fn() -> Nil {
  let assert Ok(dispose) =
    viewer.new(
      viewer.collector("https://recordings.example"),
      viewer.artifacts("/replay-artifacts"),
    )
    |> viewer.mount("#viewer")
  dispose
}
```

The package supplies styles, search, original-time playback, scrubber, markers,
full-viewport scaling and iframe messaging. The browser bootstrap just imports
compiled Gleam, calls `main`, and retains/calls its disposer. No copied viewer
JavaScript, FFI or custom timer is needed. The containing page chooses its own
body margin; the examples use zero.

For advanced use, `Source` takes typed session and range functions, and `Resolver`
is a typed artifact lookup function. Each returns `Task(value)`: a callback-based
operation that replies once with `Result` and returns cancellation. Search,
selection and disposal cancel obsolete tasks; late replies cannot update the UI.
The [advanced archive source](../examples/advanced/src/retrace_example/local_archive.gleam)
implements these policies in Gleam. Custom client storage and uploads use
`retrace_frontend/client/adapter` typed constructors, with provider-specific errors and
explicit cancellation. The basic example has no handwritten FFI. The advanced
example retains only a thin localStorage IO binding; queue rules and receipt
construction live in Gleam. Defaults use collector HTTP and a manifest directory.

Customize the `Config` record's `max_entries` and `label_event`, or override
`.retrace-viewer` selectors in your stylesheet. Artifacts own application styles,
labels and viewport projection. A completely different viewer can reuse
`replay.load`, `describe` and `mount`, but the packaged shell does not
currently expose a replaceable UI component tree or separate playback controller.

## 6. Preserve artifacts and operate collection

Build live and replay entrypoints with one build ID; retain HTML, JavaScript,
styles and manifest for every deployed version. Follow the
[application-owned build recipe](application-builds.md). No metaprogramming or
builder package is needed. Missing or incompatible builds refuse playback.
Mutable development overrides are explicit with `viewer.with_development`.

The example collector composes PostgreSQL and object storage. Hosted
authentication, tenant isolation, retention and erasure remain deployment policy.
Viewer tasks permit custom authenticated readers without changing capture.
Default artifacts are trusted same-origin code. For authenticated hosted viewers,
the JavaScript `createViewer` option `frameMode: "opaque"` requires its artifact
resolver to return `{api: 1, build, isolated_html}`. This is a self-contained
HTML document assembled from verified immutable bytes by the application. The
viewer sets `sandbox="allow-scripts"` and `referrerpolicy="no-referrer"`; it never
grants same-origin, form, popup, download or top-navigation capabilities. The
assembler must embed scripts/styles/fonts, provide a restrictive CSP blocking
network access, and inject its own fixed trusted parent origin. Do not derive
that origin from recording content, query parameters, referrers or messages.

The artifact calls `replay.mount_with_parent_origin(app, build, selector,
max_entries, trusted_parent_origin)` instead of `mount`. It returns
`Result(fn() -> Nil, String)`, rejecting noncanonical HTTP(S) origins. The viewer
puts a fresh nonce in the iframe name before assigning srcdoc; the frame accepts
messages only from its parent window, exact configured origin, nonce and protocol
version. The viewer accepts only the selected frame window, opaque `null` origin,
nonce and protocol version. Sending to an opaque frame uses `*` only in this
explicit mode; no incoming origin check becomes a wildcard. Neither this channel
nor the iframe sandbox certifies application-supplied reducers as pure. The typed
Gleam viewer's existing `mount` continues to use same-origin URL artifacts.

This is still an experimental, bounded replay API: 5,000 retained events by
default, no lazy seek, live tail, automatic DOM capture or million-event UI claim.
The collector search returns the latest 100 sessions; it has no search pagination.
The example workflows and failure/recovery checks are retained as executable
evidence; Git availability does not imply a stable or production-hardened API.
