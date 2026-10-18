# Show usage as compiled, runnable examples

<a id="adr-0017"></a>

Recorded on 2026-10-17.

## Decision

Usage lives as code that compiles and runs, not as a prose guide. Each usage topic has
source in an example or consumer and a check that fails when the library's API or
behavior moves. The topics are the replayable definition, capture and delivery with
replay of the delivered batches, the historical replay frame, the viewer, custom storage
and upload and viewer source in Gleam, build identity and preserved artifacts, and
installation from Git. `examples/README.md` lists each topic with its source and check.

README Gleam snippets are verbatim excerpts of that compiled source, joined by `// ...`
where they skip code, and README Git dependency snippets name the real packages, paths
and repository. `dev/readme.test.mjs` enforces both. Retrace keeps no changelog, and it
has no external oracle or benchmark suite, so it keeps no oracle or benchmark document.

## Context

The retired guides described adoption, build identity, installation, the viewer and device
testing in prose. Prose cannot fail when a signature changes, so the guides drifted from
the code they described. The same material as executable examples is checked by the
repository gate and the services checks, and the design states the rules while the ADRs
keep the reasoning.

## Consequences

An example that stops compiling or running fails `bash dev/check.sh` instead of misleading a
reader. A new usage topic adds code and a check, not a page. Topics that need a browser,
database or device stay in their own evidence classes, and the topic table names the lane.
