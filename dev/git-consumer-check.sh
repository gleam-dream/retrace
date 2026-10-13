#!/usr/bin/env bash
# Run inside nix develop. Verify committed Git distribution outside the monorepo.
set -euo pipefail
project_root=$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)
repository=${1:-"file://$project_root"}
revision=${2:-$(git -C "$project_root" rev-parse HEAD)}
consumer_root=$(mktemp -d "${TMPDIR:-/tmp}/retrace-git-consumer.XXXXXX")
trap 'rm -rf "$consumer_root"' EXIT

for package in core frontend server; do
  directory="$consumer_root/$package"
  mkdir -p "$directory/src"
  target=erlang
  if [ "$package" = frontend ]; then target=javascript; fi
  cat > "$directory/gleam.toml" <<TOML
name = "retrace_distribution_check"
version = "0.1.0"
target = "$target"
[dependencies]
retrace = { git = "$repository", ref = "$revision" }
TOML
  if [ "$package" != core ]; then
    cat >> "$directory/gleam.toml" <<TOML
retrace_$package = { git = "$repository", ref = "$revision", path = "packages/retrace_$package" }
TOML
  fi
done

cat > "$consumer_root/core/src/retrace_distribution_check.gleam" <<'GLEAM'
import retrace

pub fn main() {
  let origin = retrace.Origin("git-consumer", "counter-v1")
  let assert Ok(#(recorder, checkpoint)) = retrace.start(origin, 0)
  let assert Ok(#(_, entry)) = retrace.record(recorder, 3, elapsed_ms: 20)
  let assert Ok(player) =
    retrace.replay(checkpoint, "counter-v1", fn(state, message) {
      Ok(state + message)
    })
  let assert Ok(player) = retrace.step(player, entry)
  assert retrace.model(player) == 3
}
GLEAM
cat > "$consumer_root/frontend/src/retrace_distribution_check.gleam" <<'GLEAM'
import retrace_frontend/client
import retrace_frontend/viewer

pub fn main() {
  let _storage = client.browser_storage()
  let _transport = client.http_transport("https://recordings.example")
  let _viewer =
    viewer.new(
      viewer.collector("https://recordings.example"),
      viewer.artifacts("/artifacts"),
    )
  Nil
}
GLEAM
cat > "$consumer_root/server/src/retrace_distribution_check.gleam" <<'GLEAM'
import retrace_server

pub fn main() {
  let store = retrace_server.ObjectStore(
    put: fn(_, _) { Ok(Nil) },
    get: fn(_) { Error(retrace_server.Missing) },
  )
  assert store.get("missing") == Error(retrace_server.Missing)
}
GLEAM

(cd "$consumer_root/core" && gleam run --target erlang && gleam run --target javascript)
(cd "$consumer_root/frontend" && gleam run)
(cd "$consumer_root/server" && gleam run)
printf 'Git consumers passed: %s at %s\n' "$repository" "$revision"
