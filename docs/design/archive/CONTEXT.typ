#let terms = (
  (slug: "term-batch-receipt", title: [Batch receipt], body: [The durable record of an admitted batch that retains its session, starting sequence, range and digest after the database payload is removed.

    _Avoid_: acknowledgement — names the confirmation returned to the client, not the retained record.]),
  (slug: "term-archive-segment", title: [Archive segment], body: [A group of whole original batches totalling at most 1000 entries that one archive object holds.]),
  (slug: "term-archive-generation", title: [Archive generation], body: [One immutable archive object for a segment, passing from planned to current to retired and never returning to current.]),
  (slug: "term-archive-plan", title: [Archive plan], body: [The durable record of a generation's object key, digest and complete payload, committed before any remote upload.]),
  (slug: "term-object-store", title: [Object store], body: [The caller-supplied pair of put and get functions that place and fetch archive bytes in remote storage.]),
  (slug: "term-deletion-fence", title: [Deletion fence], body: [The atomic commit that refuses admission, archival, search and reads for a session and inventories every object key of that session for erasure.]),
  (slug: "term-admission-cursor", title: [Admission cursor], body: [The highest sequence a session has durably committed. The checkpoint of the next admitted batch must equal it.

    _Avoid_: durable cursor — does not say whose position it is; recording cursor — names the recorder's position in #ctx("recording"), not the server's committed position.]),
  (slug: "term-tombstone", title: [Tombstone], body: [The retained record that a session was fenced for erasure, held with the session's object keys so that repeated erasure can delete late-written objects without making the session readable.]),
  (slug: "term-collector", title: [Collector], body: [A host that serves batch submission, session listing and batch paging to the packaged client and viewer. The development collector owns a database pool and an archive worker and serves the examples.]),
)
