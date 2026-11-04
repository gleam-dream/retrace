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

A batch body larger than `wire.max_bytes` (1 MiB) is refused with `413`. A
declared `Content-Length` over the limit is refused before the body is read, and
a chunked body is streamed and refused once it passes the limit. mist still
buffers one transfer chunk whole before handing it over, so a single oversized
chunk is held in memory until it arrives.

From the repository's Nix shell, run `bash dev/services.sh` to start its local
services and collector. Run `python3 dev/backend-check.py` to check ingestion and
archive readback against those services.

An external development host can use the collector through Git+path alongside
the published packages. Replace `RETRACE_COMMIT_SHA` with a verified commit; the
collector's parent dependencies resolve from Hex.

```toml
[dependencies]
retrace = ">= 0.1.0 and < 0.2.0"
retrace_server = ">= 0.1.0 and < 0.2.0"
retrace_collector = { git = "https://github.com/gleam-dream/retrace.git", ref = "RETRACE_COMMIT_SHA", path = "support/collector" }
```
