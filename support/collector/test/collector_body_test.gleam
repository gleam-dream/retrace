import collector_http
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None}
import retrace/wire
import retrace_collector.{Access}

fn chunked_post(port: Int, chunks: List(BitArray)) -> collector_http.Reply {
  let head = <<
    "POST /batches HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n",
  >>
  let framed =
    list.map(chunks, fn(chunk) {
      let size = int.to_base16(bit_array.byte_size(chunk))
      <<size:utf8, "\r\n", chunk:bits, "\r\n">>
    })
  collector_http.send(port, [head, ..list.append(framed, [<<"0\r\n\r\n">>])])
}

fn filler(bytes: Int) -> BitArray {
  list.repeat(<<"a">>, bytes) |> bit_array.concat
}

pub fn chunked_body_over_the_limit_is_refused_as_oversized_test() {
  let port = collector_http.serve(Access([], None))
  let chunk = filler(65_536)
  let count = wire.max_bytes / 65_536 + 1
  let reply = chunked_post(port, list.repeat(chunk, count))
  assert reply.status == 413
}

pub fn chunked_body_one_byte_over_the_limit_is_refused_test() {
  let port = collector_http.serve(Access([], None))
  let reply = chunked_post(port, [filler(wire.max_bytes), <<"a">>])
  assert reply.status == 413
}

pub fn chunked_body_within_the_limit_is_decoded_test() {
  let port = collector_http.serve(Access([], None))
  let reply = chunked_post(port, [<<"{\"not\":">>, <<"\"a batch\"}">>])
  assert reply.status == 400
}

pub fn declared_length_over_the_limit_is_refused_test() {
  let port = collector_http.serve(Access([], None))
  let reply =
    collector_http.send(port, [
      <<
        "POST /batches HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: ",
        { int.to_string(wire.max_bytes + 1) }:utf8,
        "\r\nconnection: close\r\n\r\n",
      >>,
    ])
  assert reply.status == 413
}
