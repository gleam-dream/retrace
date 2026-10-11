# Retrace client

`start(config, on_status)` uses IndexedDB and HTTP. It has no native npm dependency.
Tauri applications explicitly import `retrace_client/tauri` and use
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

## Custom adapters

`Storage` and `Transport` are opaque Gleam FFI types. An application module can
return these types from JavaScript, as `examples/advanced/src/local_archive_ffi.mjs`
demonstrates. `start_with` uses the selected transport; `config.endpoint` is used
only when constructing `http_transport` or calling the default `start`.

```javascript
// Storage: (name, maxItems, maxBytes) => Promise<Store>
// Store.all(): Promise<Array<{key: string, body: string}>>
// Store.put(key, body): Promise<void>
// Store.remove(key): Promise<void>
// Transport: (encodedBatch, AbortSignal) => Promise<acknowledgementJson>
```

`put` must enforce durable item/UTF-8-byte limits atomically, accept identical
retries and reject conflicting content. Resolve only once the selected storage
has saved the value. All operations must settle or reject. A factory owns one
queue writer; coordinate multiple writers in the adapter if needed. Transport
must honor cancellation, reject unsuccessful responses and return the receipt
body. Runtime validates session and final sequence before deleting anything.
The transport can add application-owned authentication headers without exposing
credentials to the recorder. Avoid recording those headers in event payloads.

The advanced example’s local mode uses a persistent local browser archive instead of HTTP.
Its localStorage adapter is for a single writer and disposable local testing;
it does not provide cross-tab transactions or production durability guarantees.

The status and persistence diagnostics remain strings in this experimental API.
Machine-actionable error categories are a possible follow-up, not a current claim.
