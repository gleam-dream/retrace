#import ".render/designlib.typ": *
#let title = [Retrace]
#let accent = "teal"
#let body = [
  #section(title: "Foundation", lead: "Retrace records application messages, delivers durable sessions and reconstructs them for inspection.", body: [
    #goal(title: "Follow a session across capture, storage and replay")[A developer can reproduce an application state from a web or Tauri session, search recordings by user reference, and replay a recording after the collector restarts.]
    #goal(title: "Compose small runtime owners")[The portable recording core has no Lustre dependency. A client owns a local delivery queue. The server coordinates PostgreSQL and S3. The example viewer optionally composes Time Travel.]
    #no-goal(title: "Universal screen recording")[The initial release reconstructs explicitly recorded application state. It does not capture pixels, operating-system dialogs, arbitrary DOM mutations or native screens.]
    #invariant(title: "Playback does not execute application effects", enforcement: "convention")[The viewer uses an application-supplied pure reducer and inert view. HTTP, native calls and other effects remain in the live application. Function types alone cannot prove purity.]
    #invariant(title: "Acknowledgement follows durable commit", enforcement: "partial")[A #term("term-acknowledgement") means PostgreSQL committed the immutable #term("term-batch"). S3 failure cannot erase that accepted copy.]
    #principle(title: "The application owns safe meaning", lens: "composition")[Applications select replay-safe messages, state projections, codecs, user references and #term("term-replay-contract") identifiers before capture. Formatters do not establish redaction.]
    This initial system is a local development example with explicit runtime owners. Deployment authentication, tenant isolation, retention and erasure require separate policy before a hosted deployment. #adr(1)
  ])
  #section(title: "System and ownership", lead: "The application, client queue, collector and viewer cooperate through explicit values and durable receipts.", body: [
    #md-table(3, (
      [*Unit*], [*Owns*], [*Caller owns*],
      [Portable package], [Recording cursor, reconstruction, envelope validation], [Types, codecs, clock, deterministic reducer],
      [Client SDK], [Bounded durable queue, serialized delivery, retries], [Capture policy, endpoint, identity, storage selection],
      [Server package], [Atomic admission, session index, archival and retrieval], [Database pool, object-store configuration, worker lifetime],
      [Example applications], [Mist routes, Lustre interface, Tauri shell and viewer], [Starting and stopping local resources],
    ))
    #points(
      [A #term("term-session") has an immutable ID, user reference, build, platform and replay contract. Multiple devices or tabs use distinct IDs. User reference is searchable metadata, not authorization.],
      [A recording cursor owns sequence and elapsed-time monotonicity. A #term("term-entry") advances it once, including a message that changes no state. A #term("term-checkpoint") starts reconstruction at its declared cursor.],
      [Transport format version and application replay compatibility are separate. The initial transport uses bounded JSON strings for application payloads so the collector need not import application types.],
      [The example uses PostgreSQL 16, a caller-configured S3-compatible service, Mist on BEAM, and a shared Lustre frontend for browser and Tauri. Nix supplies the development tools.],
    )
  ])
  #section(title: "Recording and replay", lead: "Pure values retain application types and report invalid history without advancing a player.", body: [
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
      [Start validates identity. Record increments sequence and returns an immutable entry. Resume validates a supplied cursor; the caller must first recover its matching outbox and state. All sequence and elapsed-time integers fit the JavaScript exact-integer range.],
      [A batch contains at most 128 entries and at most one MiB of encoded bytes. Its checkpoint precedes its entries; all origins match its session. A batch is nonempty. JSON decoding does not prove the application's model or event validity.],
      [Compatibility checks do not prove reducer equivalence or authenticate a checkpoint. The application owns those claims.],
    )
  ])
  #section(title: "Client delivery", lead: "The client persists before uploading and removes a batch only after its matching durable receipt.", body: [
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
    #points(
      [A client runtime has one writer and one sequential upload loop. Each page instance starts a fresh session; it still drains durable batches left by earlier instances. Upload duplicates caused by overlapping runtimes are safe on the server.],
      [Browser persistence uses IndexedDB. Tauri persistence uses its native store plugin. The SDK returns explicit persistence and delivery status through the application's callback. It owns retry timers and exposes shutdown.],
      [The initial SDK caps its queue by item count and bytes. A live transition and asynchronous local capture are separate commits; an abrupt termination before save confirmation can lose that transition. Persisted batches survive a normal runtime restart; device failure, storage eviction and mobile background execution are outside this guarantee.],
    )
  ])
  #section(title: "Ingestion and archival", lead: "The server serializes admission per session and moves accepted recording bytes to object storage without a loss window.", body: [
    #behavior(title: "Duplicates are distinguished from conflicts", level: "boundary", area: "Admission")[
      #given[a batch was durably accepted]
      #when[a caller retries its range]
      #then[identical content returns the same acknowledgement and different content is refused]
    ]
    #behavior(title: "Session admission is ordered and atomic", level: "boundary", area: "Admission")[
      #given[a session's durable cursor]
      #when[a new batch is admitted]
      #then[its checkpoint must match that cursor and its fixed session metadata must agree before the batch and index advance together]
    ]
    #behavior(title: "Archival failure preserves accepted data", level: "boundary", area: "Archival")[
      #given[a committed batch still held in the database]
      #when[object upload fails]
      #then[the database copy remains readable and eligible for a later retry]
    ]
    #behavior(title: "Archived sessions remain replayable", level: "boundary", area: "Retrieval")[
      #given[a batch was successfully archived]
      #when[the collector restarts and the viewer requests that session]
      #then[the session remains searchable and its recording is fetched and checked before playback]
    ]
    #points(
      [Database states are pending, with payload and digest, and archived, with object key and digest. Upload precedes committing the archived state. A crash before that commit can leave an orphan object; the deterministic key makes retry safe. Failed upload never clears the database payload.],
      [Admission locks the session row. The initial checkpoint starts at sequence zero. A previously accepted batch is identified by session and starting sequence; its digest permits exact retry checks after its database payload has been removed. Different chunking is a conflict, not automatic deduplication.],
      [Session search is bounded and supports a user reference. Range retrieval is ordered and bounded. The object adapter returns compressed bytes; reconstruction verifies the stored content digest after decompression.],
      [The server package borrows a database pool and object-store functions. The example owns the pool and periodic archive worker. Storage functions have explicit read/write failures; no package starts hidden background workers.],
    )
  ])
  #section(title: "Example application and viewer", lead: "A small membership app demonstrates the same session contract in the browser and Tauri.", body: [
    #behavior(title: "Inspection leaves live capture running", level: "interface", area: "Replay")[
      #given[a developer is viewing an earlier replay state]
      #when[a live application effect completes]
      #then[the live application records the result while the selected replay remains unchanged]
    ]
    #behavior(title: "Replay is inert", level: "interface", area: "Replay")[
      #given[a compatible stored recording]
      #when[the viewer navigates its entries]
      #then[the application state is reconstructed without making native requests or recording new live events]
    ]
    #points(
      [The frontend separates live application state, capture state and viewer state. It exposes session/user identity, queued versus acknowledged progress, session search, selection and playback.],
      [A native platform-information request demonstrates a genuine Tauri command and records its result as an application message. The browser has its own labelled result. Native operating-system UI is represented by events, not a pixel recording.],
      [The viewer accepts only its supported replay contract and build. It loads stored ranges, decodes application payloads, reconstructs with the pure reducer and feeds inert snapshots to the Time Travel inspector.],
      [The local collector binds to loopback by default. Local example routes are unauthenticated and must not be treated as a hosted service configuration.],
    )
  ])
]
