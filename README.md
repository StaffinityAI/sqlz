# sqlz

sqlz is an early SQL toolkit for Zig, inspired by Rust's SQLx. It aims to keep
applications close to handwritten SQL while providing offline query checking,
generated type-safe bindings, and revision-based migrations.

> [!IMPORTANT]
> The first SQLite query/runtime slice is implemented. The offline semantic
> checker, generated bindings, migrations, PostgreSQL runtime, and stable public
> API are still under development.

## Planned features

- SQLite support through [`zqlite`](https://github.com/karlseguin/zqlite.zig).
- PostgreSQL support through [`pg.zig`](https://github.com/karlseguin/pg.zig).
- Lazy backend dependencies, with neither backend enabled by default and support
  for enabling either or both.
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

These documents define the intended 0.1 behavior and implementation milestones;
the current slice implements only the subset described below.

## Current slice

`zig build test` exercises typed SQLite queries across exec, one, optional, and
many cardinalities; borrowed and owned rows; nullable joins; recursive CTEs;
upserts with RETURNING; transaction commit/rollback; portable named-parameter
rewriting; and `libpg_query` parsing. Each scenario under `examples/` is also an
independently runnable executable, for example `zig build run-account_crud`.

The immediate next milestone is the offline semantic checker and binding
generator on top of this parser/runtime foundation. See the
[implementation roadmap](docs/README.md#implementation-roadmap) for the complete
sequence and acceptance gates.

## License

See [LICENSE](LICENSE).
