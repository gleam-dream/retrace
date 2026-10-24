# Distribute the packages from Git at one shared revision

<a id="adr-0011"></a>

Recorded on 2026-10-17. The install snippets and release checks are executable: `dev/git-consumer-check.sh` builds independent consumers of the committed revision, and `dev/readme.test.mjs` checks the README dependency snippets (ADR 0017).

## Decision

The portable core, the frontend and the server install as source from the
Retrace Git repository, and every Retrace dependency of an application pins the
same tag or full commit SHA. No package is published to Hex. A release is an
experimental prerelease of a checked commit with fixed tags.

## Rationale

The subpackages resolve the core through a relative dependency inside one
checkout, so a mixed revision would pair incompatible packages. Hex publication
requires packaging the internal path dependencies appropriately and is a
separate decision. Pinning a commit gives an application an immutable source.

## Consequences

Two gates verify a release. The repository gate builds and tests everything
locally, and a separate consumer gate creates temporary projects outside the
repository and installs the committed revision. After a push, the same consumer
gate installs the remote source to verify what a user receives. Neither gate
exercises a browser, native shell, database or cloud service, and each kind of
runtime evidence is reported separately.
