import collector_http
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None}
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
      "content-length: " <> int.to_string(wire.max_bytes + 1) <> "\r\n",
      <<>>,
    )
  assert reply.status == 413
}

pub fn declared_length_at_the_limit_is_decoded_test() {
  let body = filler(wire.max_bytes)
  let reply =
    post(
      serve(),
      "content-length: " <> int.to_string(wire.max_bytes) <> "\r\n",
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
