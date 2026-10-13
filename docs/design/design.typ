#import ".render/designlib.typ": *
#let title = [Retrace]
#let accent = "teal"
#let body = [
  #section(title: "Foundation", lead: "Retrace records application messages, delivers durable sessions and reconstructs them for inspection.", body: [
    #goal(title: "Follow a session across capture, storage and replay")[A developer can reproduce an application state from a web or Tauri session, search recordings by user reference, and replay a recording after the collector restarts.]
    #goal(title: "Compose small runtime owners")[The portable recording core has no Lustre dependency. A client owns a local delivery queue. The server coordinates PostgreSQL and S3. The optional Lustre companion composes application-owned replay modules.]
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
      [Frontend: client modules], [Bounded durable queue, serialized delivery, retries], [Capture policy, endpoint, identity, storage selection],
      [Server package], [Atomic admission, session index, archival and retrieval], [Database pool, object-store configuration, worker lifetime],
      [Frontend: Lustre modules], [Capture coordination, typed reconstruction and inert frame], [Safe codecs, reducer, view and runtime lifetime],
      [Frontend: viewer module], [Default interface, playback clock and cancellable reads], [Source, artifact policy, host mount and cleanup],
      [Example applications], [Basic browser adoption and advanced native/custom-adapter composition], [Starting and stopping local resources],
    ))
    #points(
      [Three packages form the distribution boundary: portable retrace; JavaScript retrace_frontend, which depends on core and Lustre; and BEAM retrace_server, which depends on core and backend libraries. Frontend delivery, capture, replay and viewer modules retain separate configuration and cleanup. Importing the package starts no resources. Tauri plugin use remains explicit. Applications can replace adapters or supply their own viewer/backend. #adr(8)],
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
    #behavior(title: "Typed client adapters preserve operation ownership", level: "boundary", area: "Delivery")[
      #given[a client using application-supplied typed storage and upload operations]
      #when[an operation completes, fails or its pending upload is cancelled]
      #then[only its first completion is observed; cancellation releases the upload and ignores late replies, while admitted storage work settles and borrowed resources remain caller-owned]
    ]
    #points(
      [Typed adapter constructors accept cold Gleam callback operations and an explicit formatter for application-native errors. Storage receives the queue namespace and limits and supplies list, put and remove operations. Upload receives the exact encoded batch and returns the encoded receipt; the client retains receipt validation. The bridge handles synchronous completion, thrown provider errors, deadlines and late replies without adding retries or taking ownership of resources. Storage operations must settle; their cancellation callbacks are not invoked because admitted writes and deletions must finish. Default and foreign adapters remain available. No archive or build-metadata framework belongs to this module. #adr(7)],
      [A client runtime has one writer and one sequential upload loop. Each page instance starts a fresh session; it still drains durable batches left by earlier instances. Upload duplicates caused by overlapping runtimes are safe on the server.],
      [Browser persistence defaults to IndexedDB. Tauri uses an explicitly selected native store adapter. Callers can supply storage and an abortable upload transport; the runtime owns ordering and acknowledgement validation. The SDK returns explicit persistence and delivery status through the application's callback. It owns retry timers and exposes shutdown.],
      [Pending capture and durable storage each have independent item and encoded-byte caps. Admission reserves pending capacity synchronously; overload stops further capture visibly. Already admitted writes complete unless persistence itself fails. The upload deadline covers headers and acknowledgement body, and shutdown aborts that request. Custom storage must enforce atomic, idempotent writes and durable capacity limits; custom transports must honor cancellation. A live transition and asynchronous local capture are separate commits; an abrupt termination before save confirmation can lose that transition. Persisted batches survive a normal runtime restart; device failure, storage eviction and mobile background execution are outside this guarantee.],
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
      [The server package borrows a database pool and object-store functions. The development collector owns the pool and periodic archive worker. Storage functions have explicit read/write failures; no package starts hidden background workers.],
    )
  ])
  #section(title: "Lustre replay composition", lead: "An optional companion reconstructs bounded ranges using application-native types and a shared inert view.", body: [
    #behavior(title: "Application adapters preserve range identity", level: "boundary", area: "Replay composition")[
      #given[an application adapter, expected build and a bounded recorded range]
      #when[the range is reconstructed from its first checkpoint]
      #then[all envelopes, session metadata, checkpoints and transitions must agree before any snapshots are returned; failure leaves the caller free to retry a corrected range]
    ]
    #behavior(title: "Replay frames have an explicit lifetime", level: "boundary", area: "Replay composition")[
      #given[a mounted application replay frame]
      #when[the host disposes it]
      #then[its message listener and application runtime stop responding]
    ]
    #behavior(title: "Capture coordination preserves application ownership", level: "boundary", area: "Capture composition")[
      #given[an initialized capture state and an application-approved transition]
      #when[the application observes that transition with its safe state and event codecs]
      #then[the adapter records its checkpoint and event in order, reports persistence separately, and stops capture visibly on failure without executing or suppressing the application's effects]
    ]
    #behavior(title: "Viewer adapters own cancellable work", level: "boundary", area: "Viewer composition")[
      #given[a viewer using default or application-supplied typed readers]
      #when[a request is replaced or the viewer is disposed]
      #then[its pending reads are cancelled, stale replies cannot replace the current display, and disposal can be repeated safely]
    ]
    #points(
      [The optional capture module owns recorder coordination and persistence feedback as immutable state and Lustre effects. Applications map its messages into their update function and observe accepted transitions; delivery messages are never recorded recursively. A per-session monotonic clock and random session ID are supplied, with explicit clock injection for deterministic consumers. Capture stops visibly if observed before connection, on invalid time, or on failed persistence; the application remains usable. The caller owns the client lifetime and invokes stop when its application unmounts.],
      [Viewport observations expose typed CSS dimensions and safe-area insets. Applications translate these values into their own recorded message schema.],
      [The experimental retrace_frontend/replay module owns a typed replay-module adapter, bounded reconstruction and an inert frame. Applications supply codecs, deterministic reduction, equality, event labels, presentation projection and the complete view used live. Reconstruction retains typed application errors; the frame renders diagnostic text.],
      [Ranges may begin at a nonzero checkpoint. Snapshot and seek identifiers are absolute sequence numbers; offsets remain internal. The default viewer uses a caller-supplied range reader with an after cursor and bounded page size, validates progress and refuses beyond its retained-entry budget. The host owns storage, authorization and artifact selection.],
      [Applications project a fixed desktop viewport or record resize observations in their own events. An optional browser helper observes CSS dimensions and safe areas inside browsers or Tauri WebViews and returns cleanup. Presentation never enters the portable recording core.],
      [The basic inventory consumer uses provided browser persistence, HTTP delivery and viewer readers without application-authored FFI. The advanced membership consumer combines Tauri, native results and an optional custom local archive with its own storage, transport and typed viewer source. Both import public package APIs and retain their own application types. Exactly these two examples are maintained; the shared collector belongs to development tooling and backend fault consumers remain isolated test harnesses. #adr(6) The companion and viewer remain experimental bounded replay, without live subscription or an unbounded cache. #adr(3)],
    )
  ])
  #section(title: "Example application and viewer", lead: "A small membership app demonstrates the same session contract in the browser and Tauri.", body: [
    #behavior(title: "Playback preserves recorded timing", level: "interface", area: "Replay")[
      #given[a complete validated recording range]
      #when[a developer plays or seeks within it]
      #then[the playhead follows elapsed time, preserves gaps and displays the last state at or before that time; equal-time entries retain sequence order and appear together; previous and next navigation move between distinct timestamps]
    ]
    #behavior(title: "Replay preserves the application viewport", level: "interface", area: "Replay")[
      #given[a recording with application presentation state]
      #when[a developer inspects a point in time]
      #then[the complete application view uses the recorded viewport and screen, scaled to fit without changing its responsive layout]
    ]
    #behavior(title: "Unavailable artifacts refuse playback", level: "interface", area: "Replay")[
      #given[a session whose matching replay artifact is missing or incompatible]
      #when[a developer opens it]
      #then[the viewer explains the failure and does not substitute the current application build]
    ]
    #behavior(title: "Replay is inert", level: "interface", area: "Replay")[
      #given[a compatible stored recording]
      #when[the viewer navigates its entries]
      #then[the application state is reconstructed without making native requests or recording new live events]
    ]
    #points(
      [The live application and viewer have separate entrypoints and local endpoints. The #term("term-replay-viewer") owns search, artifact loading, timing and event navigation. The live application owns capture and effect execution. Capture diagnostics remain available as a separate live-only panel.],
      [A #term("term-replay-module") supplies the full view used by live and recorded states. A native platform-information request demonstrates a genuine Tauri command and records its result as an application message. The browser has its own labelled result. Native operating-system UI is represented by events, not a pixel recording.],
      [An application-owned #term("term-replay-artifact") checks its build and contract, validates all checkpoints and entries, and renders the same root view as the live application. The example host embeds trusted local artifacts in an iframe using a versioned, source-checked message protocol. It accepts validated checkpoint ranges and bounds retained snapshots. Time Travel is not a runtime dependency; retained attribution records the original derivation. #adr(5)],
      [The application records CSS viewport dimensions, safe-area insets and screen navigation in its own model and messages. The wire format remains unchanged. Replay stops at the last observed event and labels this as a loaded range, not a known session end. The viewer pauses when hidden. Native sheets, keyboard pixels, arbitrary scrolling and autonomous animation are outside this example's fidelity claim.],
      [The optional retrace_frontend/viewer module owns the default playback interface and typed cancellable source and artifact adapters. Its collector and artifact-directory defaults require no application-authored JavaScript. Applications can replace storage reads and artifact policy from Gleam, and customize the supplied stylesheet. These interfaces remain experimental. #adr(5)],
      [The local collector binds to loopback by default. Local example routes are unauthenticated and must not be treated as a hosted service configuration.],
    )
  ])
]
