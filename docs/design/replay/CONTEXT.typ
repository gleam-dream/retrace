#let terms = (
  (slug: "term-replay-module", title: [Replay module], body: [Application-owned codecs, deterministic reducer and complete view used to reconstruct a recorded application state.]),
  (slug: "term-replay-frame", title: [Replay frame], body: [The inert rendering of a replay module's full view inside an iframe document, driven only by loaded batches and seek commands.]),
  (slug: "term-replay-artifact", title: [Replay artifact], body: [A compiled replay module with its document, styles and dependencies, identified by the application build that produced a recording.]),
  (slug: "term-replay-viewer", title: [Replay viewer], body: [The session-inspection interface that selects artifacts and controls playback time independently of the live application.]),
  (slug: "term-build-identity", title: [Build identity], body: [The unique identifier of one application build, written into every session it records and used to select that build's replay artifact.

    _Avoid_: version — implies a release number, while a build identity distinguishes builds of one revision.]),
  (slug: "term-progressive-window", title: [Progressive window], body: [A group of whole original batches that the progressive viewer publishes to the frame as one update.]),
)
