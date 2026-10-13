# Install and release Retrace

Retrace is distributed as source through
[gleam-dream/retrace](https://github.com/gleam-dream/retrace). The three packages
share one repository revision and version. They are experimental; pin a revision
and review changes before upgrading. No Hex release is available.

## Install from Git

Use Gleam 1.16 or later. Declare only the packages your application imports. A
Lustre browser or Tauri application typically starts with:

```toml
[dependencies]
retrace = { git = "https://github.com/gleam-dream/retrace.git", ref = "v0.1.0" }
retrace_frontend = { git = "https://github.com/gleam-dream/retrace.git", ref = "v0.1.0", path = "packages/retrace_frontend" }
```

A backend instead uses:

```toml
[dependencies]
retrace = { git = "https://github.com/gleam-dream/retrace.git", ref = "v0.1.0" }
retrace_server = { git = "https://github.com/gleam-dream/retrace.git", ref = "v0.1.0", path = "packages/retrace_server" }
```

The portable core works on Erlang and JavaScript; frontend targets JavaScript and
server targets Erlang. Keep all Retrace dependencies on the **same revision**.
The subpackages' relative core dependency resolves within that Git checkout.
Continue declaring Lustre and other libraries directly when your code imports them.
Commit your application's `manifest.toml` to preserve resolved dependencies.

For an immutable source pin, replace `v0.1.0` in every Retrace dependency with the
full commit SHA shown by the GitHub release. For local development, clone the
repository and use `path` dependencies instead. See the
[Lustre adoption guide](adopting-lustre.md) for application wiring.

## Check a release

From a clean checkout, enter `nix develop` and run:

```sh
bash dev/check.sh
bash dev/git-consumer-check.sh
```

The first gate tests both core targets, builds all consumers and both examples,
and runs the frontend and artifact tests. The second creates temporary projects
outside this repository and runs core reconstruction on both targets, frontend
adapter construction on JavaScript, and server object-store composition on Erlang.
It uses the current **committed** revision, not working-tree edits. It does not
exercise a browser, native shell, database or cloud service.

For runtime evidence, use the explicitly separate browser, backend and Simulator
checks documented in the [root README](../README.md#checks) and
[device guide](testing-devices.md). Report which gates ran; a compile is not a
native deployment test.

Before tagging, review tracked files, licenses and attribution, run the design
gate, and commit release changes. Publish the checked commit as an experimental
GitHub prerelease. Keep existing release tags fixed. Do not use `gleam publish`:
Hex distribution is a separate decision and requires packaging the internal
path dependencies appropriately.

After pushing, verify the actual remote source from independent consumers:

```sh
bash dev/git-consumer-check.sh https://github.com/gleam-dream/retrace.git v0.1.0
```
