# Retrace Lustre (experimental)

A small optional companion for a compiled application replay module. The portable
`retrace` package remains independent of Lustre and browser APIs.

Applications supply one typed `ReplayModule(model, message, error)` with their
own codecs, pure reducer, equality, full view, viewport projection and event labels.
See `examples/basic/src/retrace_inventory/domain.gleam` and
`examples/advanced/src/retrace_example/replay.gleam` for two different consumers.

```gleam
let app = domain.replay_module()
let snapshots = retrace_lustre.load(app, batches, build_id, 5000)
// In the historical iframe entrypoint:
let mounted = retrace_lustre.mount(app, build_id, "#app", 5000)
// On Ok(dispose), retain and call dispose when the host tears it down.
```

`load` validates the complete supplied range before returning snapshots. A range
can begin at a nonzero checkpoint; sequence numbers remain absolute. It verifies
all batch checkpoints with the application's equality function and retains typed
reducer errors in `InvalidReplay`. Decoding/compatibility failures use
`InvalidRange`. A failed call has no mutable state, so retry with corrected input.

`mount` renders the application's full view inertly and ignores its messages.
It executes no live effects or capture. The reducer/view must themselves be pure;
types cannot enforce this. The returned cleanup removes the frame subscription
and removes its owned mount node, releasing its browser event handlers. The pinned
Lustre SPA shutdown branch is unimplemented, so cleanup does not rely on it.
Use one frame runtime per iframe document. Cleanup is idempotent.

A fixed viewport needs only `fn(_) { Viewport(900, 600) }`. For changing dimensions,
`retrace_lustre/viewport.read()` and `.observe(callback)` return CSS dimensions
and vertical safe areas as a typed `Viewport(width, height, top, bottom)`.
The observer returns cleanup. The application chooses its event schema and
translates these observations into its own model.
This works in browser and Tauri WebViews, without a native plugin. It does not
record OS sheets, keyboard pixels or arbitrary scrolling.

## Live capture

`retrace_lustre/capture` coordinates the core recorder and client delivery through
immutable `State` and Lustre effects. `start` returns state and a connection effect;
map its `Message` into your application and feed it to `update`. `observe` takes
the state before an accepted transition, its message, and safe encoders. It never
runs the application reducer or effects. `info` reports capture and persistence
separately; failure stops further capture without disabling the application.
Run `stop` before discarding the state. The client is owned by this capture state;
do not share it across independently advancing application models.

See the [adoption guide](../../docs/adopting-lustre.md) for the complete update
pattern, Tauri selection, typed observation and runtime lifetime.

## Viewer host

The optional [retrace_viewer package](../retrace_viewer/README.md) provides the
default shell with typed, cancellable source and artifact adapters. The standard
configuration is Gleam; DOM and timing FFI stay private. Applications can replace
the shell entirely while reusing `load`, `describe` and `mount`.

Artifacts supply their own styles, labels and viewport projection. Only trusted
same-origin artifacts are supported. The immutable build recipe remains
application-owned. Reconstruction retains a bounded range of snapshots; there is
no live tailing or million-event virtualization claim.
