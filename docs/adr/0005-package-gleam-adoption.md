# Package the Gleam adoption path

<a id="adr-0005"></a>

On 2026-10-10 the user approved implementing capture and viewer composition
and permanently deleting retired experiments. This supersedes ADR 0004's local
archive retention and the example-only viewer ownership in ADR 0002.

The portable core stays independent of Lustre and browsers. An optional capture
module composes the existing client with application-owned safe codecs; the
application continues to own its update, effects and runtime lifetime. A separate
viewer package exposes typed callbacks and defaults while retaining the tested
JavaScript playback implementation internally. Forcing the DOM implementation
into Gleam would not itself reduce consumer work.

Both examples use these interfaces: membership uses HTTP and immutable artifacts;
inventory supplies a local archive and a custom resolver. Custom asynchronous
readers return cancellation, so replacing requests and disposal have explicit
ownership. The standard path needs no application-authored telemetry FFI. Build
metadata and business-specific native integrations remain application concerns.

Retired sources, local archive copies and completed delivery briefs are deleted.
ADRs, upstream attribution, Simulator regression inputs, recordings and historical
application artifacts remain. No upstream PR or publication is part of this work.
