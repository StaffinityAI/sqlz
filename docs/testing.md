# Test strategy

Testing is layered so parser correctness, schema replay, generated Zig, driver
behavior, and migration safety fail independently.

## Developer and CI gates

The repository has two intentionally separate validation gates:

- `mise run check` is the quick offline gate. It delegates to `hk check`, checks
  formatting, and runs `zig build test-offline`. It is deterministic, requires
  no network or database service, and is the only gate installed as the hk
  pre-commit hook.
- `mise run ci` is the complete gate. It runs the offline gate, starts the
  pinned PostgreSQL service from `compose.yaml`, runs `zig build test`, and then
  runs `zig build test-integration` against SQLite and PostgreSQL. A shell trap
  always removes the Compose service and volume.

`zig build test-postgres` remains a compile/API test and does not connect to a
server. `zig build test-postgres-integration` is the live PostgreSQL-only gate;
`zig build test-bootstrap-integration` creates a realistic temporary SQLite
database, runs the public SQLite-to-PostgreSQL bootstrap command, and validates
the resulting PostgreSQL rows and identity sequences. `zig build test-sqlite`
is the SQLite-only runtime gate. These narrower commands are useful while
developing an adapter, but `mise run ci` is the required pre-push and
continuous-integration command.

Long-running, service-backed, and end-to-end tests must not be added to
`test-offline` or the hk hook. Quick parser, catalog, migration-planning,
checker, generator, and generated-code tests should remain offline where
possible so they can fail before integration infrastructure is involved.

## Required suites

- lexer/parser unit tests, golden ASTs, recovery diagnostics, property tests, and
  fuzz targets;
- catalog signature, coercion, nullability, overload, and codec-resolution tests;
- migration DAG planning, replay, merge convergence, checksum, identity, lock,
  journal, interruption, and state-upgrade tests;
- checkpoint tests for exact replacement closures, per-backend catalog
  equivalence, fresh bootstrap selection, historical-path coexistence, partial
  deployments, adoption, ambiguous candidates, finalized tombstones, source
  pruning, and downgrade-boundary refusal;
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
network access after dependencies and engine images are provisioned. The
PostgreSQL integration suite uses only the disposable Compose service; SQLite
integration tests use an in-process or temporary database.

Checkpoint tests use both schema-only and DML-bearing histories. They prove only
empty-database schema equivalence and verify that the tool never claims historical
data equivalence. Failure-injection coverage includes transactional and
nontransactional checkpoint bootstrap, adoption drift, interrupted finalization,
and recovery from a journaled partial bootstrap.
Finalization tests remove the original revision directories, retain
`history.ziggy`, and cover databases below, exactly at, and beyond the boundary.
They verify that at/beyond states continue, below-boundary states produce a
pruned-history-unavailable diagnostic, and reused finalized IDs are rejected.
Repeated-compaction fixtures verify composed equivalence from a finalized
checkpoint snapshot through a live suffix, and reject nested checkpoints while an
earlier coexistence transition remains open.
