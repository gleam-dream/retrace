#!/usr/bin/env bash
# Run inside nix develop. Network/runtime/native checks are explicit separate gates.
set -euo pipefail
project_root=$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
gleam test --target javascript
gleam test --target erlang
for package in packages/retrace_lustre packages/retrace_viewer packages/retrace_client packages/retrace_server support/collector support/server_checks; do
  (cd "$package" && gleam build)
done
(cd examples/advanced && npm ci && npm run build && node --test dev/history.test.mjs)
node --test packages/retrace_client/test/runtime.test.mjs
node --test packages/retrace_lustre/test/*.test.mjs packages/retrace_viewer/test/*.test.mjs
(cd examples/basic && npm ci && npm run build && node --test replay.test.mjs)
(cd examples/advanced/viewer && npm run build)
shellcheck dev/*.sh dev/simulator/*.sh
