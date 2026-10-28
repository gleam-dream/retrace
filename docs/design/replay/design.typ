#import "../.render/designlib.typ": *
#let title = [Replay]
#let accent = "amber"
#let body = [
  #section(title: "Foundation", lead: "Replay owns reconstruction of recorded ranges, the viewer, replay artifacts and build identity.", body: [
    #goal(title: "Inspect a recorded session with the application's own view")[A developer can search sessions by user reference, play or seek a bounded recorded range in original time, and see the complete application view with its recorded viewport.]
    #goal(title: "Pair every recording with the build that produced it")[A #term("term-build-identity") carried by the session selects the preserved #term("term-replay-artifact") that renders it.]
    #no-goal(title: "Native operating-system pixel fidelity")[Replay reconstructs explicitly recorded application state. Operating-system sheets, keyboard pixels, arbitrary DOM mutations, scroll positions, theme or locale changes and autonomous animations are not replayed.]
    #invariant(title: "Playback does not execute application effects", enforcement: "convention")[The viewer uses an application-supplied pure reducer and an inert view. HTTP, native calls and other effects stay in the live application, and function types alone cannot prove purity.]
    #invariant(title: "A recording replays only against its own build", enforcement: "mechanism")[A missing or incompatible artifact refuses playback with an explanation. The viewer never substitutes the current application build.]
    #invariant(title: "An isolated frame accepts only exact authority", enforcement: "mechanism")[An isolated replay frame accepts a message only from the expected window, the exact configured origin, the protocol version and the per-frame nonce.]
    #principle(title: "Keep viewer, artifact and application as separate owners", lens: "composition")[The viewer owns session navigation, playback time and artifact selection. The application owns codecs, reduction, the view and presentation projection, and the host owns storage, authorization and artifact policy.]
  ])
  #pending-ledger(
    pending-entry(title: "Playback and example statements carried over from retired guides", kind: "verify", since: "2026-10-17")[
      The statements on playback timing, viewport scaling and the two example applications come from retired guides. This review confirmed the viewer budgets, the frame channel rules and the build identity recipe, and not playback timing or viewport scaling.
    ],
  )
  #section(title: "Replay modules and frames", lead: "An optional companion reconstructs bounded ranges using application-native types and a shared inert view.", body: [
    #behavior(title: "Protected observations preserve recorded decisions", level: "boundary", area: "Replay composition")[
      #given[a protected recording whose application codecs validate its observations]
      #when[the range is loaded or sought]
      #then[the shared application view receives the recorded decisions without validating placeholder text or invoking live commands]
      #then[malformed observations refuse the range without exposing partially reconstructed snapshots]
    ]
    #behavior(title: "Application adapters preserve range identity", level: "boundary", area: "Replay composition")[
      #given[an application adapter, expected build and a bounded recorded range]
      #when[the range is reconstructed from its first checkpoint]
      #then[all envelopes, session metadata, checkpoints and transitions must agree before any snapshots are returned]
      #then[a failure leaves the caller free to retry a corrected range]
    ]
    #behavior(title: "Replay frames have an explicit lifetime", level: "boundary", area: "Replay composition")[
      #given[a mounted application replay frame]
      #when[the host disposes it]
      #then[its message listener and application runtime stop responding]
    ]
    #behavior(title: "Isolated replay channels require exact authority", level: "boundary", area: "Replay composition")[
      #given[an explicitly isolated replay frame using a verified application build]
      #when[the viewer or frame receives a protocol message]
      #then[it accepts only the expected window, exact configured origin, protocol version and per-frame nonce]
      #then[the frame never infers parent authority from a message, referrer or recording]
    ]
    #points(
      [Replay owns no stored entity. #ctx("recording") owns the session, batch and checkpoint, #ctx("archive") owns the batch receipt, and the application pipeline owns the artifact manifest.],
      [A #term("term-replay-module") is typed by model, message and error. The application supplies its codecs, deterministic reducer, equality, full view, viewport projection and event labels, and the live application and the replay entrypoint share the same view.],
      [Two strategies use this unchanged contract. Deterministic replay shares a pure reducer and records external results as messages. Protected observation replay records accepted decisions and adopts each validated observation as the next replay state. Both feed the same view used live; neither executes the live effect interpreter.],
      [Replacing private text before rerunning business validation can change a decision: a one-character input fails a minimum-length rule while a longer protected placeholder passes it. An observation instead records the original invalid decision and field presence. Its decoder validates the observation schema and invariants, never the placeholder as business input.],
      [The application owns the observation vocabulary, presence policy, codecs, consistency rules and conversion into the shared view's input. Retrace supplies capture, range validation, inert mounting and exact build matching. Excluded text, its geometry, unrecorded decisions and external state cannot be reconstructed. Function types and inert DOM do not prevent effects hidden inside application callbacks; artifacts must omit live capabilities and use the host's isolation policy.],
      [Reconstruction validates the complete supplied range before returning snapshots. A range may begin at a nonzero checkpoint, and sequence numbers stay absolute. Every batch checkpoint is verified with the application's equality function.],
      [Typed reducer errors surface as invalid-replay failures, and decoding or compatibility failures surface as invalid-range failures. A failed call holds no mutable state, so the caller retries with corrected input.],
      [The #term("term-replay-frame") renders the application's full view inertly and ignores its messages. Cleanup removes the frame subscription and the node it owns, is idempotent, and does not rely on the Lustre single-page shutdown branch. One frame runtime serves one iframe document.],
      [An application with a fixed viewport projects a constant viewport. An application with changing dimensions reads or observes typed viewport values (width, height, top and bottom safe-area insets) and translates them into its own event schema. Presentation fields never enter the portable core.],
      [The viewport helper observes CSS dimensions and vertical safe areas inside browsers and Tauri WebViews and returns its cleanup. It records no operating-system sheets, keyboard pixels or arbitrary scrolling.],
    )
  ])
  #section(title: "Viewer", lead: "The viewer is the default session-inspection interface with replaceable sources and artifact resolution.", body: [
    #behavior(title: "Viewer adapters own cancellable work", level: "boundary", area: "Viewer composition")[
      #given[a viewer using default or application-supplied typed readers]
      #when[a request is replaced or the viewer is disposed]
      #then[its pending reads are cancelled]
      #then[stale replies cannot replace the current display]
      #then[disposal can be repeated safely]
    ]
    #behavior(title: "Progressive replay exposes a usable prefix", level: "interface", area: "Viewer composition")[
      #given[a viewer configured for progressive loading of a bounded recording]
      #when[the first valid range is available and later ranges are still loading]
      #then[the developer can inspect the loaded interval]
      #then[subsequent ranges extend the same timeline without moving the playhead]
      #then[a later retrieval failure keeps the valid prefix available with an explicit retry]
    ]
    #behavior(title: "Progressive ranges preserve bounded evidence", level: "boundary", area: "Viewer composition")[
      #given[a progressive reader at an accepted checkpoint]
      #when[a later page changes session identity, skips an entry, reverses time or exceeds its configured budgets]
      #then[the page is refused without advancing the accepted cursor]
      #then[a corrected retry starts from that cursor]
      #then[cancellation cannot commit late data]
    ]
    #points(
      [The viewer module owns its DOM, scoped styles, playback clock, frame protocol and pending read lifetimes. It imports no Lustre and needs no Tauri plugin or database. Its containing frontend package depends on Lustre.],
      [A page mounts one viewer, which owns the session and time URL parameters. Mounting refuses an invalid selector and a nonpositive entry budget. The host supplies the element, body margin and surrounding layout, and disposal is idempotent.],
      [A source supplies session listing by user and ranged reads by id, cursor after and limit. A resolver maps a session to an artifact carrying build, URL and a development flag. Each returns a #term("term-task"), so selection, repeated search and disposal cancel obsolete work and late replies are ignored.],
      [A page of batches carries encoded wire strings, and its next cursor is the last sequence when more pages remain. Absolute sequences must advance. A loaded range is validated before display, and a nonzero starting cursor requires its first checkpoint to equal that cursor.],
      [The default collector reader requests at most 128 batches per read, lists at most the latest 100 sessions, and applies a ten-second deadline. The default artifact resolver checks the manifest api, build and contract. A development override supplies a mutable build and contract without a fallback for other builds.],
      [The viewer retains at most 5,000 entries by default and refuses beyond its configured budget. Only trusted same-origin artifacts are supported in default mode. Authentication and hiding protected data belong to the host.],
      [Playback preserves recorded gaps and ends at the last loaded event, and its range caption states that the session end is unknown. Speed changes affect subsequent elapsed time, hiding the viewer pauses it, and a link carrying session and time in milliseconds reopens the same point.],
      [Loading more recorded events requests the events captured since the previous load. The viewer shows dense markers in clusters and keeps every entry in its event list. A fully different interface reuses the reconstruction, description and mount functions of the companion, because the packaged shell exposes no separate headless playback controller.],
    )
    #subsection(title: "Progressive loading")[
      #points(
        [The JavaScript viewer entrypoint accepts an opt-in progressive configuration with a window duration, window entry count, window byte count, a total byte budget and a page size. The typed mount and existing callers load one complete bounded range. #adr(13)],
        [A #term("term-progressive-window") keeps whole original batches and targets five minutes, 256 entries or one MiB. One long batch can exceed a time or entry target but never the wire batch limit. An exhausted page is immediately playable and ends its window.],
        [The selected recording stays within its entry and encoded-byte budgets, and no recording survives selection or disposal. Prefetched data counts toward the same budgets.],
        [After first playback, the viewer combines the remaining checked windows of one page into a single frame update. It reads at most one page ahead, with one read and one frame update in flight.],
        [Later windows extend the validated prefix through the existing load and absolute-sequence seek protocol, so historical artifacts need no rebuild. The viewer reports only the acknowledged interval and pauses at its end, and a failed later read keeps the prefix playable and retries the uncommitted cursor.],
      )
    ]
    #subsection(title: "Isolated frames for hosted viewers")[
      #points(
        [An explicit opaque frame mode takes a self-contained document from the artifact resolver. The document carries api version, build and the isolated HTML, and the application assembles it from verified immutable bytes.],
        [The viewer mounts it as a source document with scripts only, never same-origin, form, popup, download or top-navigation capabilities, and suppresses referrers. The assembler embeds scripts, styles and fonts, provides a restrictive content security policy that blocks network access, and injects a fixed trusted parent origin. The origin is never derived from recording content, query parameters, referrers or messages.],
        [The artifact mounts with the explicit parent origin, which rejects a noncanonical HTTP or HTTPS origin. The viewer places a fresh nonce in the frame name before assigning the document, and the frame accepts messages only from its parent window, that exact origin, the nonce and the protocol version.],
        [The viewer accepts only the selected frame window, the null origin, the nonce and the protocol version. Outgoing delivery to an opaque frame uses a wildcard target because an opaque origin cannot be named, and no inbound check becomes a wildcard. Default local frames keep same-origin URL behavior. #adr(14)],
        [Neither the channel nor the sandbox certifies application-supplied reducers as pure.],
        [A real-browser check loads and seeks the real viewer's script-only frame on a loopback fixture. It verifies that each recording load creates a new named browsing context and disposes it, which the Node protocol tests cannot establish.],
      )
    ]
  ])
  #section(title: "Build identity and replay artifacts", lead: "A recording carries its build identity offline, and the application pipeline preserves the artifact that renders it.", body: [
    #md-table(3,
      ([*Value*], [*Owner*], [*Purpose*],
       [Source revision], [Git checkout], [Full commit SHA of the committed source],
       [Build identity], [Application pipeline], [Unique identity of one application build and its recording and replay pairing],
       [Replay contract], [Application], [Compatibility of checkpoints, messages and reducer semantics],
       [Host protocol], [Replay integration], [Version of commands and responses between the preview host and the artifact],
       [Artifact digest], [Application pipeline], [Content identity of the completed replay bundle with its styles and assets],
      ))
    #points(
      [Source revision, build identity and artifact digest stay separate. #adr(10) One source revision can yield different binaries through configuration, dependency or toolchain changes, so the revision is provenance and never the sole build identity. A bundle cannot embed its own final digest, so the digest is stored in a release manifest outside the bundle.],
      [The pipeline reads the revision after checkout, allocates one build identity per live and replay pairing before bundling, and writes metadata into ignored build output. No committed file contains its own future commit hash. A dirty flag marks uncertainty and never identifies the changed bytes.],
      [The live bootstrap and the replay entrypoint receive the same build identity, either injected by the bundler or passed as a startup argument, and the replay entrypoint mounts with the identity written into the session. The application carries its identity offline, so a cached page or an older mobile installation keeps its original identity.],
      [An application update starts a new session under its new identity. Batches queued earlier keep their original session metadata while they drain and are never rewritten to the uploader's current identity.],
      [The release order is: build from the intended revision, exercise a recording against its replay artifact, compute the artifact digest, store the immutable bytes, register an immutable manifest from identity to artifact, verify retrieval, then release the already-built application. An identical manifest retry may succeed, different content under one identity fails, and the same bytes are promoted between environments without a rebuild.],
      [The host distinguishes unavailable artifacts, unsupported host protocols and incompatible recordings and never loads the newest renderer silently. Artifacts are kept as long as their retained recordings need them, including after a rollback. Native platforms may need separate artifacts, and sharing one is a claim to verify.],
      [Retrace defines no manifest schema, builder package or artifact registry. A multi-file artifact's digest scheme is defined before the digest is treated as portable, and secrets never enter public build metadata.],
      [Artifacts execute code, so a production host needs a trusted publication path and an explicit isolation and integrity policy. A digest in a filename verifies nothing about fetched content. The advanced example trusts same-origin artifacts and demonstrates style and runtime separation only, and it is no sandbox for untrusted modules.],
      [The advanced example's build script chooses the build identity from the environment or allocates a unique local one. It injects it into the live bundle and the replay renderer, records source revision and dirty status in the artifact manifest, and writes replay output to a per-build directory. It refuses an existing identity so a later build cannot overwrite a recording's renderer, and it neither hashes, signs nor verifies artifact contents.],
      [The development server uses a visibly labelled mutable build that preserves no history across source edits. Historical fidelity is tested with an embedded Tauri build or the production bundle. Sessions of an older identity show an unsupported-artifact explanation.],
    )
  ])
  #section(title: "Example applications", lead: "Two maintained applications demonstrate the same session contract with different adapters.", body: [
    #behavior(title: "Playback preserves recorded timing", level: "interface", area: "Replay")[
      #given[a complete validated recording range]
      #when[a developer plays or seeks within it]
      #then[the playhead follows elapsed time and preserves gaps]
      #then[the view displays the last state at or before that time]
      #then[equal-time entries retain sequence order and appear together]
      #then[previous and next navigation move between distinct timestamps]
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
      [Exactly two applications are maintained. The basic inventory application uses provided browser storage, HTTP transport, the collector reader and the default viewer, with no handwritten FFI and no native dependency. The advanced membership application adds Tauri, recorded viewport changes, native command results, immutable replay artifacts and an optional custom local archive. #adr(6)],
      [The basic application's protected topic uses one shared parametric view for private live labels and presence-only observations. Its live-only interpreter fetches a static HTTP result without sending the label; its historical entrypoint imports only the observation schema, shared view and replay runtime. Unit checks inspect saved and uploaded bytes. A separate production-bundle browser check exercises real IndexedDB, seeking, malformed replacement and inert synthetic input with traps for HTTP, storage writes and native commands.],
      [Each application owns its model, codecs, pure reducer, full view and replay entrypoint, and both use the same public capture, client, reconstruction and viewer APIs. The advanced application changes adapters and forks no shared validation. The shared collector and the backend fault consumer belong to development tooling.],
      [Each application runs its live entrypoint, viewer and replay frame as separate entrypoints with separate local endpoints. The viewer owns search, artifact loading, timing and event navigation, and the live application owns capture and effect execution. Capture diagnostics stay a separate live-only panel.],
      [The examples send one event and its checkpoint per batch so each transition is easy to inspect. The advanced example configures a delivery queue of 2,000 batches and 8 MiB and a viewer budget of 2,000 entries, and the basic example keeps the default viewer budget of 5,000 entries.],
      [A native platform-information request demonstrates a genuine Tauri command whose result is recorded as an application message, and the browser has its own labelled result. Replay displays the stored result without invoking the command again.],
      [The application records CSS viewport dimensions, safe-area insets and screen navigation in its own model and messages, and the wire format is unchanged. The recorded viewport sizes the replay frame and the viewer scales the frame to fit, so the responsive layout is preserved. The decorative device border is no operating-system simulator.],
      [The replay document disables animations and user interaction, and adding either requires explicit presentation events and a virtual-time policy. Typography can differ between browser engines.],
      [An optional custom local archive stores its outbox and accepted archive in browser local storage, acknowledges saved ranges and implements session search and paging in Gleam. It serves one browser writer, needs no collector, and is no production storage recommendation. Only a thin binding to browser I/O and URL selection is handwritten script.],
      [The default viewer's collector and artifact-directory defaults need no application-authored JavaScript. Applications replace storage reads and artifact policy from Gleam and customize the supplied stylesheet. Presentation of the examples is defined by their stylesheets, and the replay interfaces remain experimental. #adr(5)],
      [The #term("term-replay-viewer") of the advanced example embeds trusted local artifacts in an iframe through a versioned, source-checked message protocol. It accepts validated checkpoint ranges, bounds retained snapshots, and keeps Time Travel out of its runtime dependencies. The retained attribution records the original derivation. #adr(4)],
      [The companion and viewer remain experimental, bounded replay without live subscription or an unbounded cache. #adr(3) The host protocol checks origin, frame identity, a fresh per-load token, protocol version and application build, and those checks do not sandbox hostile artifacts. #adr(2)],
    )
    #md-table(3,
      ([*Part*], [*Owns*], [*Does not own*],
       [Application domain module], [Model, safe payloads, reducer, presentation observations], [Transport or effects],
       [Application screen module], [Complete view reused by live and historical entrypoints], [Viewer controls],
       [Replay companion], [Build and schema checks, checkpoints, reconstruction, inert frame], [Live effects or storage],
       [Application replay module], [Codecs, view, labels and viewport projection], [Generic replay machinery],
       [Frame entrypoint], [Historical Lustre entrypoint and inert view], [Native calls or capture],
       [Timeline module], [Time-to-state selection and marker grouping], [Timers, storage or the DOM],
       [Viewer module], [Default interface, frame lifecycle, playback clock], [Collector or artifact policy],
       [Viewer host], [Collector reads and build-to-artifact resolution], [Application model or reducer],
      ))
  ])
]
