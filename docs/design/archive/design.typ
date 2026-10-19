#import "../.render/designlib.typ": *
#let title = [Archive]
#let accent = "blue"
#let body = [
  #section(title: "Foundation", lead: "Archive owns server-side admission, indexing, object archival, retrieval and erasure of recorded sessions.", body: [
    #goal(title: "Commit every accepted batch before acknowledging it")[The server admits a #term("term-batch") in a database transaction that locks its #term("term-admission-cursor"), and returns its #term("term-acknowledgement") only after the commit.]
    #goal(title: "Move accepted recordings to object storage without a loss window")[The database copy of a batch stays readable until its archive object is uploaded and verified, so an object-store outage only delays archival.]
    #goal(title: "Erase a session on caller authority")[A caller-authorized #term("term-deletion-fence") stops admission, archival, search and reads for a session, and the caller drives deletion of its objects and recording rows.]
    #no-goal(title: "A hardened hosted service")[Authentication, tenant isolation, rate limits, archive repair and a versioned migration system belong to the deployment. The development collector binds to loopback and is not a service configuration.]
    #invariant(title: "A committed batch outlives every archival failure", enforcement: "mechanism")[A failed upload, failed verification or dead worker leaves the database copy readable and eligible for retry.]
    #invariant(title: "Admission is ordered per session", enforcement: "mechanism")[A batch is admitted only when its checkpoint matches the session's #term("term-admission-cursor") and its fixed session metadata agrees with the stored metadata.]
    #invariant(title: "Original batch identity survives archival", enforcement: "mechanism")[A #term("term-batch-receipt") retains the original range and digest after the database payload is removed, so an exact retry returns the original acknowledgement.]
    #invariant(title: "A fenced session never becomes readable again", enforcement: "mechanism")[Admission, archival, search and reads refuse a fenced session, including a late object write that finishes after its worker died.]
    #invariant(title: "Erasure never completes while an admitted upload might publish", enforcement: "mechanism")[An #term("term-write-attempt") is committed under the session lock before its PUT is dispatched. Erasure reports completion, clears recording rows and marks the tombstone reconciled only when every attempt is completed or proven quiescent and every inventoried key is deleted. A timeout, expired lease, dead worker, absent object, successful DELETE or local cancellation never proves quiescence.]
    #principle(title: "The host owns operations and policy", lens: "composition")[The host owns the database pool, object-store configuration, worker lifetimes, retention deadlines, authorization and backup restoration. The package starts no hidden worker.]
  ])
  #pending-ledger(
    pending-entry(title: "Publication, fence and recovery statements carried over from retired guides", kind: "verify", since: "2026-10-17")[
      The rules for the publication lock, the fence snapshot, plan recovery and late-object reconciliation come from retired guides. This review confirmed the numeric limits (1000 entries, 32 MiB, sixteen concurrent reads, eight keys per pass) and the generation states. Server checks now exercise attempt admission, fencing and resolution against a controlled provider (ADR 0019); plan recovery after a crash and the behavior of a real provider remain unverified.
    ],
  )
  #section(title: "Admission", lead: "The server serializes admission per session and distinguishes duplicates from conflicts.", body: [
    #behavior(title: "Duplicates are distinguished from conflicts", level: "boundary", area: "Admission")[
      #given[a batch was durably accepted]
      #when[a caller retries its range]
      #then[identical content returns the same acknowledgement and different content is refused]
    ]
    #behavior(title: "Session admission is ordered and atomic", level: "boundary", area: "Admission")[
      #given[a session with an #term("term-admission-cursor")]
      #when[a new batch is admitted]
      #then[the batch is refused unless its checkpoint matches that cursor and its fixed session metadata agrees with the stored metadata]
      #then[an admitted batch and the session index advance together]
    ]
    #points(
      [Admission locks the session row inside a transaction. The initial checkpoint starts at sequence zero. Out-of-order batches are refused. #adr(1)],
      [A previously accepted batch is identified by session and starting sequence. Its digest permits exact retry checks after its database payload is removed. Different chunking is a conflict, never automatic deduplication.],
      [A host that must authorize or account atomically with admission calls the in-transaction admission and fence operations inside its own database transaction. Those operations neither begin nor commit a transaction, because nesting a transaction would commit the outer one unexpectedly.],
      [Session search is bounded to the latest 100 sessions and supports an exact user-reference filter. Search pagination is not provided.],
    )
  ])
  #section(title: "Archival generations", lead: "Archival packs whole batches into immutable generations and preserves the old sources until publication is verified.", visual: sequence(
    title: "Publish one archive generation",
    participants: ((id: "worker", label: "Archive worker", shape: "control"), (id: "db", label: "Database", shape: "database"), (id: "store", label: "Object store", shape: "database")),
    steps: (
      seq-msg("worker", "db", "commit plan: key, digest, payload"),
      seq-msg("worker", "store", "upload the planned bytes"),
      seq-msg("worker", "store", "read back and compare with the planned bytes"),
      seq-msg("worker", "db", "clear payloads, move pointers, mark current"),
    ),
    caption: [A failure at any step leaves the plan and the old sources in place, so a replacement worker resumes from the committed plan.],
  ), body: [
    #behavior(title: "Archival failure preserves accepted data", level: "boundary", area: "Archival")[
      #given[a committed batch still held in the database]
      #when[object upload fails]
      #then[the database copy remains readable and eligible for a later retry]
    ]
    #behavior(title: "Session archives preserve whole batches", level: "boundary", area: "Archival")[
      #given[an idle session with original durable batch receipts]
      #when[the host compacts it or appends a late batch]
      #then[at most 1000 entries occupy each current generation]
      #then[a session no larger than that stays in one object when archivable]
      #then[original checkpoints, page order and exact-retry identities remain unchanged]
    ]
    #behavior(title: "Publication has a durable recovery source", level: "boundary", area: "Archival")[
      #given[a persisted archive plan with its payload and fixed object key]
      #when[object upload, verification or the publishing worker fails]
      #then[the old sources remain authoritative until verified publication commits]
      #then[a replacement worker can resume the plan]
      #then[a deletion fence inventories every possible generation]
    ]
    #points(
      [A #term("term-batch-receipt") retains its original range and digest after archival. The per-batch archive operation stores one batch per object. The session operation groups whole original batches greedily into #term("term-archive-segment")s of at most 1000 entries after host-configured inactivity, ordinarily 60 seconds.],
      [A session at or below 1000 entries has one current object when archivable. Only entry count creates another segment, and checkpoints and retry receipts are never rechunked. A late batch replaces its preceding segment when the whole batch fits.],
      [An #term("term-archive-generation") moves from planned to current to retired and never becomes current again. An #term("term-archive-plan") commits its key, digest and complete payload before any remote PUT. Publication verifies a GET against the exact planned bytes before clearing database payloads and changing pointers.],
      [A decoded segment is limited to 32 MiB, and decompression stops at that limit. A larger group keeps its existing sources and receives a durable deferral until the session advances, because byte size never creates an early segment. At most one planned payload per session temporarily duplicates up to 32 MiB in the database, which hosts count in capacity policy.],
      [Preparation snapshots sources under a short session lock, reads objects without that lock, and rechecks the original source pointers and complete segment coverage before committing a plan. Per-batch reads use windows of at most sixteen one-MiB objects under a running byte budget. Admission beyond the snapshot range stays safe.],
      [Publication admits a #term("term-write-attempt") under the session lock, commits it, then uploads and verifies outside the lock and replaces pointers only after a locked recheck of the fence and the plan. A crash or uncertain PUT leaves a durable plan for retry, an inventoried key and an attempt that blocks erasure completion until the host proves it quiescent. Adapters still bound their external I/O. The archive operation reports true for publication or durable deferral and false for no work or a snapshot invalidated by a competing worker.],
      [The segment object is gzip-compressed newline-delimited JSON, a versioned session and range header followed by the unchanged encoded batches. Retired keys are eligible for immediate cleanup in passes of at most eight. The reclaim operation rechecks that neither batches nor an active plan reference a key, and later deletion reconciliation follows the host interval.],
      [Old per-batch objects stay readable and become eligible for idle compaction. A host that must avoid temporary per-batch objects does not run the per-batch archive worker. #adr(9)],
    )
  ])
  #section(title: "Retrieval", lead: "Archived sessions stay replayable, and reads return verified batches in recording order.", body: [
    #behavior(title: "Archived sessions remain replayable", level: "boundary", area: "Retrieval")[
      #given[a batch was successfully archived]
      #when[the collector restarts and the viewer requests that session]
      #then[the session remains searchable]
      #then[its recording is fetched and checked before playback]
    ]
    #behavior(title: "Concurrent retrieval preserves ordered evidence", level: "boundary", area: "Retrieval")[
      #given[a caller opts into concurrent reads from an adapter safe for independent read calls]
      #when[a bounded archived range is retrieved]
      #then[concurrency stays within the requested bounded budget]
      #then[results remain in recording order]
      #then[every payload is verified]
      #then[any failed object refuses the whole range]
    ]
    #behavior(title: "Read workers remain scoped to their caller", level: "boundary", area: "Retrieval")[
      #given[a concurrent range read has outstanding adapter calls]
      #when[the read completes, fails or loses its caller]
      #then[its read workers terminate without stopping borrowed resources]
      #then[a deletion fence observed before return refuses the range]
    ]
    #points(
      [Range retrieval is ordered and bounded to 128 batches, and the last returned entry's absolute sequence is the next-page cursor. Serial reads run in the calling process.],
      [Opt-in concurrent reads clamp their worker budget to one through sixteen and require an adapter safe for independent calls. The budget applies to each read and not to all callers. #adr(16) Workers belong only to the synchronous read, and adapter operations bound their own external I/O.],
      [A page fails as a whole when an object is missing, corrupt or unavailable. Each page fetches a shared object once and verifies both its envelope and original batch identities. The object adapter returns compressed bytes, and reconstruction verifies the exact stored content digest after bounded decompression.],
      [A missing object permits one authoritative pointer refresh only when a concurrent replacement changed its source. Corrupt content never falls back. A final fence check refuses a read fenced while its objects were being fetched.],
      [A concurrent read owns a temporary coordinator and its read workers, and it waits for them to terminate on success or failure. Caller death also terminates them. An adapter exception is returned as an unavailable-storage failure, and cancellation never stops a provider operation or a resource the adapter created.],
      [Scheduling uses linked processes, typed subjects and selectors from the standard Gleam Erlang library, and an exception guard around foreign adapter calls guarantees worker cleanup. Native bindings remain for hashing, bounded gzip handling and atomic filesystem storage.],
    )
  ])
  #section(title: "Retention and erasure", lead: "The caller authorizes deletion and drives it through a fence and retained tombstones.", body: [
    #behavior(title: "Erasure fences delivery and archival", level: "boundary", area: "Retention")[
      #given[a caller-authorized session deletion]
      #when[the caller commits a fence and drives erasure]
      #then[admission and reads refuse the session]
      #then[a fence waits only for upload admission, never for a remote call]
      #then[a fenced session admits no new attempt, so a retained worker neither starts nor retries an upload]
      #then[objects are deleted before recording rows]
      #then[retained #term("term-tombstone")s permit idempotent retry and late-object reconciliation]
    ]
    #behavior(title: "Erasure waits for uploads whose outcome is unknown", level: "boundary", area: "Retention")[
      #given[a fenced session with an admitted upload whose PUT failed or was lost without proof of its outcome]
      #when[the caller drives erasure]
      #then[the result reports the count of uploads that might publish and not completion]
      #then[keys of those uploads are not deleted or counted as done, and the tombstone is not marked reconciled]
      #then[completion follows only after the host proves every such upload quiescent and every inventoried key is deleted]
    ]
    #points(
      [A #term("term-deletion-fence") atomically prevents new admission, archive work, search and reads, including for a session ID not yet admitted. It snapshots object keys under the transaction-scoped session lock that admission and upload admission also use. Every planned, current and retired key and every attempt key participates in fencing and repeated erasure.],
      [Erasure idempotently deletes the objects before clearing recording rows. Each pass handles at most eight keys and reports erasing, awaiting writers with the unresolved count, or erased. A further operation advances the least recently checked unfinished fence or reconciles a completed deletion after a supplied interval, and reports that session and its erasure state.],
      [A #term("term-write-attempt") is completed when PUT returns success. Otherwise it stays in flight or failed until the host proves it quiescent: erasure takes a host function that Retrace calls on every pass for each such attempt with its state, object key, time since admission and time since a returned failure, and Retrace records the basis of each positive answer. #term("term-quiescence") is therefore never inferred from elapsed time since admission, because a paused worker can send its PUT arbitrarily later. A host may rely on time since a returned failure only against a provider-qualified maximum request lifetime.],
      [Object removal is supplied separately from the put and get functions of an object store. #term("term-tombstone")s and object keys are retained because a PUT with an uncertain remote outcome can finish after its worker died, and repeated deletion reconciles that object without making its session readable.],
      [The host owns authorization, deadlines, worker supervision, retry cadence and backup restoration. It reapplies tombstones after restoring a backup and separately qualifies versioned objects, provider snapshots and physical deletion deadlines. Completed erasure does not establish removal from provider versions or backups.],
      [Every ingestion and archive worker is upgraded before retention is enabled, because older workers ignore the fence and do not record attempts. Deleted is an additional failure variant of admission and reads. #adr(15) #adr(19)],
    )
  ])
  #section(title: "Domain model", lead: "Archive owns the session record, the batch receipt, the archive generation and the tombstone.", body: [
    #subsection(title: "Archive domain")[
      #entity(
        title: "Session record",
        description: [The server's record of one session: its fixed metadata and the next sequence it admits.],
        kind: "aggregate",
        owner: "archive",
        lifecycle: "stateful",
        domain: "archive",
        tint: "blue",
      )[
        #attribute(name: "Fixed metadata", type: "Session metadata", provenance: "authored")[the identifier, user reference, build, platform and replay contract that every later batch must agree with]
        #attribute(name: "Admission cursor", type: "Sequence number", provenance: "derived")[the highest committed sequence, advanced with each admitted batch under the session lock]
        #relates(cardinality: "1 : n")[retains many *Batch receipts*]
        #relates(cardinality: "1 : n")[is archived in many *Archive generations*]
      ]
      #entity(
        title: "Batch receipt",
        description: [The durable record of an admitted batch that survives removal of its database payload.],
        kind: "entity",
        owner: "archive",
        lifecycle: "append-only",
        domain: "archive",
        tint: "blue",
      )[
        #attribute(name: "Starting sequence", type: "Sequence number", provenance: "derived")[the sequence that identifies the batch within its session]
        #attribute(name: "Range", type: "Contiguous sequence range", provenance: "derived")[the original range the batch covered]
        #attribute(name: "Content digest", type: "Content digest", provenance: "derived")[the digest that permits an exact retry check after the payload is gone]
        #relates(cardinality: "n : 1")[belongs to one *Session record*]
        #relates(cardinality: "n : 0..1")[is held by at most one current *Archive generation*]
      ]
      #entity(
        id: "archive-generation",
        title: "Archive generation",
        description: [One immutable archive object for a segment of whole batches.],
        kind: "entity",
        owner: "archive",
        lifecycle: "stateful",
        domain: "archive",
        tint: "blue",
      )[
        #attribute(name: "Object key", type: "Object key", provenance: "derived")[the fixed key committed with the plan before any upload]
        #attribute(name: "Content digest", type: "Content digest", provenance: "derived")[the digest of the planned bytes that verification reads back]
        #attribute(name: "Planned payload", type: "Archive payload", provenance: "derived")[the complete payload kept in the database until verified publication]
        #attribute(
          id: "state",
          name: "Generation state",
          type: "Generation state",
          provenance: "derived",
          state-type: "generation-state",
          state-machine: "generation-lifecycle",
        )[planned, current or retired]
        #relates(cardinality: "n : 1")[archives batches of one *Session record*]
      ]
      #entity(
        title: "Tombstone",
        description: [The retained record that a session was fenced for erasure.],
        kind: "entity",
        owner: "archive",
        lifecycle: "append-only",
        domain: "archive",
        tint: "blue",
      )[
        #attribute(name: "Object key inventory", type: "Object keys", provenance: "derived")[every planned, current and retired key of the session]
        #attribute(name: "Erasure completion", type: "Erased, erasing or awaiting writers", provenance: "derived")[whether every write attempt is resolved and erasure finished deleting the session's objects and rows]
        #attribute(name: "Write attempts", type: "Write attempts", provenance: "derived")[each admitted upload with its immutable key and its in-flight, failed, completed or quiesced state]
        #relates(cardinality: "1 : 0..1")[fences one *Session record* when the session was already admitted]
      ]
    ]
    #subsection(title: "Archive generation lifecycle")[
      #state-type(
        id: "generation-state",
        title: "Generation state",
        variants: (
          (id: "planned", description: [The key, digest and payload are committed and the object is not yet published.]),
          (id: "current", description: [The object is the verified publication for its entry range.]),
          (id: "retired", description: [A later generation replaced the object and its key awaits cleanup.]),
        ),
      )
      #state-machine(
        id: "generation-lifecycle",
        subject: "archive-generation",
        state-field: "state",
        state-type: "generation-state",
        states: ("planned", "current", "retired"),
        transitions: (
          ("planned", "current", "publication verified"),
          ("current", "retired", "replaced by a later generation"),
        ),
        initial: "planned",
        accepting: ("retired",),
      )
    ]
  ])
  #section(title: "Collector protocol", lead: "A collector serves batch submission, session listing and batch paging, and the packaged client and viewer depend on exactly these three operations.", body: [
    #behavior(title: "A submitted batch is acknowledged after it is durable", level: "boundary", area: "Collector protocol")[
      #given[a batch within the size limit whose checkpoint matches the session's committed position]
      #when[a caller submits the batch]
      #then[the batch is committed before any acknowledgement is sent]
      #then[the acknowledgement names the session and the end position of the batch]
    ]
    #behavior(title: "Concurrent identical submissions are acknowledged once", level: "boundary", area: "Collector protocol")[
      #given[several callers submit the same accepted batch at the same time]
      #when[the submissions race]
      #then[every caller receives the same acknowledgement]
      #then[the session position advances only once]
    ]
    #behavior(title: "Conflicting and out-of-order submissions are refused", level: "boundary", area: "Collector protocol")[
      #given[a session with a committed position]
      #when[a caller submits a batch whose checkpoint does not match that position or whose content differs from an accepted range]
      #then[the submission is refused as conflicting]
      #then[the stored session and its batches are unchanged]
    ]
    #behavior(title: "Invalid and oversized submissions are refused", level: "boundary", area: "Collector protocol")[
      #given[a submission that is larger than one MiB, or whose entries are not contiguous or exceed the entry limit]
      #when[a caller submits it]
      #then[an oversized submission is refused as oversized before it is decoded]
      #then[any other invalid submission is refused as invalid]
      #then[no stored state changes]
    ]
    #behavior(title: "Storage failure is reported without internal detail", level: "boundary", area: "Collector protocol")[
      #given[durable storage is unavailable or a stored archive fails verification]
      #when[a caller uses any collector operation]
      #then[the caller learns only that recording storage is unavailable]
      #then[storage diagnostics and credentials are not exposed]
    ]
    #behavior(title: "Session listing is filtered, recent and bounded", level: "boundary", area: "Collector protocol")[
      #given[sessions recorded for several user references]
      #when[a caller lists sessions with a user reference or without one]
      #then[a listing with a user reference returns only sessions whose user reference equals it exactly]
      #then[a listing without one returns the sessions of every user reference]
      #then[either listing returns at most the 100 most recently updated sessions, newest first]
      #then[each entry reports the session, its committed position, its elapsed recorded time and the counts of batches awaiting archival and already archived]
    ]
    #behavior(title: "Batch paging returns whole batches in recording order", level: "boundary", area: "Collector protocol")[
      #given[a session with accepted batches, some of them archived]
      #when[a caller pages batches after a position]
      #then[the page holds at most 128 whole batches whose range ends after that position, in recording order]
      #then[an archived batch is verified before it is returned]
      #then[a page requested after the last accepted position is empty]
      #then[a request without a position starts at the beginning of the session]
    ]
    #behavior(title: "Paging a session with no accepted batches is empty", level: "boundary", area: "Collector protocol")[
      #given[a session identifier with no accepted batches and no erasure fence]
      #when[a caller pages its batches]
      #then[the page is empty, as for a known session paged past its end]
    ]
    #points(
      [The three operations are the contract between the packaged client, the viewer and any collector that serves them. A collector may add operations, and it may not change or remove these. #adr(18)],
      [A collector authorizes callers and scopes tenants itself, because the server package does not. The development collector does neither, binds to loopback by default and stays outside the hosted-deployment policy.],
      [Refusals reach callers as distinguishable categories: conflicting, invalid, oversized, erased session and unavailable storage. The client's handling of each category belongs to the separate client retry and rejected-batch ruling.],
    )
  ])
  #section(title: "Hosting and storage ownership", lead: "The server package borrows its resources, and the development collector is the example host.", body: [
    #points(
      [The server package borrows a database pool and object-store functions. It starts no HTTP listener, pool or background process on import, and storage functions report explicit read and write failures.],
      [The package supplies an S3-compatible adapter that takes credentials, bucket and region, and a local directory adapter. A caller may supply its own #term("term-object-store"), so the S3 adapter works with HTTPS and any region and the directory adapter keeps admission unchanged.],
      [The schema helper creates the initial schema and its archive tables, and the host chooses when to run it before upgraded workers start. It is not a versioned migration system. The schema helper refuses a database that holds tombstones from before write attempts and changes nothing. The runtime role needs select, insert, update and delete privileges on those tables and usage on the attempt sequence.],
      [The development #term("term-collector") owns the pool and the periodic archive worker. It serves the collector protocol above and adds local routes for one archive attempt and health. It is unauthenticated, binds to loopback by default, and stores local data in ignored directories.],
    )
  ])
]
