#let terms = (
  (slug: "term-session", title: [Session], body: [One application's ordered recording, identified independently from its user's reference and fixed to an application build and replay contract.]),
  (slug: "term-entry", title: [Entry], body: [One accepted, safe application message with a sequence number and monotonic elapsed time inside a session.]),
  (slug: "term-checkpoint", title: [Checkpoint], body: [A replay-safe application model at a known session sequence and elapsed time.]),
  (slug: "term-recording-cursor", title: [Recording cursor], body: [The position of a recorder in a session, holding the next sequence number and the latest elapsed time.]),
  (slug: "term-batch", title: [Batch], body: [An immutable checkpoint followed by a bounded contiguous range of entries, used as the unit of upload, deduplication and replay pagination. Archival groups whole batches without changing their receipts or checkpoints.]),
  (slug: "term-acknowledgement", title: [Acknowledgement], body: [The server's confirmation that a batch is durably committed; it permits the client to remove that batch from its queue.

    _Avoid_: receipt — names the retained record in #ctx("archive"), not the confirmation returned to the client.]),
  (slug: "term-replay-contract", title: [Replay contract], body: [The application-owned compatibility identifier for its event schema, checkpoint schema and reducer semantics.]),
  (slug: "term-delivery-queue", title: [Delivery queue], body: [The client's bounded durable collection of saved batches awaiting acknowledgement.]),
  (slug: "term-task", title: [Task], body: [A cold callback operation that starts its work when invoked, replies once with a result, and returns a function that cancels its pending work.]),
)
