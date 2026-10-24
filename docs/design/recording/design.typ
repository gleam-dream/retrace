#import "../.render/designlib.typ": *
#let title = [Recording]
#let accent = "teal"
#let body = [
  #section(title: "Foundation", lead: "Recording owns the application-neutral session data and its path from capture to an acknowledged batch.", body: [
    #goal(title: "Reconstruct application state from recorded messages")[A developer can rebuild the state of an application at any recorded point from the messages and checkpoints the application chose to record.]
    #goal(title: "Deliver every saved batch until acknowledged")[A client saves a #term("term-batch") locally before uploading it, retries it after network failure or restart, and removes it only after its #term("term-acknowledgement").]
    #no-goal(title: "Automatic redaction")[Retrace does not infer which application state is safe to record. Debugger formatters cannot redact data already captured.]
    #invariant(title: "Invalid history never advances a player", enforcement: "mechanism")[A gap, duplicate position, foreign session or contract, backwards time, or failing reducer returns a typed failure and leaves the previous player usable.]
    #invariant(title: "Sequence and elapsed time never move backwards", enforcement: "mechanism")[A #term("term-recording-cursor") advances once per #term("term-entry"). Every sequence and elapsed-time integer fits the JavaScript exact-integer range.]
    #invariant(title: "A batch stays queued until its matching acknowledgement", enforcement: "mechanism")[Only an acknowledgement matching the batch session and final sequence removes the batch from the #term("term-delivery-queue"). A late reply from a cancelled upload cannot remove it.]
    #principle(title: "The application owns safe meaning", lens: "composition")[Applications select replay-safe messages, state projections, codecs, user references and #term("term-replay-contract") identifiers before capture. Reducer determinism and purity are application obligations that function types cannot prove.]
  ])
  #pending-ledger(
    pending-entry(title: "Native store and capture statements carried over from retired guides", kind: "verify", since: "2026-10-17")[
      The statements on Tauri native store durability, one writing window per queue and the capture failure paths come from retired guides. This review confirmed the batch limits, the five-second upload deadline, the fixed retry delay and the acknowledgement check, and not the native store behavior.
    ],
  )
  #section(title: "Session and recording cursor", lead: "Pure values retain application types and report invalid history without advancing a player.", body: [
    #behavior(title: "Invalid history preserves the replay cursor", level: "boundary", area: "Reconstruction")[
      #given[a player at a validated checkpoint]
      #when[an entry has a gap, duplicate position, different session or contract, backwards time, or a failing application reducer]
      #then[the operation returns the corresponding typed failure and the previous player remains usable]
    ]
    #behavior(title: "A checkpoint can restart reconstruction", level: "boundary", area: "Reconstruction")[
      #given[a compatible checkpoint and subsequent contiguous entries]
      #when[the caller reconstructs the recorded range]
      #then[the final state and absolute sequence can be inspected and compared with a supplied checkpoint]
    ]
    #points(
      [A #term("term-session") has an immutable ID, user reference, build, platform and #term("term-replay-contract"). Multiple devices or tabs use distinct session IDs. The user reference is searchable metadata and never authorization.],
      [A #term("term-recording-cursor") owns sequence and elapsed-time monotonicity. An #term("term-entry") advances it once, including a message that changes no state. A #term("term-checkpoint") starts reconstruction at its declared cursor.],
      [Start validates identity, record increments the sequence and returns an immutable entry, and resume validates a supplied cursor. The caller recovers its matching outbox and state before resuming.],
      [Compatibility checks prove neither reducer equivalence nor checkpoint authenticity. The application owns both claims.],
      [The portable core has no Lustre, Tauri, database or network dependency and runs on the Erlang and JavaScript targets. Application types stay application types, and JSON appears only at the wire boundary.],
    )
  ])
  #section(title: "Batch and wire format", lead: "A batch is the unit of upload, deduplication and replay pagination.", body: [
    #points(
      [A #term("term-batch") holds immutable session metadata, a checkpoint and 1–128 contiguous entries. Its encoded size is at most one MiB. Its checkpoint precedes its entries, and every origin matches its session.],
      [Application payloads travel as bounded JSON strings, so the collector imports no application types. JSON decoding does not prove the validity of the application's model or event.],
      [Transport format version and application replay compatibility are separate. Session IDs are unique per recording.],
      [An application may group up to 128 entries in one batch to reduce request and object counts. It supplies the checkpoint that precedes the group.],
    )
  ])
  #section(title: "Domain model", lead: "Recording owns five application-neutral values: the session, the recording cursor, the entry, the checkpoint and the batch.", body: [
    #subsection(title: "Recording domain")[
      #entity(
        title: "Session",
        description: [One application's ordered recording, fixed to an application build and replay contract.],
        kind: "entity",
        owner: "recording",
        lifecycle: "immutable",
        domain: "recording",
        tint: "teal",
      )[
        #attribute(name: "Identifier", type: "Session identifier", provenance: "authored")[the identifier that is unique per recording and independent of the user reference]
        #attribute(name: "User reference", type: "User reference", provenance: "authored")[searchable metadata that never authorizes access]
        #attribute(name: "Build identity", type: "Build identity", provenance: "authored")[the identity of the application build that recorded the session]
        #attribute(name: "Replay contract", type: "Replay contract identifier", provenance: "authored")[the application's compatibility identifier for its schemas and reducer semantics]
        #attribute(name: "Platform", type: "Platform name", provenance: "authored")[the platform that ran the application, such as web or Tauri]
        #relates(cardinality: "1 : n")[is carried by many *Batches*]
      ]
      #entity(
        title: "Recording cursor",
        description: [The position of a recorder in a session.],
        kind: "value-object",
        owner: "recording",
        lifecycle: "immutable",
        domain: "recording",
        tint: "teal",
      )[
        #attribute(name: "Next sequence", type: "Sequence number", provenance: "derived")[the sequence of the next entry, advanced once per entry]
        #attribute(name: "Latest elapsed time", type: "Elapsed time", provenance: "observed")[the latest clock reading, which never moves backwards]
      ]
      #entity(
        title: "Entry",
        description: [One accepted, safe application message inside a session.],
        kind: "event",
        owner: "recording",
        lifecycle: "immutable",
        domain: "recording",
        tint: "teal",
      )[
        #attribute(name: "Sequence", type: "Sequence number", provenance: "derived")[the position the recording cursor assigned]
        #attribute(name: "Elapsed time", type: "Elapsed time", provenance: "observed")[the monotonic clock reading when the application accepted the transition]
        #attribute(name: "Application event", type: "Encoded application event", provenance: "authored")[the message the application chose to record, encoded as a bounded JSON string]
        #relates(cardinality: "n : 1")[belongs to one *Batch*]
      ]
      #entity(
        title: "Checkpoint",
        description: [A replay-safe application model at a known session sequence and elapsed time.],
        kind: "value-object",
        owner: "recording",
        lifecycle: "immutable",
        domain: "recording",
        tint: "teal",
      )[
        #attribute(name: "Sequence", type: "Sequence number", provenance: "derived")[the session position the model describes]
        #attribute(name: "Elapsed time", type: "Elapsed time", provenance: "observed")[the clock reading at that position]
        #attribute(name: "Application model", type: "Encoded application model", provenance: "authored")[the safe projection of application state that starts reconstruction]
        #relates(cardinality: "1 : 1")[precedes the entries of one *Batch*]
      ]
      #entity(
        title: "Batch",
        description: [An immutable checkpoint followed by a bounded contiguous range of entries, the unit of upload, deduplication and replay pagination.],
        kind: "aggregate",
        owner: "recording",
        lifecycle: "immutable",
        domain: "recording",
        tint: "teal",
      )[
        #attribute(name: "Entry range", type: "Contiguous sequence range", provenance: "derived")[one to 128 entries whose sequences follow the checkpoint without gaps]
        #attribute(name: "Encoded size", type: "Byte count", provenance: "derived")[the size of the encoded batch, at most one MiB]
        #relates(cardinality: "n : 1")[belongs to one *Session*]
        #relates(cardinality: "1 : n")[holds many *Entries*]
      ]
    ]
  ])
  #section(title: "Client delivery", lead: "The client persists before uploading and removes a batch only after its matching acknowledgement.", body: [
    #behavior(title: "Interrupted delivery is recoverable", level: "boundary", area: "Delivery")[
      #given[a batch confirmed as saved locally]
      #when[the network fails or the client runtime restarts before acknowledgement]
      #then[the batch remains available for retry with the same session and sequence]
    ]
    #behavior(title: "Capture failure stays visible", level: "interface", area: "Capture")[
      #given[the local queue is full or its storage write fails]
      #when[the application attempts to record another transition]
      #then[capture reports its failure without claiming that transition was saved]
    ]
    #behavior(title: "Typed client adapters preserve operation ownership", level: "boundary", area: "Delivery")[
      #given[a client using application-supplied typed storage and upload operations]
      #when[an operation completes, fails or its pending upload is cancelled]
      #then[only its first completion is observed]
      #then[cancellation releases the upload and ignores late replies]
      #then[admitted storage work settles and borrowed resources remain caller-owned]
    ]
    #points(
      [The client reports local save and upload acknowledgement as separate statuses through the application callback. It owns retry timers and exposes shutdown. Retry delays are fixed, and a permanently rejected batch blocks later uploads in its queue.],
      [A client runtime has one writer and one sequential upload loop. Each page instance starts a fresh session and still drains durable batches left by earlier instances. Duplicate uploads from overlapping runtimes are safe on the server.],
      [Browser persistence defaults to IndexedDB. Tauri uses an explicitly selected native store adapter, and a browser-only build needs no Tauri plugin. Tauri assumes one writing window per queue and provides no cross-process locking.],
      [The #term("term-delivery-queue") caps pending capture and durable storage independently by item count and encoded bytes. Both caps together admit up to twice the encoded-payload budget plus metadata, encoding temporaries and storage-engine overhead. The caps are not a process heap limit.],
      [Admission reserves pending capacity synchronously, and overload stops further capture visibly. Already admitted writes complete unless persistence itself fails. A fresh application session starts after a capture gap.],
      [The upload deadline of five seconds covers headers and the acknowledgement body. Shutdown aborts the active request and cancels retries. Admitted saves still settle, and shutdown never closes a handle borrowed from custom storage.],
      [The runtime validates session and final sequence before deleting a batch. Cancellation cannot undo a server commit, so upload retries rely on idempotent admission.],
      [A live transition and its asynchronous local capture are separate commits, so abrupt termination before the save confirmation can lose that transition. Persisted batches survive a normal runtime restart. Device failure, storage eviction, mobile background execution and power loss are outside this guarantee, and native store durability means only that the plugin save completed.],
    )
    #subsection(title: "Typed adapters")[
      #points(
        [Typed adapter constructors accept cold #term("term-task") operations and an explicit formatter for application-native errors. Storage and transport policy are independent, and storage and transport may use different error types.],
        [A #term("term-task") starts its work when invoked, replies once with a result, and returns a function that cancels pending work. Deferring synchronous work wraps it without running it during adapter construction.],
        [The bridge observes only the first completion, turns provider throws into failures, and ignores late replies. It starts no scheduler or retry loop and takes no ownership of resources. #adr(7)],
        [Storage operations must settle, and their cancellation callbacks are never invoked because admitted writes and deletions finish after shutdown. The caller releases storage resources after those operations settle.],
        [A put must enforce durable item and UTF-8-byte limits atomically, accept identical retries, reject conflicting content, and reply only after saving. Multiple writers are coordinated by the storage implementation.],
        [Upload receives the exact encoded batch and returns the acknowledgement as encoded JSON, so byte identity is preserved and the application may interpret the batch with the wire module. A custom transport honors cancellation and rejects unsuccessful responses.],
        [Provider error types stay in application callbacks until the selected formatter produces string diagnostics. Authentication headers never enter recorded events.],
      )
      #md-table(2,
        ([*Operation*], [*Application supplies*],
         [Open store], [Opens a store for a queue carrying its name, item cap and byte cap],
         [Store listing], [Returns every saved row, each carrying an opaque queue key and an encoded batch body],
         [Store put], [Saves one row and replies after saving],
         [Store remove], [Removes one row by key],
         [Upload], [Sends the encoded batch and returns the acknowledgement JSON],
         [Error formatter], [Converts a provider error into a diagnostic string],
        ))
      #points(
        [Existing opaque JavaScript adapters remain valid. A foreign storage opens a store from a name and two caps and exposes asynchronous listing, put and remove. A foreign transport takes an encoded batch and an abort signal and returns the acknowledgement JSON.],
      )
    ]
  ])
  #section(title: "Capture coordination", lead: "The capture module records accepted transitions without taking over application update or effects.", body: [
    #behavior(title: "Capture coordination preserves application ownership", level: "boundary", area: "Capture composition")[
      #given[an initialized capture state and an application-approved transition]
      #when[the application observes that transition with its safe state and event codecs]
      #then[the adapter records its checkpoint and event in order]
      #then[persistence is reported separately]
      #then[a failure stops capture visibly]
      #then[the application's effects are neither executed nor suppressed]
    ]
    #points(
      [Capture coordinates the core recorder and client delivery through immutable state and Lustre effects. Starting returns the state and a connection effect, and the application maps capture messages into its own message type. Delivery messages are never observed recursively.],
      [Observation takes the state before an accepted transition, the message and the safe encoders. It never runs the application reducer or effects. The adapter emits one checkpoint and event batch per observation.],
      [Capture requires a prior connection. Observing before connection stops capture visibly instead of introducing a silent history gap. Invalid time and failed persistence also stop capture visibly, and the application stays usable.],
      [The caller owns the client lifetime and stops capture before discarding its state. Retry repairs delivery only and never repairs a failed recording. A fresh session starts after a capture failure.],
      [Capture information reports the session, captured count, locally saved count, delivery status and optional failure. A per-session monotonic clock and random session ID are supplied by default, and a clock can be injected for deterministic consumers.],
      [The results of effects, such as a native reply, are recorded as ordinary messages. Time and randomness values that affect state are recorded in events. Only transitions that cannot affect the replay model may be omitted, because an omitted meaningful transition makes later checkpoints inconsistent.],
    )
  ])
]
