# Collector host

[![CI](https://github.com/gleam-dream/retrace/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/retrace/actions/workflows/ci.yml)
[![retrace on Hex](https://img.shields.io/hexpm/v/retrace?label=Hex%3A%20retrace)](https://hex.pm/packages/retrace)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

An unpublished development host for the collector protocol, backed by PostgreSQL
and an S3-compatible store. It binds to loopback and has no deployment
authentication or tenant isolation. Applications own hosted deployment policy.

From the repository's Nix shell, run `bash dev/services.sh` to start its local
services and collector. Run `python3 dev/backend-check.py` to check ingestion and
archive readback against those services.

An external development host can use the collector through Git+path alongside
the published packages. Replace `RETRACE_COMMIT_SHA` with a verified commit; the
collector's parent dependencies resolve from Hex.

```toml
[dependencies]
retrace = ">= 0.1.0 and < 0.2.0"
retrace_server = ">= 0.1.0 and < 0.2.0"
retrace_collector = { git = "https://github.com/gleam-dream/retrace.git", ref = "RETRACE_COMMIT_SHA", path = "support/collector" }
```
