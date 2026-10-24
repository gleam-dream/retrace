# Isolate hosted replay artifacts in an opaque sandboxed frame

<a id="adr-0014"></a>

Recorded on 2026-10-17. The opaque frame is exercised by `dev/opaque-frame-check.mjs` and `packages/retrace_frontend/test/channel.test.mjs`.

## Decision

An authenticated hosted viewer opts into an opaque frame mode. The application
assembles a self-contained document from verified immutable bytes, and the
viewer mounts it with scripts only, without same-origin or navigation
capabilities, and without referrers. Messages require the exact window, origin,
protocol version and a per-load nonce in the frame name.

## Rationale

Default artifacts are trusted same-origin code. A hosted viewer cannot trust
recording content, query parameters, referrers or messages to name the parent,
so the assembler injects one fixed trusted parent origin. An opaque origin
cannot be named, so outgoing delivery uses a wildcard target while inbound trust
still demands the exact window, null origin and nonce.

## Consequences

The channel and the sandbox do not certify that an application's reducer is
pure. The assembler must embed all assets and apply a content security policy
that blocks network access. A noncanonical parent origin is rejected at mount.
Default local frames keep their same-origin behavior.
