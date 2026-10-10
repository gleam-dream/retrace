#!/usr/bin/env bash
set -euo pipefail
project_root=$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)
export PGHOST=127.0.0.1 PGPORT=${PGPORT:-5547} PGUSER=retrace
check_db="retrace_check_$$"
export DATABASE_URL="postgres://retrace@127.0.0.1:$PGPORT/$check_db"
export RETRACE_CHECK_OBJECTS
RETRACE_CHECK_OBJECTS=$(mktemp -d)
createdb "$check_db"
cleanup() { dropdb --force "$check_db"; rm -rf "$RETRACE_CHECK_OBJECTS"; }
trap cleanup EXIT
cd "$project_root/examples/server_checks"
gleam run
