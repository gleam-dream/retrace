# Associate recordings with application builds

This guide recommends an application-owned build and release workflow. The
[maintained build script](../examples/advanced/dev/build.mjs) creates matching live
and replay bundles. See [viewer integration](replay-viewer.md) for local use.
Retrace does not provide a builder package or production artifact registry.
The wire format already carries `Session.build` and `Session.contract`.

## Keep source, build and artifact identities separate

| Value           | Owner                | Purpose                                                                      |
| --------------- | -------------------- | ---------------------------------------------------------------------------- |
| Source revision | Git checkout         | Full commit SHA identifying the committed source                             |
| Build ID        | Application pipeline | Unique identity for one application build and its recording/replay pairing   |
| Replay contract | Application          | Compatibility identifier for checkpoints, messages and reducer semantics     |
| Host protocol   | Replay integration   | Version of commands and responses between the preview host and artifact      |
| Artifact digest | Application pipeline | Content identity of the completed replay bundle, including styles and assets |

CI starts from a commit that already exists. Read its revision after checkout,
then generate metadata into ignored build outputs. Do not commit that metadata
back into the source tree. No metaprogramming or self-referential commit is needed.

Allocate a build ID before bundling. A CI run ID plus attempt and platform can
supply one; a local development run can use a random ID. One source revision can
produce different binaries because of configuration, dependency or toolchain
changes. Keep the revision as provenance rather than using it as the sole build ID.

Compute the artifact digest after bundling. Store it in a release manifest outside
the hashed artifact. A bundle cannot include its own final digest as ordinary
embedded metadata without changing that digest.

## Pass identity through the application bootstrap

The maintained example's build script chooses `RETRACE_BUILD_ID`, or allocates a
unique local ID, before bundling. Vite injects `__RETRACE_BUILD__` into both live
and historical entrypoints. One tiny application FFI function exposes that value
to Gleam. Source revision and dirty status are stored in the artifact manifest.

A consuming application can instead accept a build ID as a Gleam startup argument.
Its generated JavaScript bootstrap calls that compiled function with the ID, using
`JSON.stringify` to encode the value safely. This keeps application types in Gleam
and does not require constructing generated Gleam records from JavaScript.
A generated Gleam source module is also possible if created before compilation.

The replay entrypoint calls `retrace_frontend/replay.mount` with the same build ID used in
`wire.Session.build`. See [the maintained replay entrypoint](../examples/advanced/src/retrace_example/frame.gleam).
Environment variables, HTML entrypoints and bundling remain application build
configuration; no checked-in file needs to contain its own future commit hash.

## Build, preserve and release in order

1. Check out the intended revision and restore locked dependencies and toolchains.
   Record the actual checkout SHA, replay-relevant configuration and platform.
   Release builds should reject unexpected dirty source; development builds should
   identify it explicitly. A dirty flag identifies uncertainty, not the changed bytes.
2. Allocate one build ID per application/replay pairing. Pass it to the live and
   replay bootstraps. Bundle dependencies, CSS, fonts and other required assets
   with the replay entrypoint, or reference preserved immutable assets.
3. Exercise a recording produced by that build in its replay artifact. Include
   external effect results as recorded messages; the replay reducer and view must
   not invoke live effects.
4. Compute the artifact digest and upload its immutable bytes. Preserve the exact
   built output rather than relying on rebuilding an old checkout later.
5. Register an immutable release manifest mapping the build ID to the artifact.
   An identical retry may succeed; different content under that ID must fail.
   A hosted registry needs atomic create-if-absent or equivalent coordination.
6. Verify the uploaded artifact is retrievable, then release the already-built
   application. Promote those bytes between environments without rebuilding them.

A production manifest could contain:

```json
{
  "format": 1,
  "build": "membership-ios-482",
  "source_revision": "<full-commit-sha>",
  "source_dirty": false,
  "contract": "card-v1",
  "host_protocol": 1,
  "platform": "ios",
  "replay": {
    "url": "https://replay.example/artifacts/<digest>/index.html",
    "digest": "sha256:<digest>",
    "digest_scheme": "<defined-artifact-hash-format>"
  }
}
```

This is a recommendation, not a schema implemented by Retrace. Define how a
multi-file artifact is hashed before treating its digest as portable. Record
compiler, dependency-lock and configuration provenance separately as needed;
avoid putting secrets into public build metadata.

Keep CI provider details in the application's workflow. On GitHub pull-request
workflows, `GITHUB_SHA` may identify the merge commit. Deliberately select the
checkout, then record `git rev-parse HEAD`. See
[GitHub's workflow event reference](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows).

## Resolve recordings without changing their identity

```text
Session.build → immutable release manifest → preserved replay artifact
Session.contract + host protocol → compatibility checks → reconstruction
```

The application carries its identity offline. A web build embeds it with the
loaded application; Tauri embeds it with the frontend assets. Do not fetch a
mutable current-version endpoint to identify executing code. A cached web page
or an older mobile installation must keep its original build ID.

An application update starts a new session under its new build ID. Previously
queued batches retain their original session metadata while they drain. Do not
rewrite those batches to the uploader's current build ID.

The host should distinguish unavailable artifacts, unsupported host protocols and
incompatible recordings. It must not silently load the newest renderer. Keep
artifacts for as long as their retained recordings need them, including after an
application rollback. Native platform differences may require separate replay
artifacts; sharing an artifact is a claim to verify, not an implication of sharing
Gleam source.

Artifacts execute code. A production host needs a trusted publication path and an
explicit isolation and integrity policy. A digest in a filename does not verify
fetched content. The maintained example trusts same-origin artifacts and demonstrates
style/runtime separation only; it is not a sandbox for untrusted modules.

## Run the maintained recipe

Inside `nix develop`, from `examples/advanced`:

```sh
npm ci
npm run build
# Or supply an application-owned CI identity:
RETRACE_BUILD_ID=membership-ios-482 npm run build
```

Live assets go to `examples/advanced/dist/`. Replay HTML, JavaScript, styles and the
manifest go to `examples/advanced/viewer/public/artifacts/<build>/`. Existing build IDs
are refused to avoid overwriting a recording's renderer. Preserve and deploy
those bytes with the application release. `npm run dev` uses a visibly mutable
development ID and does not preserve history across source edits.

The maintained recipe records source provenance but does not hash, sign or
verify artifact contents. Digest verification and atomic registry publication
above are deployment recommendations, not implemented capabilities. The older
two-edition digest experiment has been retired; its conclusions remain in this
guide, while current code references point to the maintained examples.
