# Load recordings progressively through whole-batch windows

<a id="adr-0013"></a>

Recorded on 2026-10-17. The progressive mode is exercised by `dev/progressive-viewer-browser-check.mjs` and `packages/retrace_frontend/test/range.test.mjs`.

## Decision

The JavaScript viewer offers an opt-in progressive mode. It publishes windows of
whole original batches, targeting five minutes, 256 entries or one MiB, and
extends the validated prefix through the existing load and absolute-sequence
seek protocol. The typed mount keeps loading one complete bounded range.

## Rationale

A batch is the indivisible unit of integrity, so a window never splits one and a
single long batch can exceed a time or entry target. Reusing the load and seek
protocol means historical artifacts need no rebuild. Reading one page ahead
overlaps fetching with reconstruction without concurrent reads or frame updates.

## Consequences

The first valid page is playable at once, and the timeline claims only the
interval that has loaded. A later read failure keeps the prefix playable with a
retry from the uncommitted cursor. Entry and byte budgets cover the whole
recording including prefetched data, and nothing is cached across selection.
Lazy seeking and live tailing remain undesigned.
