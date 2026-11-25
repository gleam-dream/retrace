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

pub fn upload_carries_the_write_token_outside_the_batch_test() {
  let metadata = wire.Metadata("ada", "v1", "card-v1", "web")
  let session = wire.session("issued-1", metadata)
  assert wire.metadata(session) == metadata
  let assert Ok(#(recorder, checkpoint)) =
    retrace.start(wire.origin(session), "{}")
  let assert Ok(#(_, first)) =
    retrace.record(recorder, wire.Event("tap", "{}"), elapsed_ms: 1)
  let upload = wire.Upload("token-1", wire.Batch(session, checkpoint, [first]))
  assert wire.decode_upload(wire.encode_upload(upload)) == Ok(upload)
  // A stored or read batch never contains the token.
  assert wire.decode_upload(wire.encode(upload.batch))
    == Error(wire.MalformedEnvelope)
  assert wire.decode_upload(
      wire.encode_upload(wire.Upload("../no", upload.batch)),
    )
    == Error(wire.MalformedEnvelope)
}

pub fn grant_and_metadata_roundtrip_test() {
  let metadata = wire.Metadata("ada", "v1", "card-v1", "web")
  assert wire.decode_metadata(wire.encode_metadata(metadata)) == Ok(metadata)
  assert wire.decode_metadata(wire.encode_metadata(
      wire.Metadata(..metadata, user_ref: ""),
    ))
    == Error(wire.InvalidSession)
  let grant = wire.Grant(wire.session("issued-1", metadata), "token-1")
  assert wire.decode_grant(wire.encode_grant(grant)) == Ok(grant)
  let forged = wire.Grant(wire.session("../x", metadata), "token-1")
  assert wire.decode_grant(wire.encode_grant(forged))
    == Error(wire.InvalidSession)
}
