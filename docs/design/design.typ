#import ".render/designlib.typ": *
#let title = [Retrace]
#let accent = "teal"
#let body = [
  #section(title: "Foundation", lead: "Retrace records application messages, delivers durable sessions and reconstructs them for inspection.", body: [
    #goal(title: "Follow a session across capture, storage and replay")[A developer can reproduce an application state from a web or Tauri session, search recordings by user reference, and replay a recording after the collector restarts.]
    #goal(title: "Distribute three packages from one Git revision")[The portable core, the JavaScript frontend and the BEAM server install from one repository and share one revision.]
    #no-goal(title: "Universal screen recording")[Retrace reconstructs explicitly recorded application state. It does not capture pixels, operating-system dialogs, arbitrary DOM mutations or native screens.]
    #no-goal(title: "A hosted deployment policy")[Deployment authentication, tenant isolation, retention schedules and consent policy are application and host decisions, and the examples are local development hosts.]
    #invariant(title: "Acknowledgement follows durable commit", enforcement: "partial")[An #term("term-acknowledgement") means PostgreSQL committed the immutable #term("term-batch"). An object-store failure cannot erase that accepted copy.]
    #principle(title: "Compose small runtime owners", lens: "composition")[The portable core has no Lustre dependency. A client owns a local delivery queue, the server coordinates PostgreSQL and S3, and the optional Lustre companion composes application-owned replay modules. Importing a package starts no resource.]
  ])
  #pending-ledger(
    pending-entry(title: "Hosted deployment policy", kind: "ruling", since: "2026-10-10")[
      Authentication, tenant isolation, rate limiting, consent and retention schedules need an owner decision before a hosted deployment. The collector is loopback-only and unauthenticated.
    ],
    pending-entry(title: "Replay beyond a bounded range", kind: "ruling", since: "2026-10-10")[
      Live tailing, lazy seeking from checkpoints, event-payload search and analytics are not designed. The viewer retains a bounded range of snapshots.
    ],
    pending-entry(title: "Artifact integrity and registry", kind: "ruling", since: "2026-10-11")[
      Artifact digest verification, signing and an atomic manifest registry are recommendations only. The maintained build recipe records provenance and verifies no content.
    ],
    pending-entry(title: "Client retry and rejected-batch policy", kind: "ruling", since: "2026-10-10")[
      The client retries on fixed delays and a permanently rejected batch blocks its queue. A quarantine and backoff policy needs an owner decision.
    ],
    pending-entry(title: "Evidence runs carried over from retired guides", kind: "verify", since: "2026-10-17")[
      The statements on the native desktop check, the Simulator scenario and the physical-phone path describe runs that this review did not repeat. It confirmed only that the retained check files exist.
    ],
  )
  #section(title: "System at a glance", lead: "Three contexts divide the session path: recording owns the data, archive owns durable storage, replay owns inspection.", visual: diagram(
    altitude: "L2", viewpoint: "context-ownership", title: "Contexts of Retrace",
    nodes: (
      (id: "app", label: "Application", sub: "types, codecs, reducer, view", kind: "external-system", tint: "slate"),
      (id: "recording", label: "Recording", sub: "sessions, batches, client delivery", kind: "bounded-context", tint: "teal"),
      (id: "archive", label: "Archive", sub: "admission, archival, erasure", kind: "bounded-context", tint: "blue"),
      (id: "replay", label: "Replay", sub: "reconstruction, viewer, build identity", kind: "bounded-context", tint: "amber"),
      (id: "host", label: "Host", sub: "database, object store, workers", kind: "external-system", tint: "slate"),
    ),
    edges: (
      (from: "app", to: "recording", relation: "dataflow", label: "safe messages and checkpoints"),
      (from: "recording", to: "archive", relation: "dataflow", label: "batches and acknowledgements"),
      (from: "archive", to: "replay", relation: "dataflow", label: "verified batch pages"),
      (from: "app", to: "replay", relation: "dependency", label: "replay module and artifact"),
      (from: "host", to: "archive", relation: "dependency", label: "pool, store, worker lifetime"),
    ), caption: [Each context owns its vocabulary. The application and the host supply their own types and resources through explicit values.],
  ), body: [
    #md-table(3,
      ([*Unit*], [*Owns*], [*Caller owns*],
       [Portable package], [Recording cursor, reconstruction, envelope validation], [Types, codecs, clock, deterministic reducer],
       [Frontend client modules], [Bounded durable queue, serialized delivery, retries], [Capture policy, endpoint, identity, storage selection],
       [Server package], [Atomic admission, session index, archival and retrieval], [Database pool, object-store configuration, worker lifetime],
       [Frontend Lustre modules], [Capture coordination, typed reconstruction, inert frame], [Safe codecs, reducer, view, runtime lifetime],
       [Frontend viewer module], [Default interface, playback clock, cancellable reads], [Source, artifact policy, host mount and cleanup],
       [Example applications], [Basic browser adoption and advanced native composition], [Starting and stopping local resources],
      ))
    #points(
      [#ctx("recording") owns the session data model, the wire format, client delivery and capture. It is the upstream context, and #ctx("archive") and #ctx("replay") conform to its terms.],
      [#ctx("archive") owns admission, indexing, object archival, retrieval and erasure on the server. It supplies verified batch pages to #ctx("replay") through a source the viewer calls.],
      [#ctx("replay") owns reconstruction, the viewer, replay artifacts and build identity. It never executes application effects.],
      [Three packages form the distribution boundary: the portable package, the JavaScript frontend that depends on the core and Lustre, and the BEAM server that depends on the core and backend libraries. Frontend delivery, capture, replay and viewer modules keep separate configuration and cleanup, and applications may replace adapters or supply their own viewer or backend. #adr(8)],
      [The root package has no Lustre, Tauri, database or network import. The examples use PostgreSQL 16, a caller-configured S3-compatible service, Mist on BEAM and a shared Lustre frontend for browser and Tauri, with Nix supplying the development tools. #adr(1)],
    )
  ])
  #section(title: "Distribution and verification", lead: "Retrace installs from Git, and each kind of evidence is reported separately.", body: [
    #points(
      [Retrace is distributed as source from its Git repository and is not published to Hex. The three packages share one repository revision and version, and every Retrace dependency of an application pins the same tag or full commit SHA. The packages are experimental, so an application pins a revision and reviews changes before upgrading.],
      [An application declares only the packages it imports: the portable core with the frontend for a Lustre browser or Tauri application, and the core with the server for a backend. The core runs on the Erlang and JavaScript targets, the frontend targets JavaScript and the server targets Erlang. Libraries the application imports directly, such as Lustre, remain its own dependencies.],
      [The repository gate tests both core targets, builds every consumer and both examples, and runs the frontend and artifact tests. A separate consumer gate creates temporary projects outside the repository and runs core reconstruction on both targets, frontend adapter construction on JavaScript and server object-store composition on Erlang. It uses the committed revision, and it exercises no browser, native shell, database or cloud service.],
      [Usage is shown as compiled, runnable examples, never as a prose guide. Every usage topic has a check that fails when the library's API or behavior moves. #adr(17) The #lnk("../../examples/README.md")[usage topics] list each topic with its source and check.],
      [The adoption walk-through records an application's accepted transitions, delivers them and replays the delivered batches to the same state. Custom storage, upload and viewer source run against an in-memory stand-in for browser storage.],
      [The build recipe runs into scratch locations. It shows one build identity in the live and replay bundles, source provenance in the manifest and refusal to overwrite a published build.],
      [Required validation consists of standard formatting, compilation and behavioral unit and integration tests. Formatting runs through Nix/treefmt, and design validation imports the pinned shared design-layer checker. README equality, repository conventions and local checker self-tests are not gates. Runnable examples remain tested. #adr(19)],
      [Native builds, browser tests, database tests and remote-cloud tests are distinct evidence classes, and a compile is no native deployment test. Browser checks keep screenshots in ignored output and create disposable sessions in the development backend. A real PostgreSQL check signs local S3 requests, and an isolated database check injects archive failures and recovery.],
      [Simulator evidence is separate from browser evidence. The retained Simulator scenario drives the embedded Tauri build with native UI input, uploads through the native queue to the loopback collector, and replays that stored session in a desktop browser. It supports no claim about physical devices, background delivery or power-loss durability.],
      [A native desktop smoke check drives the real WebView, native store plugin, Rust command and upload with supplied render frames, because a hidden automation WebView pauses animation frames. It is excluded from ordinary builds and says nothing about mobile lifecycle or signing.],
      [A physical phone reaches a collector only through an endpoint compiled into its frontend, and the loopback default points at the phone itself. The mobile network policy and content security policy must permit that endpoint, and any bridge to the development collector needs an explicit access policy because the collector has no authentication. The session ID found and replayed on a desktop browser is the only confirmation that a phone uploaded a session.],
      [A release is published as an experimental prerelease from a checked commit with fixed tags, and Hex publication is a separate decision. Remote Git installs are verified from independent consumers after a push. #adr(11)],
      [Evidence limits stay explicit. The local object store test is no cloud deployment or power-failure test, and a successful build or installation establishes no phone upload. #adr(12)],
    )
  ])
  #section(title: "End-to-end walkthrough", lead: "A recorded transition travels from the application to an archived object and back into a replayed view.", visual: sequence(
    title: "Record, archive and replay one transition",
    participants: ((id: "app", label: "Application", shape: "participant"), (id: "client", label: "Client queue", shape: "control"), (id: "server", label: "Server", shape: "control"), (id: "store", label: "Object store", shape: "database"), (id: "viewer", label: "Viewer", shape: "boundary")),
    steps: (
      seq-msg("app", "client", "safe message and checkpoint"),
      seq-msg("client", "client", "save batch locally"),
      seq-msg("client", "server", "upload encoded batch"),
      seq-msg("server", "client", "acknowledgement after commit", dashed: true),
      seq-msg("server", "store", "archive after inactivity"),
      seq-msg("viewer", "server", "search sessions, read pages"),
      seq-msg("server", "viewer", "verified batches", dashed: true),
      seq-msg("viewer", "viewer", "reconstruct inert frame"),
    ),
    caption: [The client removes its copy only after the acknowledgement. Archival never reduces the committed copy, and replay performs no application effect.],
  ), body: [
    #points(
      [The application observes an accepted transition and the capture module records its checkpoint and entry as a #term("term-batch") in the #term("term-delivery-queue"). The queue saves it locally, uploads it, and removes it when the matching #term("term-acknowledgement") arrives.],
      [The server commits the batch, archives it after inactivity into an #term("term-archive-generation"), and serves it again as verified pages. The viewer selects the #term("term-replay-artifact") named by the session's #term("term-build-identity") and replays the pages in original time.],
    )
  ])
]
