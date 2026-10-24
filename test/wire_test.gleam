import retrace
import retrace/wire

pub fn batch_roundtrip_and_rejection_test() {
  let session = wire.Session("test-1", "ada", "v1", "card-v1", "web")
  let assert Ok(#(recorder, checkpoint)) =
    retrace.start(wire.origin(session), "{}")
  let assert Ok(#(_, first)) =
    retrace.record(recorder, wire.Event("tap", "{}"), elapsed_ms: 1)
  let batch = wire.Batch(session, checkpoint, [first])
  assert wire.decode_batch(wire.encode(batch)) == Ok(batch)
  assert wire.validate(wire.Batch(..batch, entries: []))
    == Error(wire.EmptyBatch)
  let wrong = retrace.Entry(..first, sequence: 2)
  assert wire.validate(wire.Batch(..batch, entries: [wrong]))
    == Error(wire.InvalidHistory(retrace.OutOfOrder(1, 2)))
  assert wire.decode_batch("{}") == Error(wire.MalformedEnvelope)
  assert wire.valid_id("../escape") == False
}
