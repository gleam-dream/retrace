//// JavaScript delivery runtime. Capture and application updates remain separate.
//// The host owns start/stop; saved batches drain across runtime restarts.

import retrace/wire

pub type Client

pub type Config {
  Config(endpoint: String, queue_name: String, max_items: Int, max_bytes: Int)
}

pub type Status {
  Status(queued: Int, acknowledged: Int, detail: String)
}

pub fn start(config: Config, on_status: fn(Status) -> Nil) -> Client {
  start_runtime(
    config.endpoint,
    config.queue_name,
    config.max_items,
    config.max_bytes,
    fn(queued, acknowledged, detail) {
      on_status(Status(queued, acknowledged, detail))
    },
  )
}

/// Called after projection. The callback confirms local persistence, not upload.
/// Validation failure does not touch local storage or the network.
pub fn enqueue(
  client: Client,
  batch: wire.Batch,
  saved: fn(Result(Nil, String)) -> Nil,
) -> Nil {
  case wire.validate(batch) {
    Error(_) -> saved(Error("Invalid recording batch"))
    Ok(_) ->
      enqueue_runtime(client, wire.encode(batch), fn(ok, message) {
        case ok {
          True -> saved(Ok(Nil))
          False -> saved(Error(message))
        }
      })
  }
}

@external(javascript, "../client_ffi.mjs", "start")
fn start_runtime(
  endpoint: String,
  name: String,
  max_items: Int,
  max_bytes: Int,
  on_status: fn(Int, Int, String) -> Nil,
) -> Client

@external(javascript, "../client_ffi.mjs", "enqueue")
fn enqueue_runtime(
  client: Client,
  batch: String,
  saved: fn(Bool, String) -> Nil,
) -> Nil

@external(javascript, "../client_ffi.mjs", "stop")
pub fn stop(client: Client) -> Nil

@external(javascript, "../client_ffi.mjs", "retry")
pub fn retry(client: Client) -> Nil

/// A factory that opens caller-owned persistence. Use retrace_frontend/client/adapter
/// to construct one from Gleam operations, or provide an existing FFI adapter.
pub type Storage

/// An abortable upload returning acknowledgement JSON. Construct one through
/// retrace_frontend/client/adapter or use a provided transport. No reducer runs here.
pub type Transport

@external(javascript, "../client_ffi.mjs", "browserStorage")
pub fn browser_storage() -> Storage

@external(javascript, "../client_ffi.mjs", "httpTransport")
pub fn http_transport(endpoint: String) -> Transport

/// Advanced entrypoint; the caller selects persistence and upload policy.
pub fn start_with(
  config: Config,
  storage: Storage,
  transport: Transport,
  on_status: fn(Status) -> Nil,
) -> Client {
  start_with_runtime(
    config.queue_name,
    config.max_items,
    config.max_bytes,
    fn(queued, acknowledged, detail) {
      on_status(Status(queued, acknowledged, detail))
    },
    storage,
    transport,
  )
}

@external(javascript, "../client_ffi.mjs", "startWith")
fn start_with_runtime(
  name: String,
  max_items: Int,
  max_bytes: Int,
  on_status: fn(Int, Int, String) -> Nil,
  storage: Storage,
  transport: Transport,
) -> Client
