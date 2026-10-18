# Retire superseded experiments and keep their attribution

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
a history directory, explicitly outside current design authority. Recorded sessions,
local database/object storage and retained historical replay artifacts are kept.

The adoption material of that period described current work and a proposed Gleam-first
direction; it now lives as compiled examples (ADR 0017). No new instrumentation wrapper
or viewer package is declared implemented by this cleanup. Standard paths should eventually require no application-authored FFI;
application privacy, deterministic replay semantics and deployment ownership
remain explicit decisions.

The retired Time Travel sources are removed. The attribution notice retains the
upstream repository and base revision, the evaluated fork and its revision, the
author and the MIT license. Time Travel is not a runtime dependency, and no
upstream pull request was opened.
