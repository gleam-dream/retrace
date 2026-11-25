//// Separate consumer for typed client operation contracts and recovery.

import retrace_frontend/client
import retrace_frontend/client/adapter

pub type ProviderError {
  Unavailable(reason: String)
  Refused(reason: String)
}

fn explain(error: ProviderError) -> String {
  case error {
    Unavailable(reason) -> "Provider: " <> reason
    Refused(reason) -> "Refused: " <> reason
  }
}

fn permanent(error: ProviderError) -> Bool {
  case error {
    Unavailable(_) -> False
    Refused(_) -> True
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

pub fn rejecting_transport(
  send: fn(String) -> adapter.Task(String, ProviderError),
) -> client.Transport {
  adapter.rejecting_transport(send, explain, permanent)
}

pub fn defaults() -> #(client.Storage, client.Transport) {
  #(client.browser_storage(), client.http_transport("http://127.0.0.1:4417"))
}

/// This task is built wholly in Gleam, without any native IO binding.
pub fn immediate_receipt(body: String) -> adapter.Task(String, ProviderError) {
  adapter.defer(fn() { Ok(body) })
}
