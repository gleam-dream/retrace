# Restrict the development collector to allowed origins

<a id="adr-0021"></a>

Recorded on 2026-11-03. Amends the access statement in
[ADR 0018](0018-treat-the-collector-routes-as-a-supported-contract.md#adr-0018).

## Decision

The development collector refuses requests whose `Host` is not a loopback name and
requests whose `Origin` is outside an allow-list, without CORS headers. It answers a
preflight only for an allowed origin and echoes that origin exactly. The allow-list
defaults to the example dev servers and Tauri builds and is replaced by
`RETRACE_ALLOWED_ORIGINS`. When `RETRACE_COLLECTOR_TOKEN` is set, every request except
an allowed preflight needs that bearer token. Without it the collector warns at startup
and stays open to allowed origins and local processes.

## Rationale

Loopback binding stops other machines, not pages open in the developer's browser. A
wildcard `access-control-allow-origin` let any site list sessions, read every recording
and submit batches. Refusing a foreign origin outright, not only withholding the CORS
grant, also stops cross-site form and `no-cors` submissions, and the host check stops a
rebound DNS name from reaching the collector as its own origin.

## Alternatives

Require a token always. This breaks the zero-configuration examples, because the packaged
`http_transport` and `viewer.collector` send no headers. Changing those public adapters
belongs to the hosted-deployment ruling.

## Consequences

Authentication and tenant isolation for a hosted collector remain with the
hosted-deployment ruling. A token-protected development collector needs a custom client
transport, a custom viewer source or a proxy that adds the header. The collector tests
in `support/collector/test` check the origin, host and token rules.
