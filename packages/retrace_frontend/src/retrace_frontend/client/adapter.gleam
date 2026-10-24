//// Construct existing client adapters from typed Gleam operations.
//// No storage engine, upload policy, scheduler or resource owner is introduced.

import retrace_frontend/client

/// Cold operation: start work only when invoked, reply with its outcome, and
/// return cancellation for pending work. The bridge observes only the first
/// completion and ignores late replies after cancellation. Cancellation cannot
/// undo a remote commit; upload retries must still be idempotent.
///
/// Storage operations must settle. Their cancellation functions are not called:
/// admitted saves and deletions complete even when the client shuts down.
pub type Task(value, error) =
  fn(fn(Result(value, error)) -> Nil) -> fn() -> Nil

pub type Queue {
  Queue(name: String, max_items: Int, max_bytes: Int)
}

pub type Row {
  Row(key: String, body: String)
}

/// Caller-owned persistence. Put must enforce limits atomically, accept an
/// identical retry, reject conflicting content and reply only after saving.
/// All operations must settle, including failures. The client never closes the
/// store; callers release resources only after pending operations have settled.
pub type Store(error) {
  Store(
    all: fn() -> Task(List(Row), error),
    put: fn(Row) -> Task(Nil, error),
    remove: fn(String) -> Task(Nil, error),
  )
}

/// Run synchronous work when the adapter invokes it, not during configuration.
/// For asynchronous IO supply a Task directly; no additional task framework is
/// needed. Side effects and failures belong inside work.
pub fn defer(work: fn() -> Result(value, error)) -> Task(value, error) {
  fn(reply) {
    reply(work())
    fn() { Nil }
  }
}

/// Construct a Storage with provider-specific errors and explicit diagnostics.
/// The client passes its validated queue settings to open. The returned store
/// and its underlying handles remain caller-owned.
pub fn storage(
  open: fn(Queue) -> Task(Store(error), error),
  explain: fn(error) -> String,
) -> client.Storage {
  storage_bridge(
    fn(name, items, bytes) { open(Queue(name, items, bytes)) },
    explain,
  )
}

/// Construct an upload adapter. Send receives the exact encoded batch and
/// returns the encoded acknowledgement. The client checks the receipt before
/// removing anything from storage. Deadline and shutdown invoke pending task
/// cancellation; a late callback cannot turn cancellation into success.
pub fn transport(
  send: fn(String) -> Task(String, error),
  explain: fn(error) -> String,
) -> client.Transport {
  transport_bridge(send, explain)
}

@external(javascript, "./adapter_ffi.mjs", "storage")
fn storage_bridge(
  open: fn(String, Int, Int) -> Task(Store(error), error),
  explain: fn(error) -> String,
) -> client.Storage

@external(javascript, "./adapter_ffi.mjs", "transport")
fn transport_bridge(
  send: fn(String) -> Task(String, error),
  explain: fn(error) -> String,
) -> client.Transport
