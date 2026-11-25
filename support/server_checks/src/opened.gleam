//// Sessions for the checks, opened through the public server API.

import pog
import retrace/wire
import retrace_server as server

/// Open a session with the checks' counter contract.
pub fn grant(db: pog.Connection, user_ref: String) -> wire.Grant {
  let assert Ok(grant) =
    server.open(
      db,
      wire.Metadata(user_ref, "counter-v1", "counter-v1", "erlang"),
    )
  grant
}

/// The object key of the batch that starts at `start`.
pub fn key(session: wire.Session, start: String) -> String {
  "sessions/" <> session.id <> "/" <> start <> ".json.gz"
}
