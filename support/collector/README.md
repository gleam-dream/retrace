# Collector host

[![CI](https://github.com/gleam-dream/retrace/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/retrace/actions/workflows/ci.yml)
[![retrace on Hex](https://img.shields.io/hexpm/v/retrace?label=Hex%3A%20retrace)](https://hex.pm/packages/retrace)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

An unpublished development host for the collector protocol, backed by PostgreSQL
and an S3-compatible store. It binds to loopback and has no tenant isolation.
Applications own hosted deployment policy.

## Access

Binding to loopback stops other machines, not web pages open in the developer's
browser. The collector therefore refuses:

- a request whose `Host` is not `127.0.0.1`, `localhost` or `[::1]`, which
  stops DNS-rebound names;
- a request whose `Origin` is not in the allow-list, with `403` and no CORS
  headers. A preflight is answered only for an allowed origin, and an allowed
  origin is echoed exactly in `access-control-allow-origin`;
- with a token configured, every request except an allowed preflight that lacks
  `Authorization: Bearer <token>`, with `401`. The token is compared in
  constant time.

Requests without an `Origin`, such as `curl` and `dev/backend-check.py`, need
only the token when one is set.

| Variable                  | Default                                                                                                                               |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `RETRACE_ALLOWED_ORIGINS` | The example dev servers on `127.0.0.1` and `localhost` ports 5190, 5191, 5193 and 5194, `tauri://localhost`, `http://tauri.localhost` |
| `RETRACE_COLLECTOR_TOKEN` | Unset: every route is open to the allowed origins and to local processes, and the collector logs a warning at startup                 |

`RETRACE_ALLOWED_ORIGINS` is a comma-separated list of exact origins and
replaces the defaults; it has no wildcard, and an empty value admits no browser
origin.

The packaged `client.http_transport` and `viewer.collector` send no
`Authorization` header, so they work with the default, token-less collector
only. With a token set, submit through `client.start_with` and a transport from
`client/adapter.transport`, read through a custom `viewer.Source`, or put a
same-origin proxy that adds the header in front of the collector.

## Body limit

A batch submission must declare its length. A request carrying any
`Transfer-Encoding` or no `Content-Length` is refused with `411` before its body
is read, because mist buffers each transfer chunk whole; the packaged adapters
always send `Content-Length`. A declared length over `wire.max_bytes` (1 MiB) is
refused with `413` before the body is read. As a second defence, the body is
streamed and refused with `413` if more bytes arrive than the limit allows.

## Known limitations

- mist 6.0.3 accepts HTTP/2 prior-knowledge connections on the same port and
  buffers their DATA frames before the collector's guard can refuse the stream,
  so a local process can consume memory before any origin or token check.
  Browsers cannot open such a connection. Closing it needs an upstream mist
  option to disable HTTP/2.
- mist keeps only the last value of a repeated request header, so the collector
  cannot detect several `Origin` or `Host` headers and judges the last one. A
  browser sends one `Origin`, which it does not let page scripts set.
