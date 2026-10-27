#!/usr/bin/env bash
# Run inside nix develop. Verify committed Git distribution outside the monorepo.
set -euo pipefail
project_root=$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)
repository=${1:-"file://$project_root"}
revision=${2:-$(git -C "$project_root" rev-parse HEAD)}
consumer_root=$(mktemp -d "${TMPDIR:-/tmp}/retrace-git-consumer.XXXXXX")
trap 'rm -rf "$consumer_root"' EXIT

prepare_dependencies() {
  local dependency_output attempt
  for attempt in 1 2 3; do
    if dependency_output=$(gleam deps download 2>&1); then
      printf '%s\n' "$dependency_output"
      return 0
    fi
    printf '%s\n' "$dependency_output" >&2
    if [[ "$dependency_output" != *"rate limit for the Hex API has been exceeded"* || "$attempt" = 3 ]]; then
      return 1
    fi
    printf 'Hex metadata rate limit; retrying dependency download in 45 seconds.\n' >&2
    sleep 45
  done
}

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

mkdir -p "$consumer_root/collector/src"
cat > "$consumer_root/collector/gleam.toml" <<TOML
name = "retrace_distribution_check"
version = "0.1.0"
target = "erlang"
[dependencies]
retrace = ">= 0.1.0 and < 0.2.0"
retrace_server = ">= 0.1.0 and < 0.2.0"
retrace_collector = { git = "$repository", ref = "$revision", path = "support/collector" }
TOML
cat > "$consumer_root/collector/src/retrace_distribution_check.gleam" <<'GLEAM'
import retrace_collector

pub fn main() {
  let _start: fn() -> Nil = retrace_collector.main
  Nil
}
GLEAM

(cd "$consumer_root/core" && prepare_dependencies && gleam run --target erlang && gleam run --target javascript)
(cd "$consumer_root/frontend" && prepare_dependencies && gleam run)
(cd "$consumer_root/server" && prepare_dependencies && gleam run)
(cd "$consumer_root/collector" && prepare_dependencies && gleam build --warnings-as-errors && gleam run)
python3 - "$consumer_root/collector/manifest.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as source:
    packages = {package["name"]: package for package in tomllib.load(source)["packages"]}
for name in ("retrace", "retrace_server"):
    assert packages[name]["source"] == "hex", f"Git collector replaced Hex {name}"
print("Git collector retains both published Hex parents")
PY
printf 'Git consumers passed: %s at %s\n' "$repository" "$revision"
