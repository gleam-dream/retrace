#!/usr/bin/env bash
# Repository-owned local development services. No existing database is touched.
set -euo pipefail
project_root=$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)
service_root="${RETRACE_DATA_DIR:-$project_root/.local}"
mkdir -p "$service_root/seaweed" "$service_root/logs"
export PGHOST=127.0.0.1 PGPORT="${PGPORT:-5547}" PGUSER=retrace PGDATABASE=retrace
export DATABASE_URL="postgres://retrace@127.0.0.1:$PGPORT/retrace"
export RETRACE_PORT="${RETRACE_PORT:-4417}" S3_PORT="${S3_PORT:-8337}"
export S3_HOST=127.0.0.1 S3_BUCKET=retrace S3_ACCESS_KEY=retrace-local S3_SECRET_KEY=retrace-local-development-only
if [[ ! -f "$service_root/postgres/PG_VERSION" ]]; then
  initdb -D "$service_root/postgres" --username=retrace --auth-local=trust --auth-host=trust >/dev/null
fi
started_pg=0
if ! pg_ctl -D "$service_root/postgres" status >/dev/null 2>&1; then
  pg_ctl -D "$service_root/postgres" -o "-h 127.0.0.1 -p $PGPORT -k $service_root" -l "$service_root/logs/postgres.log" start >/dev/null
  started_pg=1
fi
createdb retrace 2>/dev/null || true
# Port defaults are distinct from ordinary PostgreSQL, S3 and the prior demos.
(cd "$service_root/seaweed" && exec weed server -dir="$service_root/seaweed" -ip=127.0.0.1 -ip.bind=127.0.0.1 \
  -master.port=9347 -volume.port=8097 -filer.port=8897 -s3 -s3.port="$S3_PORT" -volume.max=32 -master.volumeSizeLimitMB=64 \
  >"$service_root/logs/seaweed.log" 2>&1) &
object_pid=$!
collector_pid=""
cleanup() {
  [[ -z "$collector_pid" ]] || kill "$collector_pid" 2>/dev/null || true
  kill "$object_pid" 2>/dev/null || true
  wait "$object_pid" 2>/dev/null || true
  [[ "$started_pg" != 1 ]] || pg_ctl -D "$service_root/postgres" -m fast stop >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
for _ in $(seq 1 60); do
  curl -s --connect-timeout 1 "http://127.0.0.1:$S3_PORT/" >/dev/null && break
  sleep 1
done
kill -0 "$object_pid" || { tail -30 "$service_root/logs/seaweed.log"; exit 1; }
if [[ "${1:-}" = "--" ]]; then shift; "$@"; exit; fi
cd "$project_root/support/collector"
gleam run &
collector_pid=$!
wait "$collector_pid"
