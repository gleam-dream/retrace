# Publish the three packages to Hex

<a id="adr-0020"></a>

Recorded on 2026-10-26. Supersedes the Git-only distribution decision in
[ADR 0011](0011-distribute-from-git-with-one-shared-revision.md#adr-0011).

## Decision

Publish `retrace`, `retrace_frontend` and `retrace_server` as separate Hex packages
with one coordinated version. Applications declare only the packages they import
and retain the resolved versions in `manifest.toml`.

Published frontend and server packages depend on the core through Hex version
requirements. Repository path dependencies remain useful for development; they
must be reconciled for the release before exporting or publishing a package.

## Rationale

Git-only distribution kept the three packages in one source checkout. Hex
provides normal Gleam installation and dependency resolution while retaining the
portable, frontend and backend package boundaries. Coordinated versions and
compatible core requirements keep those packages aligned.

## Consequences

Preserve existing Git tags. A release uses a checked source commit and verifies
the published Hex archives through independent consumers. The retained Git
consumer check qualifies source installation, not a Hex release. Browser, native,
database and cloud evidence retain their existing scope.

The packages remain experimental; publication does not establish runtime
guarantees beyond the checks actually executed.
