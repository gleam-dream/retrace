import collector_http
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import retrace
import retrace/wire
import retrace_collector.{Access}

fn serve() -> Int {
  collector_http.serve(Access([], None))
}

fn post(port: Int, headers: String, body: BitArray) -> collector_http.Reply {
  collector_http.send(port, [
    <<
      "POST /batches HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type: application/json\r\n",
      headers:utf8,
      "connection: close\r\n\r\n",
      body:bits,
    >>,
  ])
}

fn filler(bytes: Int) -> BitArray {
  list.repeat(<<"a">>, bytes) |> bit_array.concat
}

pub fn chunked_body_is_refused_before_its_first_chunk_is_read_test() {
  let size = int.to_base16(wire.max_bytes * 64)
  // Only the chunk-size line is sent: a reply proves no chunk data was awaited.
  let reply =
    post(serve(), "transfer-encoding: chunked\r\n", <<size:utf8, "\r\n">>)
  assert reply.status == 411
  assert collector_http.header(reply, "connection") == Ok("close")
}

pub fn any_transfer_encoding_is_refused_test() {
  let reply =
    post(serve(), "transfer-encoding: GZIP, Chunked\r\n", <<"0\r\n\r\n">>)
  assert reply.status == 411
}

pub fn post_without_content_length_is_refused_test() {
  assert post(serve(), "", <<>>).status == 411
}

pub fn declared_length_over_the_limit_is_refused_test() {
  let reply =
    post(
      serve(),
      "content-length: " <> int.to_string(wire.max_upload_bytes + 1) <> "\r\n",
      <<>>,
    )
  assert reply.status == 413
}

pub fn declared_length_at_the_limit_is_decoded_test() {
  let body = filler(wire.max_upload_bytes)
  let reply =
    post(
      serve(),
      "content-length: " <> int.to_string(wire.max_upload_bytes) <> "\r\n",
      body,
    )
  assert reply.status == 400
}

pub fn declared_length_body_within_the_limit_is_decoded_test() {
  let body = <<"{\"not\":\"a batch\"}">>
  let reply =
    post(
      serve(),
      "content-length: " <> int.to_string(bit_array.byte_size(body)) <> "\r\n",
      body,
    )
  assert reply.status == 400
}

pub fn batch_without_its_write_token_is_refused_test() {
  let session = wire.Session("chosen-by-client", "ada", "v1", "card-v1", "web")
  let assert Ok(#(recorder, checkpoint)) =
    retrace.start(wire.origin(session), "{}")
  let assert Ok(#(_, entry)) =
    retrace.record(recorder, wire.Event("tap", "{}"), elapsed_ms: 1)
  let body =
    wire.encode(wire.Batch(session, checkpoint, [entry]))
    |> bit_array.from_string
  let reply =
    post(
      serve(),
      "content-length: " <> int.to_string(bit_array.byte_size(body)) <> "\r\n",
      body,
    )
  assert reply.status == 400
}

pub fn session_with_invalid_metadata_is_not_opened_test() {
  let body = wire.encode_metadata(wire.Metadata("", "v1", "card-v1", "web"))
  let reply =
    collector_http.send(serve(), [
      <<
        "POST /sessions HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type: application/json\r\n",
        "content-length: ",
        int.to_string(string.byte_size(body)):utf8,
        "\r\nconnection: close\r\n\r\n",
        body:utf8,
      >>,
    ])
  assert reply.status == 400
}
