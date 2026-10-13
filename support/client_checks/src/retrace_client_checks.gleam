//// Separate consumer for typed client operation contracts and recovery.

import retrace_frontend/client
import retrace_frontend/client/adapter

pub type ProviderError {
  Unavailable(reason: String)
}

fn explain(error: ProviderError) -> String {
  case error {
    Unavailable(reason) -> "Provider: " <> reason
  }
}

pub fn storage(
  open: fn(adapter.Queue) ->
    adapter.Task(adapter.Store(ProviderError), ProviderError),
) -> client.Storage {
  adapter.storage(open, explain)
}

pub fn transport(
  send: fn(String) -> adapter.Task(String, ProviderError),
) -> client.Transport {
  adapter.transport(send, explain)
}

pub fn defaults() -> #(client.Storage, client.Transport) {
  #(client.browser_storage(), client.http_transport("http://127.0.0.1:4417"))
}

/// This task is built wholly in Gleam, without any native IO binding.
pub fn immediate_receipt(body: String) -> adapter.Task(String, ProviderError) {
  adapter.defer(fn() { Ok(body) })
}
