# sqlz

sqlz is a planned SQL toolkit for Zig, inspired by Rust's SQLx. It aims to keep
applications close to handwritten SQL while providing offline query checking,
generated type-safe bindings, and revision-based migrations.

> [!IMPORTANT]
> sqlz is currently in the design phase. The public API described in the design
> documents has not been implemented yet.

## Planned features

- SQLite support through [`zqlite`](https://github.com/karlseguin/zqlite.zig).
- PostgreSQL support through [`pg.zig`](https://github.com/karlseguin/pg.zig).
- Lazy backend dependencies, with neither backend enabled by default and support
  for enabling either or both.
- Checked queries authored as named `.sql` files or typed Zig declarations.
- A custom host-side SQL parser and checker with precise diagnostics—no SQL
  parsing or semantic analysis at comptime.
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

The pre-implementation specification lives in [`docs/`](docs/README.md):

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

These documents define the intended 0.1 behavior and implementation milestones.
Until the first implementation exists, they are the source of truth for project
scope and API design.

## Status

The immediate next milestone is the checker foundation: source management,
diagnostics, SQL lexer/parser infrastructure, migration manifest loading, and
revision graph validation. See the [implementation roadmap](docs/README.md#implementation-roadmap)
for the complete sequence and acceptance gates.

## License

See [LICENSE](LICENSE).
