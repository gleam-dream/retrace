# Keep build, artifact and source identities separate

<a id="adr-0010"></a>

Recorded on 2026-10-17. The recipe is executable: `examples/advanced/dev/build.mjs` and `identity.mjs`, run by `examples/advanced/dev/build.test.mjs` (ADR 0017).

## Decision

A recording carries a build identity allocated once per live and replay pairing
by the application pipeline. The source revision is provenance, and the artifact
digest is computed after bundling and stored in a manifest outside the bundle.
Retrace defines no builder package, manifest schema or artifact registry.

## Rationale

One source revision can produce different binaries through configuration,
dependency or toolchain changes, so the revision cannot identify a build. A
bundle cannot embed its own final digest without changing that digest. A commit
cannot contain its own hash, so metadata is generated into ignored build output
after checkout.

A cached web page or an older mobile installation keeps executing its original
code, so the identity travels offline inside the application and is never
fetched from a mutable current-version endpoint. An update starts a new session
under its new identity, and batches queued earlier keep their original metadata.

## Consequences

A missing or incompatible artifact refuses playback, and the host never loads
the newest renderer silently. Artifacts are retained for as long as their
recordings need them, including after a rollback. The maintained example
records source provenance but hashes, signs and verifies nothing, and digest
verification with atomic manifest publication stays a deployment recommendation.
Artifacts execute code, so a production host defines its own publication,
isolation and integrity policy.
