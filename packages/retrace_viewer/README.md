# Retrace viewer (experimental)

A default session inspection UI with a typed Gleam interface. The package owns
its DOM, scoped styles, playback clock, frame protocol and pending read lifetimes.
It has no Lustre, Tauri, application model or database dependency.

```gleam
import retrace_viewer as viewer

let config = viewer.new(
  viewer.collector("http://127.0.0.1:4417"),
  viewer.artifacts("/artifacts"),
)
let mounted = viewer.mount(config, "#viewer")
// Ok(dispose): retain and invoke on unmount; disposal is idempotent.
```

Mount one viewer per page: it owns the session/time URL parameters. The host
element must exist. Mount refuses invalid selectors and nonpositive
entry budgets. It supplies scoped styles automatically; the page owns body margin
and surrounding layout. Override `.retrace-viewer` selectors in your stylesheet.
`Config` exposes `max_entries` (default 5000) and `label_event` customization.
Application UI and CSS belong to the replay artifact.

## Replace independent boundaries

`Source(list_sessions, read_range)` and `Resolver` are ordinary typed Gleam
functions. Each returns `Task(value)`, a function that starts work when invoked,
calls its reply once with `Ok(value)` or `Error(reason)`, and returns a cancellation
function. Synchronous tasks return a no-op disposer. Asynchronous tasks must
release their resources on cancellation; late replies are ignored. Starting
network work before the task is invoked defeats this ownership contract.

- `list_sessions(user)` returns `List(Summary(session, sequence))`.
- `read_range(id, after, limit)` returns `Page(batches, next)`; batches are encoded
  wire strings and `limit` bounds their count. `next` is `Some(last_sequence)` when
  more pages remain, otherwise `None`. Absolute sequences must advance.
- `resolve(session)` returns `Artifact(build, url, development)`. Only matching
  build and same-origin URLs are accepted. The frame also validates build and
  contract against its own application module.

The default collector matches the retained Mist example: at most 128 batches per
read, session search limited to its latest 100 rows, and a ten-second HTTP deadline.
The default artifact resolver checks manifest api, build and contract.
`with_development` adds an explicit mutable build/contract override without
fallback for other builds. Custom tasks own their own deadlines and authentication.

Selection, repeated searches and disposal cancel obsolete tasks. Transport errors
appear in the UI and can be retried. Loaded ranges are validated before display;
`?after=N` can select a nonzero checkpoint. The first checkpoint must equal that
cursor, and the range must fit the entry budget. The shell seeks absolute sequence
numbers and also sends legacy position offsets for existing version-one artifacts.

The package uses a private JavaScript DOM implementation. Consumers do not author
FFI or copy it. For a fully different UI use the companion's `load`, `describe`
and `mount`; this package does not expose a separate headless playback controller.
It does not add live subscriptions, lazy seek or an unbounded cache.

See [the standard viewer](../../examples/advanced/viewer/src/retrace_viewer_example.gleam),
[the custom advanced source](../../examples/advanced/src/retrace_example/local_archive.gleam)
and [adoption journey](../../docs/adopting-lustre.md).
