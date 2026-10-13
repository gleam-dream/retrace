# Retrace client

`start(config, on_status)` uses IndexedDB and HTTP. It has no native npm dependency.
Tauri applications explicitly import `retrace_frontend/client/tauri` and use
`start_with(config, tauri.storage(), http_transport(config.endpoint), on_status)`.
Only that adapter needs `@tauri-apps/plugin-store` and the Tauri store capability.
See the membership application for platform selection.

`enqueue` confirms local persistence through its callback. Upload acknowledgement
is a separate status. The five-second deadline includes reading the receipt body.
`stop` aborts the active request and cancels retries; admitted saves still settle.
It does not close a handle borrowed from custom storage. The browser/process owns
the default storage handle lifetime; custom adapters own their resources.

Pending capture and durable storage each use `max_items` and `max_bytes`.
Together they may retain up to twice that encoded-payload budget, plus metadata,
encoding temporaries and storage-engine overhead. This is not a process heap cap.
Overload or persistence failure stops new capture for this runtime; saved batches
continue draining. Start a fresh application session after a capture gap.

## Custom adapters from Gleam

`retrace_frontend/client/adapter` constructs the existing `Storage` and `Transport` values.
Storage and upload policy are independent; no additional dependency is required.

```gleam
import retrace_frontend/client as client
import retrace_frontend/client/adapter

// open_store and upload are application functions with the signatures below.
let storage = adapter.storage(open_store, explain_storage_error)
let transport = adapter.transport(upload, explain_upload_error)
client.start_with(config, storage, transport, on_status)
```

| Operation       | Application supplies                                                       |
| --------------- | -------------------------------------------------------------------------- |
| `open_store`    | `fn(adapter.Queue) -> adapter.Task(adapter.Store(error), error)`           |
| `Store.all`     | `fn() -> adapter.Task(List(adapter.Row), error)`                           |
| `Store.put`     | `fn(adapter.Row) -> adapter.Task(Nil, error)`                              |
| `Store.remove`  | `fn(String) -> adapter.Task(Nil, error)`                                   |
| `upload`        | `fn(String) -> adapter.Task(String, error)`                                |
| Error formatter | `fn(error) -> String`; storage and transport may use different error types |

A task is a cold callback operation:

```gleam
fn(reply: fn(Result(value, error)) -> Nil) -> fn() -> Nil
```

Start IO when the task is invoked, reply with its result, and return a function
that cancels pending work. `adapter.defer(fn() { ... })` wraps synchronous work
without running it during adapter construction. The bridge observes only the
first completion, turns provider throws into failures, and ignores late replies.
It does not start another scheduler or retry loop.

`Queue` carries `name`, `max_items` and `max_bytes`. `Row` carries the opaque queue
key and encoded batch body. `put` must enforce durable item/UTF-8-byte limits
atomically, accept identical retries, reject conflicting content and reply only
after saving. All storage operations must settle or fail. The client does not
cancel storage operations or close borrowed handles: admitted saves and deletions
finish after shutdown. The caller releases resources after those operations settle.
Coordinate multiple writers in the storage implementation if needed.

Upload receives the exact encoded batch and returns acknowledgement JSON. This
preserves byte identity and lets applications compose existing HTTP libraries or
interpret the batch explicitly with `retrace/wire`. The runtime validates session
and final sequence before deleting anything. Cancellation invokes pending upload
cleanup at most once and settles the request even if the provider never replies.
A late success cannot delete the saved batch. Cancellation cannot undo a server
commit; upload retries still require idempotent admission.

Provider-specific error types stay in application callbacks until the selected
formatter produces existing client diagnostics. This does not change the current
string-based status API. Storage policy, authentication and IO bindings remain
application responsibilities; do not record authentication headers in events.

The [advanced consumer](../../../examples/advanced/src/retrace_example/local_archive.gleam)
implements queue limits, duplicate handling, receipt construction and viewer reads
in Gleam. Its small FFI file binds only localStorage IO and URL selection. This is
single-writer development storage, with no cross-tab transaction or production
durability guarantee. No archive framework or build-metadata API is added.

## Existing JavaScript adapters

Opaque FFI adapters remain compatible. The contracts are unchanged:

```javascript
// Storage: (name, maxItems, maxBytes) => Promise<Store>
// Store.all(): Promise<Array<{key: string, body: string}>>
// Store.put(key, body): Promise<void>
// Store.remove(key): Promise<void>
// Transport: (encodedBatch, AbortSignal) => Promise<acknowledgementJson>
```

Foreign transports must honor the supplied abort signal and reject unsuccessful
responses. `start_with` uses the selected transport; `config.endpoint` is used only
by the default `start` or when constructing `http_transport` explicitly.
