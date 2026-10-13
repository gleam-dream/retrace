# Development support

These are isolated Gleam projects used by repository tooling, not application
adoption examples. The two application examples are basic and advanced.

- `collector/`: local Mist host, database pool and archive worker; start with
  `bash dev/services.sh` from the repository root inside Nix.
- `client_checks/`: separately compiled public-API consumer for typed client
  adapters. Build with `gleam build` in that directory, then run
  `node --test support/client_checks/adapter.test.mjs` from the repository root.
  It covers provider errors, receipt retry, cancellation races and shutdown.
- `server_checks/`: public-API fault consumer; run with `bash dev/server-check.sh`
  against the repository's local PostgreSQL service. It creates and removes its
  own disposable database.

Separate project directories keep their dependencies out of the portable core's
compiler-scanned dev/ and test/ source trees.
