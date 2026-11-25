//// Only the writer a session was issued to can append to it.

import opened
import pog
import retrace
import retrace/wire
import retrace_server as server

pub fn run(db: pog.Connection) -> Nil {
  let grant = opened.grant(db, "victim-user")
  let session = grant.session
  let assert Ok(#(recorder, checkpoint)) =
    retrace.start(wire.origin(session), "0")
  let assert Ok(#(recorder, first)) =
    retrace.record(recorder, wire.Event("Add", "1"), 5)
  let assert Ok(1) =
    server.accept(
      db,
      wire.Upload(grant.token, wire.Batch(session, checkpoint, [first])),
    )
  // Anyone who can read the session knows its id, head and metadata.
  let next = retrace.checkpoint(recorder, "1")
  let assert Ok(#(_, forged)) =
    retrace.record(recorder, wire.Event("Add", "1000"), 6)
  let forged = wire.Batch(session, next, [forged])
  let other = opened.grant(db, "attacker")
  let assert Error(server.Unauthorized) =
    server.accept(db, wire.Upload(other.token, forged))
  let assert Error(server.Unauthorized) =
    server.accept(db, wire.Upload("guessed", forged))
  // A session that was never opened here cannot be created by a batch.
  let unopened = wire.Session(..session, id: "chosen-by-client")
  let assert Ok(#(fresh, start)) = retrace.start(wire.origin(unopened), "0")
  let assert Ok(#(_, entry)) = retrace.record(fresh, wire.Event("Add", "1"), 5)
  let assert Error(server.Unauthorized) =
    server.accept(
      db,
      wire.Upload(grant.token, wire.Batch(unopened, start, [entry])),
    )
  // The refused batches left the session where its writer expects it.
  let assert Ok(#(_, genuine)) =
    retrace.record(recorder, wire.Event("Add", "2"), 6)
  let assert Ok(2) =
    server.accept(
      db,
      wire.Upload(grant.token, wire.Batch(session, next, [genuine])),
    )
  let assert Error(server.InvalidBatch(wire.InvalidSession)) =
    server.open(db, wire.Metadata("", "b", "c", "p"))
  Nil
}
