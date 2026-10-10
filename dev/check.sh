#!/usr/bin/env bash
# Run inside nix develop. Network/runtime/native checks are explicit separate gates.
set -euo pipefail
project_root=$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
gleam test --target javascript
gleam test --target erlang
for package in packages/retrace_client packages/retrace_server examples/collector examples/server_checks; do
  (cd "$package" && gleam build)
done
(cd examples/app && npm ci && npm run build)
shellcheck dev/*.sh
