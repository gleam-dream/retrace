# Consolidate frontend distribution

<a id="adr-0008"></a>

On 2026-10-11 the user chose Core + frontend + server after comparing a single
package, three packages, and the existing five-package layout.

## Decision

Keep portable `retrace` and BEAM `retrace_server`. Consolidate `retrace_client`,
`retrace_lustre` and `retrace_viewer` into JavaScript `retrace_frontend`.
Use client, capture, replay, viewport and viewer modules under its namespace.
The unpublished old packages are removed rather than maintained as aliases.
This supersedes the distribution split in ADR 0005 while preserving its runtime
ownership and extension contracts and the typed adapters added in ADR 0007.

## Consequences

An application declares one frontend integration dependency. Delivery-only and
viewer-only consumers also resolve Lustre; that dependency coupling is accepted
in exchange for simpler adoption and fewer package versions to coordinate.
The portable core and server do not acquire frontend dependencies.

Package consolidation does not combine live application, historical frame and
viewer entrypoints, or start resources automatically. Callers still own runtime
lifetimes, safe projections, native setup and artifact selection. Custom storage,
transport, source and resolver callbacks remain independently replaceable.
Wire formats, replay protocol, build identity and historical artifacts are unchanged.
No analytics, archive or build-metadata framework is introduced.

## Validation

Both maintained examples and the separate typed-adapter consumer use the new
package and module paths. Existing reconstruction, adapter failure/cancellation,
viewer and browser tests exercise their retained behavior. Browser-only bundling
continues to reject native plugin imports. Native runtime testing remains distinct
from JavaScript build and browser evidence.
