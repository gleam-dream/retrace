#import "../.render/designlib.typ": *
#let title = [Archive]
#let accent = "blue"
#let body = [
  #section(title: "Foundation", lead: "Archive owns server-side admission, indexing, object archival, retrieval and erasure of recorded sessions.", body: [
    #goal(title: "Commit every accepted batch before acknowledging it")[The server admits a #term("term-batch") in a database transaction that locks its session cursor, and returns its #term("term-acknowledgement") only after the commit.]
    #goal(title: "Move accepted recordings to object storage without a loss window")[The database copy of a batch stays readable until its archive object is uploaded and verified, so an object-store outage only delays archival.]
    #goal(title: "Erase a session on caller authority")[A caller-authorized #term("term-deletion-fence") stops admission, archival, search and reads for a session, and the caller drives deletion of its objects and recording rows.]
    #no-goal(title: "A hardened hosted service")[Authentication, tenant isolation, rate limits, archive repair and a versioned migration system belong to the deployment. The development collector binds to loopback and is not a service configuration.]
    #invariant(title: "A committed batch outlives every archival failure", enforcement: "mechanism")[A failed upload, failed verification or dead worker leaves the database copy readable and eligible for retry.]
    #invariant(title: "Admission is ordered per session", enforcement: "mechanism")[A batch is admitted only when its checkpoint matches the session's durable cursor and its fixed session metadata agrees with the stored metadata.]
    #invariant(title: "Original batch identity survives archival", enforcement: "mechanism")[A #term("term-batch-receipt") retains the original range and digest after the database payload is removed, so an exact retry returns the original acknowledgement.]
    #invariant(title: "A fenced session never becomes readable again", enforcement: "mechanism")[Admission, archival, search and reads refuse a fenced session, including a late object write that finishes after its worker died.]
    #principle(title: "The host owns operations and policy", lens: "composition")[The host owns the database pool, object-store configuration, worker lifetimes, retention deadlines, authorization and backup restoration. The package starts no hidden worker.]
  ])
  #section(title: "Admission", lead: "The server serializes admission per session and distinguishes duplicates from conflicts.", body: [
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
    #points(
      [Admission locks the session row inside a transaction. The initial checkpoint starts at sequence zero. Out-of-order batches are refused. #adr(1)],
      [A previously accepted batch is identified by session and starting sequence. Its digest permits exact retry checks after its database payload is removed. Different chunking is a conflict, never automatic deduplication.],
      [A host that must authorize or account atomically with admission calls the in-transaction admission and fence operations inside its own database transaction. Those operations neither begin nor commit a transaction, because nesting a transaction would commit the outer one unexpectedly.],
      [Session search is bounded to the latest 100 sessions and supports an exact user-reference filter. Search pagination is not provided.],
    )
  ])
  #section(title: "Archival generations", lead: "Archival packs whole batches into immutable generations and preserves the old sources until publication is verified.", body: [
    #behavior(title: "Archival failure preserves accepted data", level: "boundary", area: "Archival")[
      #given[a committed batch still held in the database]
      #when[object upload fails]
      #then[the database copy remains readable and eligible for a later retry]
    ]
    #behavior(title: "Session archives preserve whole batches", level: "boundary", area: "Archival")[
      #given[an idle session with original durable batch receipts]
      #when[the host compacts it or appends a late batch]
      #then[at most 1000 entries occupy each current generation, a session no larger than that stays in one object when archivable, and original checkpoints, page order and exact-retry identities remain unchanged]
    ]
    #behavior(title: "Publication has a durable recovery source", level: "boundary", area: "Archival")[
      #given[a persisted archive plan with its payload and fixed object key]
      #when[PUT, verification or the publishing worker fails]
      #then[the old sources remain authoritative until verified publication commits; a replacement worker can resume the plan and a deletion fence inventories every possible generation]
    ]
    #points(
      [A #term("term-batch-receipt") retains its original range and digest after archival. The legacy archive operation stores one batch per object. The session operation groups whole original batches greedily into #term("term-archive-segment")s of at most 1000 entries after host-configured inactivity, ordinarily 60 seconds.],
      [A session at or below 1000 entries has one current object when archivable. Only entry count creates another segment, and checkpoints and retry receipts are never rechunked. A late batch replaces its preceding segment when the whole batch fits.],
      [An #term("term-archive-generation") moves from planned to current to retired and never becomes current again. An #term("term-archive-plan") commits its key, digest and complete payload before any remote PUT. Publication verifies a GET against the exact planned bytes before clearing database payloads and changing pointers.],
      [A decoded segment is limited to 32 MiB, and decompression stops at that limit. A larger group keeps its existing sources and receives a durable deferral until the session advances, because byte size never creates an early segment. At most one planned payload per session temporarily duplicates up to 32 MiB in the database, which hosts count in capacity policy.],
      [Preparation snapshots sources under a short session lock, reads objects without that lock, and rechecks the original source pointers and complete segment coverage before committing a plan. Legacy reads use windows of at most sixteen one-MiB objects under a running byte budget. Admission beyond the snapshot range stays safe.],
      [Publication holds the session lock while it uploads, verifies and replaces pointers, so adapters bound their external I/O. A crash or uncertain PUT leaves a durable plan for retry and an inventoried key for erasure. The archive operation reports true for publication or durable deferral and false for no work or a snapshot invalidated by a competing worker.],
      [The segment object is gzip-compressed newline-delimited JSON, a versioned session and range header followed by the unchanged encoded batches. Retired keys are eligible for immediate cleanup in passes of at most eight. The reclaim operation rechecks that neither batches nor an active plan reference a key, and later deletion reconciliation follows the host interval.],
      [Old per-batch objects stay readable and become eligible for idle compaction. A host that must avoid temporary per-batch objects does not run the legacy archive worker. #adr(9)],
    )
  ])
  #section(title: "Retrieval", lead: "Archived sessions stay replayable, and reads return verified batches in recording order.", body: [
    #behavior(title: "Archived sessions remain replayable", level: "boundary", area: "Retrieval")[
      #given[a batch was successfully archived]
      #when[the collector restarts and the viewer requests that session]
      #then[the session remains searchable and its recording is fetched and checked before playback]
    ]
    #behavior(title: "Concurrent retrieval preserves ordered evidence", level: "boundary", area: "Retrieval")[
      #given[a caller opts into concurrent reads from an adapter safe for independent read calls]
      #when[a bounded archived range is retrieved]
      #then[concurrency stays within the requested bounded budget, results remain in recording order, every payload is verified, and any failed object refuses the whole range]
    ]
    #behavior(title: "Read workers remain scoped to their caller", level: "boundary", area: "Retrieval")[
      #given[a concurrent range read has outstanding adapter calls]
      #when[the read completes, fails or loses its caller]
      #then[its read workers terminate without stopping borrowed resources; a deletion fence observed before return refuses the range]
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
      #then[admission and reads refuse the session, active archival settles before the fence, objects are deleted before recording rows, and retained tombstones permit idempotent retry and late-object reconciliation]
    ]
    #points(
      [A #term("term-deletion-fence") atomically prevents new admission, archive work, search and reads, including for a session ID not yet admitted. It snapshots object keys under the transaction-scoped session lock that admission and archival also use. Every planned, current and retired key participates in fencing and repeated erasure.],
      [Erasure idempotently deletes the objects before clearing recording rows. Each pass handles at most eight keys and reports whether the session finished erasing. A further operation processes an unfinished fence or reconciles the oldest completed deletion after a supplied interval.],
      [Object removal is supplied separately from the put and get functions of an object store. Tombstones and object keys are retained because a PUT with an uncertain remote outcome can finish after its worker died, and repeated deletion reconciles that object without making its session readable.],
      [The host owns authorization, deadlines, worker supervision, retry cadence and backup restoration. It reapplies tombstones after restoring a backup and separately qualifies versioned objects, provider snapshots and physical deletion deadlines. Completed erasure does not establish removal from provider versions or backups.],
      [Every ingestion and archive worker is upgraded before retention is enabled, because older workers ignore the fence. Deleted is an additional failure variant of admission and reads. #adr(15)],
    )
  ])
  #section(title: "Hosting and storage ownership", lead: "The server package borrows its resources, and the development collector is the example host.", body: [
    #points(
      [The server package borrows a database pool and object-store functions. It starts no HTTP listener, pool or background process on import, and storage functions report explicit read and write failures.],
      [The package supplies an S3-compatible adapter that takes credentials, bucket and region, and a local directory adapter. A caller may supply its own #term("term-object-store"), so the S3 adapter works with HTTPS and any region and the directory adapter keeps admission unchanged.],
      [The schema helper creates the initial schema and its archive tables, and the host chooses when to run it before upgraded workers start. It is not a versioned migration system. The runtime role needs select, insert, update and delete privileges on those tables and no sequence privileges.],
      [The development #term("term-collector") owns the pool and the periodic archive worker. It exposes local routes for batch admission, session search, ordered batch pages, one archive attempt and health. It is unauthenticated, binds to loopback by default, and stores local data in ignored directories.],
      [The collector's session listing returns the latest 100 summaries with an optional exact user filter. Its batch page returns up to 128 encoded batch strings after a given sequence. Its admission route answers with the session ID and acknowledgement after the commit.],
    )
  ])
]
