# Retire superseded experiments

<a id="adr-0004"></a>

On 2026-10-10 the user requested cleanup before further adoption-API work.
The live membership and inventory examples plus the shared Lustre companion
supersede the synthetic two-edition replay experiment and unused membership
Time Travel/history glue. Those sources are archived locally, not maintained as
alternate implementations. The vendor fork and its revision/license provenance
remain available; current examples no longer depend on it. This supersedes the
optional example-inspector dependency described in ADR 0001.

Simulator capture is retained regression evidence, so it moves from prototypes
to dev/simulator with its executable inputs. Completed delivery briefs move to
docs/history, explicitly outside current design authority. Recorded sessions,
local database/object storage and retained historical replay artifacts are kept.

The adoption guide describes current work and a proposed Gleam-first direction.
No new instrumentation wrapper or viewer package is declared implemented by this
cleanup. Standard paths should eventually require no application-authored FFI;
application privacy, deterministic replay semantics and deployment ownership
remain explicit decisions.
