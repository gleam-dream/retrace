//// Separate consumer for typed client operation contracts and recovery.

import gleam/result
import retrace/wire
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

/// Sessions are opened by a provider written in Gleam that issues one fixed id.
pub fn transport(
  send: fn(String) -> adapter.Task(String, ProviderError),
) -> client.Transport {
  adapter.transport(open: open, send: send, explain: explain)
}

fn open(metadata: String) -> adapter.Task(String, ProviderError) {
  adapter.defer(fn() {
    use metadata <- result.map(
      wire.decode_metadata(metadata)
      |> result.replace_error(Unavailable("invalid metadata")),
    )
    wire.encode_grant(wire.Grant(
      wire.session("typed-session", metadata),
      "typed-token",
    ))
  })
}

pub fn defaults() -> #(client.Storage, client.Transport) {
  #(client.browser_storage(), client.http_transport("http://127.0.0.1:4417"))
}

/// This task is built wholly in Gleam, without any native IO binding.
pub fn immediate_receipt(body: String) -> adapter.Task(String, ProviderError) {
  adapter.defer(fn() { Ok(body) })
}
