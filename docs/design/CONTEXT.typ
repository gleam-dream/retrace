#let terms = (
  (slug: "term-session", title: [Session], body: [One application's ordered recording, identified independently from its user's reference and fixed to an application build and replay contract.]),
  (slug: "term-entry", title: [Entry], body: [One accepted, safe application message with a sequence number and monotonic elapsed time inside a session.]),
  (slug: "term-checkpoint", title: [Checkpoint], body: [A replay-safe application model at a known session sequence and elapsed time.]),
  (slug: "term-batch", title: [Batch], body: [An immutable checkpoint followed by a bounded contiguous range of entries, used as the unit of upload, deduplication and replay pagination. Archival groups whole batches without changing their receipts or checkpoints.]),
  (slug: "term-acknowledgement", title: [Acknowledgement], body: [The server's confirmation that a batch is durably committed; it permits the client to remove that batch from its queue.]),
  (slug: "term-replay-contract", title: [Replay contract], body: [The application-owned compatibility identifier for its event schema, checkpoint schema and reducer semantics.]),
  (slug: "term-replay-module", title: [Replay module], body: [Application-owned codecs, deterministic reducer and complete view used to reconstruct a recorded application state.]),
  (slug: "term-replay-artifact", title: [Replay artifact], body: [A compiled replay module with its document, styles and dependencies, identified by the application build that produced a recording.]),
  (slug: "term-replay-viewer", title: [Replay viewer], body: [The session-inspection interface that selects artifacts and controls playback time independently of the live application.]),
)
