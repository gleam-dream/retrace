import collector_http.{header, request}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import retrace_collector.{Access}

const app = "http://127.0.0.1:5190"

fn open() -> Int {
  collector_http.serve(Access([app], None))
}

fn guarded() -> Int {
  collector_http.serve(Access([app], Some("collector-test-token")))
}

pub fn development_origins_cover_the_example_dev_servers_test() {
  let origins = retrace_collector.development_origins
  assert list.contains(origins, "http://127.0.0.1:5190")
  assert list.contains(origins, "http://127.0.0.1:5191")
  assert list.contains(origins, "http://127.0.0.1:5193")
  assert !list.contains(origins, "*")
}

pub fn foreign_origin_gets_no_cors_grant_and_is_refused_test() {
  let reply =
    request(open(), "GET", "/sessions", [#("origin", "https://evil.example")])
  assert header(reply, "access-control-allow-origin") == Error(Nil)
  assert reply.status == 403
}

pub fn foreign_origin_cannot_submit_batches_test() {
  let reply =
    request(open(), "POST", "/batches", [
      #("origin", "https://evil.example"),
      #("content-type", "text/plain"),
      #("content-length", "0"),
    ])
  assert header(reply, "access-control-allow-origin") == Error(Nil)
  assert reply.status == 403
}

pub fn allowed_origin_is_echoed_exactly_test() {
  let reply = request(open(), "GET", "/health", [#("origin", app)])
  assert reply.status == 200
  assert header(reply, "access-control-allow-origin") == Ok(app)
  assert header(reply, "vary") == Ok("Origin")
}

pub fn preflight_is_answered_only_for_allowed_origins_test() {
  let port = open()
  let allowed =
    request(port, "OPTIONS", "/batches", [
      #("origin", app),
      #("access-control-request-method", "POST"),
    ])
  assert allowed.status == 204
  assert header(allowed, "access-control-allow-origin") == Ok(app)
  let assert Ok(headers) = header(allowed, "access-control-allow-headers")
  assert string.contains(headers, "authorization")
  let foreign =
    request(port, "OPTIONS", "/batches", [
      #("origin", "https://evil.example"),
      #("access-control-request-method", "POST"),
    ])
  assert header(foreign, "access-control-allow-origin") == Error(Nil)
  assert foreign.status == 403
}

pub fn request_without_origin_reaches_open_collector_test() {
  assert request(open(), "GET", "/health", []).status == 200
}

pub fn rebound_host_is_refused_test() {
  let port = open()
  let reply =
    collector_http.send(port, [
      <<
        "GET /sessions HTTP/1.1\r\nhost: rebound.example:4417\r\nconnection: close\r\n\r\n",
      >>,
    ])
  assert reply.status == 403
}

pub fn token_is_required_on_every_route_test() {
  let port = guarded()
  assert request(port, "GET", "/health", []).status == 401
  assert request(port, "GET", "/sessions", []).status == 401
  assert request(port, "POST", "/archive", [#("content-length", "0")]).status
    == 401
}

pub fn wrong_token_is_refused_test() {
  let port = guarded()
  let reply =
    request(port, "GET", "/health", [
      #("authorization", "Bearer collector-test-tokem"),
    ])
  assert reply.status == 401
  assert header(reply, "www-authenticate") == Ok("Bearer")
  assert request(port, "GET", "/health", [
      #("authorization", "Basic collector-test-token"),
    ]).status
    == 401
}

pub fn right_token_is_accepted_test() {
  let reply =
    request(guarded(), "GET", "/health", [
      #("authorization", "Bearer collector-test-token"),
      #("origin", app),
    ])
  assert reply.status == 200
  assert header(reply, "access-control-allow-origin") == Ok(app)
}

pub fn preflight_needs_no_token_test() {
  let reply =
    request(guarded(), "OPTIONS", "/sessions", [
      #("origin", app),
      #("access-control-request-method", "GET"),
      #("access-control-request-headers", "authorization"),
    ])
  assert reply.status == 204
}

fn with_host(port: Int, host: String) -> Int {
  collector_http.send(port, [
    <<
      "GET /health HTTP/1.1\r\nhost: ",
      host:utf8,
      "\r\nconnection: close\r\n\r\n",
    >>,
  ]).status
}

pub fn host_must_be_a_whole_loopback_authority_test() {
  let port = open()
  assert with_host(port, "[::1].evil.example") == 403
  assert with_host(port, "localhost:4417:evil") == 403
  assert with_host(port, "127.0.0.1.evil.example:4417") == 403
  assert with_host(port, "localhost:") == 403
  assert with_host(port, "localhost:44a7") == 403
  assert with_host(port, "[::1]:4417x") == 403
}

pub fn loopback_authorities_are_accepted_test() {
  let port = open()
  assert with_host(port, "LocalHost") == 200
  assert with_host(port, "127.0.0.1:4417") == 200
  assert with_host(port, "[::1]:4417") == 200
  assert with_host(port, "[::1]") == 200
}
