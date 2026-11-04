//// Serves the collector handler on an ephemeral loopback port and exchanges
//// raw HTTP/1.1 messages with it. No database or object store is reached by
//// the routes these tests exercise.

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import mist
import pog
import retrace_collector.{type Access}
import retrace_server/directory

pub type Reply {
  Reply(status: Int, headers: List(#(String, String)))
}

@external(erlang, "collector_test_ffi", "exchange")
fn exchange(port: Int, pieces: List(BitArray)) -> Result(BitArray, Nil)

pub fn serve(access: Access) -> Int {
  let ports = process.new_subject()
  let db = pog.named_connection(process.new_name("retrace-collector-test-db"))
  let store = directory.store("build/collector-test-objects")
  let assert Ok(_) =
    mist.new(retrace_collector.handler(access, db, store))
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
  let assert Ok(port) = process.receive(ports, 5000)
  port
}

pub fn send(port: Int, pieces: List(BitArray)) -> Reply {
  let assert Ok(raw) = exchange(port, pieces)
  let assert Ok(text) = bit_array.to_string(raw)
  let assert Ok(#(head, _body)) = string.split_once(text, "\r\n\r\n")
  let assert [status_line, ..lines] = string.split(head, "\r\n")
  let assert [_, code, ..] = string.split(status_line, " ")
  let assert Ok(status) = int.parse(code)
  Reply(
    status,
    list.filter_map(lines, fn(line) {
      string.split_once(line, ":")
      |> result.map(fn(pair) {
        #(string.lowercase(pair.0), string.trim(pair.1))
      })
    }),
  )
}

/// A request without a body; each header is written as given.
pub fn request(
  port: Int,
  method: String,
  path: String,
  headers: List(#(String, String)),
) -> Reply {
  send(port, [
    bit_array.from_string(
      method
      <> " "
      <> path
      <> " HTTP/1.1\r\nhost: 127.0.0.1:"
      <> int.to_string(port)
      <> "\r\n"
      <> header_lines(headers)
      <> "connection: close\r\n\r\n",
    ),
  ])
}

pub fn header_lines(headers: List(#(String, String))) -> String {
  list.map(headers, fn(pair) { pair.0 <> ": " <> pair.1 <> "\r\n" })
  |> string.concat
}

pub fn header(reply: Reply, name: String) -> Result(String, Nil) {
  list.key_find(reply.headers, name)
}
