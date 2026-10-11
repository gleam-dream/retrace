//// Default replay UI with replaceable typed data sources. Browser target only.
//// Mount supplies scoped default styles; override them in your application's
//// stylesheet to customize presentation. Replay remains application-owned.

import gleam/option.{type Option}
import retrace/wire

/// Start when called; reply once and return cancellation for pending work.
/// Cancellation must release your resources. Late replies are ignored by mount.
pub type Task(value) =
  fn(fn(Result(value, String)) -> Nil) -> fn() -> Nil

pub type Summary {
  Summary(session: wire.Session, sequence: Int)
}

pub type Page {
  Page(batches: List(String), next: Option(Int))
}

pub type Artifact {
  Artifact(build: String, url: String, development: Bool)
}

pub type Source {
  Source(
    list_sessions: fn(String) -> Task(List(Summary)),
    read_range: fn(String, Int, Int) -> Task(Page),
  )
}

pub type Resolver =
  fn(wire.Session) -> Task(Artifact)

pub type EventLabel {
  EventLabel(sequence: Int, elapsed_ms: Int, kind: String, label: String)
}

pub type Config {
  Config(
    source: Source,
    artifacts: Resolver,
    max_entries: Int,
    label_event: fn(EventLabel) -> String,
  )
}

pub fn new(source: Source, artifacts: Resolver) -> Config {
  Config(source, artifacts, 5000, fn(event) { event.label })
}

/// Mount owns DOM, playback clock and requests. Dispose before replacing the
/// host. The disposer is idempotent. Artifacts must share the viewer's origin.
@external(javascript, "./viewer_ffi.mjs", "mount")
pub fn mount(config: Config, selector: String) -> Result(fn() -> Nil, String)

/// HTTP routes matching retrace_server's example collector, with a ten-second
/// request deadline. Session search is bounded to the collector's first page.
@external(javascript, "./viewer_ffi.mjs", "collector")
pub fn collector(endpoint: String) -> Source

/// Resolve /<build>/manifest.json under a trusted same-origin directory.
/// Validates api, build and contract. Never substitutes the current build.
@external(javascript, "./viewer_ffi.mjs", "artifacts")
pub fn artifacts(directory: String) -> Resolver

/// Explicit mutable development override; all other builds use the resolver.
pub fn with_development(
  resolver: Resolver,
  build: String,
  contract: String,
  url: String,
) -> Resolver {
  fn(session: wire.Session) {
    case session.build == build && session.contract == contract {
      True -> fn(reply) {
        reply(Ok(Artifact(build, url, True)))
        fn() { Nil }
      }
      False -> resolver(session)
    }
  }
}
