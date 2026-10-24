# Development support

Isolated Gleam projects used by repository tooling, not application examples.

- `collector/`: local Mist host, database pool and archive worker. Start with `bash dev/services.sh` from the repository root inside Nix.
- `client_checks/`: separately compiled consumer of the typed client adapters. Run `gleam build` in that directory, then `node --test support/client_checks/adapter.test.mjs` from the repository root.
- `server_checks/`: public-API fault consumer. Run `bash dev/server-check.sh` from the repository root against the local PostgreSQL service. It creates and removes its own database.

Separate project directories keep their dependencies out of the portable core's compiler-scanned `dev/` and `test/` trees.
