# Test strategy

Testing is layered so parser correctness, schema replay, generated Zig, driver
behavior, and migration safety fail independently.

## Required suites

- lexer/parser unit tests, golden ASTs, recovery diagnostics, property tests, and
  fuzz targets;
- catalog signature, coercion, nullability, overload, and codec-resolution tests;
- migration DAG planning, replay, merge convergence, checksum, identity, lock,
  journal, interruption, and state-upgrade tests;
- generated-binding snapshots plus compile-pass and compile-fail fixtures on Zig
  0.16.0;
- runtime integration tests for borrowed/owned lifetimes, transaction cleanup,
  native pools, arrays, non-STRICT SQLite validation, and error ownership;
- build-matrix tests proving core-only, SQLite-only, PostgreSQL-only, and both
  backends fetch and link only selected runtime dependencies;
- CLI human/JSON golden tests, stdout/stderr separation, exit codes, and destructive
  confirmation tests.

## Engine matrix

Differential parser/conformance CI runs against SQLite profiles 3.45–3.53 and every
PostgreSQL major 15–18. Full runtime tests run on x86_64 Linux and arm64 macOS;
Windows receives a compile check. Bundled SQLite uses a known capability manifest;
system/custom builds have runtime option verification tests.

Every defect gains the narrowest regression test and, when it crosses a component
boundary, an integration fixture. Tests must not require a production database or
network access after dependencies and engine images are provisioned.
