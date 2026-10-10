# Initial delivery brief

Accepted scope: create Retrace with sibling Nix/basic conventions and an example
Lustre app for browser and Tauri. The prior accepted architecture includes durable
client delivery, Mist ingestion, PostgreSQL indexing and S3 archival, with Time
Travel only in the viewer. No publishing or PR.

Governing source: docs/design/design.typ, especially Recording and replay,
Client delivery, Ingestion and archival, and Example application and viewer.

Acceptance: public core tests on both targets; exact retry/conflict and ordering;
real database and S3-compatible upload/retrieval; store outage preserves payload;
collector restart preserves search/replay; browser outbox drains after reload;
viewer is inert; web production build and Tauri compilation; scoped formatting
and design gates. Native device installation is not required for desktop example
completion and must not be claimed without an actual device run.

Gate commands: gleam test --target javascript; gleam test --target erlang;
dev/check.sh; nix fmt; nix flake check; design render/check/context commands in
AGENTS.md. Tests exercise public package/HTTP/UI boundaries, with local services
owned by the harness. Test storage and build outputs are ignored.
