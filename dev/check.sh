#!/usr/bin/env bash
# Run inside nix develop. Network/runtime/native checks are explicit separate gates.
set -euo pipefail
project_root=$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
gleam test --target javascript
gleam test --target erlang
for package in packages/retrace_frontend packages/retrace_server support/collector support/server_checks support/client_checks; do
  (cd "$package" && gleam build)
done
(cd examples/advanced && npm ci && npm run build && node --test dev/history.test.mjs dev/build.test.mjs dev/local_archive.test.mjs)
node --test packages/retrace_frontend/test/*.test.mjs support/client_checks/adapter.test.mjs dev/readme.test.mjs
(cd examples/basic && npm ci && npm run build && node --test replay.test.mjs adoption.test.mjs)
(cd examples/advanced/viewer && npm run build)
shellcheck dev/*.sh dev/simulator/*.sh
