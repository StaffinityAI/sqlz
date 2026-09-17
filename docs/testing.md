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
- runtime integration tests for borrowed/owned lifetimes, owned-row scopes,
  transaction cleanup and locking behavior, native pools, arrays, non-STRICT
  SQLite validation, enum and narrow-scalar decoding, and error ownership;
- declaration tests proving an embedded `.params`/`.row` struct that disagrees
  with its SQL is reported: missing, extra, and reordered fields, nullability in
  both directions, an unmappable type without a codec, and a codec pinned to a
  built-in field;
- an application-layer suite compiled with `sqlz` as its only import, so any
  ordinary database work that still required the driver handle fails to build;
- an example project whose roots cover every example directory, so an example
  query — in a `.sql` file or declared in Zig — cannot reach the runtime without
  passing the checker;
- build-input tests proving an edited, added, or removed query invalidates the
  generated module instead of reporting a cache hit;
- build-matrix tests proving core-only, SQLite-only, PostgreSQL-only, and both
  backends fetch and link only selected runtime dependencies;
- `std.Io` tests covering both halves on a non-std implementation: connections,
  transactions, and streaming cursors retain the supplied interface, and the
  host pipeline emits byte-identical bindings regardless of which one reads the
  inputs;
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
