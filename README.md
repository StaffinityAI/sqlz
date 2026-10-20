# sqlz

sqlz is an early SQL toolkit for Zig, inspired by Rust's SQLx. It aims to keep
applications close to handwritten SQL while providing offline query checking,
generated type-safe bindings, and revision-based migrations.

> [!IMPORTANT]
> Offline checking, generated bindings, and checked-query runtimes for SQLite
> and PostgreSQL are implemented for the current SQL/catalog subset. Migration
> discovery and offline catalog replay exist, but stateful database migration
> planning and execution are the largest missing subsystem. The public API is
> still under development.

## Planned features

- SQLite support through [`zqlite`](https://github.com/karlseguin/zqlite.zig).
- PostgreSQL support through [`pg.zig`](https://github.com/karlseguin/pg.zig).
- Lazy backend dependencies, with neither backend enabled by default and support
  for enabling either or both.
- Runtime handles initialized with the application's `std.Io`, so sqlz runs on
  `std.Io.Threaded` or a third-party runtime such as
  [zio](https://github.com/lalinsky/zio) without depending on either.
- Checked queries authored as named `.sql` files or typed Zig declarations.
- A host-side checker using pinned `libpg_query` for shared SQL syntax, with a
  narrow SQLite extension layer—no SQL parsing or semantic analysis at comptime.
- Offline schema reconstruction from migrations, without a development database.
- Typed named parameters, typed borrowed rows, explicit owned-row conversion,
  and custom codecs for application types.
- Alembic-inspired migration graphs with upgrades, downgrades, branches, merge
  revisions, checksums, durable operation journals, and build-system tooling.
- One versioned `sqlz.ziggy` project configuration and a unified
  `zig build sqlz -- ...` command, including support for multiple projects.
- Configurable SQLite 3.45–3.53 and PostgreSQL 15–18 compatibility profiles.

sqlz is a SQL toolkit rather than an ORM. It will not provide model persistence,
relationships, or a query-builder DSL; applications retain control over SQL,
connections, transactions, allocation, and domain models.

## Design documents

The evolving specification lives in [`docs/`](docs/README.md):

- [Architecture](docs/architecture.md)
- [Project configuration](docs/configuration.md)
- [Checked query API](docs/query-api.md)
- [SQL checker and binding generator](docs/sql-checker.md)
- [SQL parser](docs/parser.md), [type system](docs/type-system.md), and
  [catalogs](docs/catalogs.md)
- [Runtime architecture](docs/runtime.md) and
  [errors and observability](docs/errors-and-observability.md)
- [Migrations](docs/migrations.md)
- [Migration state and journal](docs/migration-state.md)
- [Build-system integration](docs/build-integration.md)
- [Build-integrated CLI](docs/cli.md)
- [Compatibility](docs/compatibility.md), [testing](docs/testing.md),
  [performance](docs/performance.md), and [security](docs/security.md)
- [Design completeness audit](docs/design-audit.md) and
  [architecture decision records](docs/adr/README.md)
- [Live implementation plan](docs/implementation-plan.md)

These documents define the intended 0.1 behavior and implementation milestones;
the current slice implements only the subset described below.

## Current status

`zig build test` exercises typed SQLite and PostgreSQL queries across exec, one,
optional, and many cardinalities; borrowed and owned rows; transactions; native
pools; enum codecs; PostgreSQL arrays and version policy; portable
named-parameter rewriting; and `libpg_query` parsing. `zig build test-zio` and
`zig build test-zio-host` repeat the SQLite runtime and host coverage on a
zio-backed `std.Io`; PostgreSQL zio socket coverage remains pending.

`zig build test-consumer` builds an application layer whose only import is
`sqlz` — schema scripts, PRAGMAs, typed connection options, enum columns, blobs,
narrow integer and float columns, arena-scoped owned rows, transactions with
explicit locking behavior, and a connection pool. The driver handle behind
`raw()` stays available for features sqlz does not model, but ordinary
application work never reaches for it.

Every scenario under `examples/` is checked offline: the examples are one sqlz
project whose schema lives in `examples/migrations` and whose SQL lives in
`examples/queries`, with every example directory registered as a Zig root, so a
query declared in Zig anywhere under `examples/` is checked too. Each is also an independently runnable
executable, for example `zig build run-account_crud`.

Start with the three `basic_*` examples. Each imports only `sqlz` (and the
generated `queries` module where it uses `.sql` files), opens an in-memory
SQLite database, and prints what it does:

- `basic_sql_file` runs queries from `.sql` files through the generated module
  and shows the `Result` union a database call returns;
- `basic_embedded_query` declares its queries in Zig and streams rows;
- `basic_transaction` rolls back one transaction and commits another.

Four of the others demonstrate
the surface an application needs beyond plain query execution — `enum_roles`
maps a column and a parameter onto a Zig enum through a registered codec,
`arena_rows` collects a result set into an arena scope with no per-row cleanup,
`pooled_reads` runs checked queries straight against a connection pool, and
`embedded_declarations` declares its queries in Zig instead of `.sql` files.

Queries authored as Zig declarations are checked the same way, and their
`.params` and `.row` structs are compared against the SQL for field names,
order, nullability, and type, so a declaration cannot drift from the query it
sits beside.

Migration discovery currently means loading revision manifests, validating and
ordering the DAG, and replaying supported DDL into offline SQLite and PostgreSQL
catalogs. It does not migrate a database: persistent migration state, target
planning, locking, checksums, journals, upgrade/downgrade runners, and runtime
migration bundles remain to be implemented.

`zig build sqlz -- bootstrap postgres` is an initial partial operational command,
not the full CLI. It can route a registered project, replay a transactional
PostgreSQL head into a dedicated schema, transfer compatible SQLite rows with
bound parameters, restore sequences, and validate row counts. It still uses a
bootstrap-private replay path and lacks normal migration state/checksums,
journaling, advisory locking, interactive confirmation, and JSON output.

See the checked [current-status table](docs/README.md#current-implementation-status)
and [implementation plan](docs/implementation-plan.md) for the complete sequence
and acceptance gates.

## Development

The repository pins Zig, [hk](https://hk.jdx.dev), and
[pkl](https://pkl-lang.org) with [mise](https://mise.jdx.dev). Install the
toolchain and wire the git hook with:

```sh
mise install
hk install
```

`mise run check` and the hk pre-commit hook run only quick offline checks:
formatting plus `zig build test-offline`. They never start Docker, open a
database connection, or require network access.

Run the complete local CI gate with:

```sh
mise run ci
```

That command first runs the offline gate, then starts PostgreSQL 18 with Docker
Compose and runs the full test suite plus integration tests against both the
in-process SQLite engine and the live PostgreSQL service. Compose teardown runs
on success, failure, or interruption.

## License

See [LICENSE](LICENSE).
