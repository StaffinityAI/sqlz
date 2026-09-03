# sqlz design documents

Status: pre-implementation design for sqlz 0.1.

These documents define the first implementation of sqlz: a Zig SQL toolkit with
offline-checked queries, generated typed bindings, and revision-based migrations.
They are normative for the 0.1 implementation. If code and these documents later
disagree, either the code or the relevant document must be updated deliberately;
the disagreement must not become an undocumented compatibility rule.

## Goals

sqlz will:

- support SQLite through `zqlite` and PostgreSQL through `pg.zig`;
- keep both backend dependencies lazy and disabled by default;
- let an application enable SQLite, PostgreSQL, or both in one build;
- check ordinary SQL against schemas reconstructed from migrations without a live
  database;
- report SQL errors from a host tool with precise source spans and actionable
  context;
- support named SQL files and typed query declarations embedded in Zig;
- expose typed parameters and typed, allocation-free row views, with an explicit
  conversion to owned results;
- provide an Alembic-inspired revision graph, downgrade support, and migration
  tooling through Zig's build system and a runtime API.

sqlz is intentionally a SQL toolkit, not an ORM. Applications retain control of
their SQL, connections, transactions, domain models, allocation, and result
lifetimes.

## Non-goals for 0.1

- MySQL, MariaDB, or other database backends.
- A model persistence layer, relationship loader, query-builder DSL, or active
  record API.
- Migration autogeneration or schema diffing.
- Query checking against a development or production database.
- SQL parsing or semantic analysis during Zig comptime execution.
- Complete grammar parity with every SQLite or PostgreSQL extension.
- A runtime-selected `AnyDatabase` abstraction.

Unchecked or extension-specific operations remain possible through the raw
`zqlite` and `pg.zig` handles exposed by their sqlz adapters.

## Design index

- [Architecture](architecture.md) defines component boundaries, data flow,
  dependency isolation, backend adaptation, diagnostics, and caching.
- [Configuration](configuration.md) defines `sqlz.ziggy`, profiles, source-root
  aliases, limits, codecs, project identity, and multiple-project builds.
- [Query API](query-api.md) defines both query authoring forms, generated APIs,
  parameter and result types, ownership, codecs, and transactions.
- [SQL checker](sql-checker.md) defines parsing, schema replay, semantic checks,
  supported SQL, diagnostics, and generated output.
- [Parser](parser.md), [type system](type-system.md), and
  [catalogs](catalogs.md) specify the checker's detailed front end and semantics.
- [Runtime](runtime.md) and [errors and observability](errors-and-observability.md)
  specify wrappers, ownership, pools, transactions, Results, privacy, and events.
- [Migrations](migrations.md) defines revision files, graph and execution
  semantics, state tracking, commands, and the runtime migrator.
- [Migration state](migration-state.md) defines project identity, checksums,
  applied revisions, internal upgrades, and the operation journal.
- [Build integration](build-integration.md) defines feature flags, public modules,
  host tools, generated modules, consumer setup, and the build matrix.
- [CLI](cli.md) defines the unified build-integrated command and output contract.
- [Compatibility](compatibility.md), [testing](testing.md),
  [performance](performance.md), and [security](security.md) define release policy.
- [Design audit](design-audit.md) tracks resolved and deferred detail, while the
  [ADR index](adr/README.md) records the rationale for accepted decisions.

## Terminology

- **Backend**: one of `sqlite` or `postgres`.
- **Dialect**: backend-specific SQL grammar and semantics.
- **Checked query**: a static SQL statement accepted by
  `zig build sqlz -- check` against a migration-derived catalog.
- **Query declaration**: a named `.sql` query or a `sqlz.Query` value in Zig.
- **Executor**: a sqlz adapter around a backend connection, pool, or transaction
  that can run a checked query.
- **Row view**: decoded values whose borrowed slices remain valid only while the
  owning query result is valid and has not advanced.
- **Owned row**: a generated value that duplicates borrowed data with a caller-
  supplied allocator.
- **Catalog**: the checker's in-memory description of schemas, tables, columns,
  constraints, indexes, and database types.
- **Revision**: one migration node with an opaque ID and zero or more parents.
- **Head**: a revision without a child in the loaded graph.

## Design principles

1. SQL is the source language. sqlz checks SQL rather than replacing it with a
   Zig DSL.
2. Diagnostics belong to a normal host program. The checker may use Zig types in
   its input and generated output, but it never parses or validates SQL at
   comptime.
3. Migration history is schema truth. CI and local builds produce the same
   catalog without credentials or network services.
4. Borrowing is explicit. APIs do not conceal a driver's result lifetime or
   silently allocate strings and blobs.
5. Portability is opt-in per query. The public conventions are shared, while the
   checker still understands and permits backend-specific SQL.
6. Disabled backends cost nothing. A disabled driver is not fetched, imported,
   compiled, or linked.

## Implementation roadmap

Each milestone ends with its stated acceptance gate. The 0.1 release requires
all milestones; early milestones are not separate compatibility promises.

### M1: configuration, syntax, diagnostics, and graph foundations

- Implement versioned Ziggy configuration/manifests, source management, lexer
  infrastructure, diagnostic rendering, and revision graph validation.
- Implement common AST nodes and explicit dialect extension points.
- Gate: golden tests cover multiple diagnostics, source labels, invalid UTF-8,
  invalid graphs, branches, and merges without crashing.

### M2: schema replay

- Parse and apply the supported SQLite and PostgreSQL DDL subset to the catalog.
- Track the migration source span for every catalog object and type fact.
- Gate: representative migration histories produce stable catalog snapshots for
  both backends, including a shared graph that uses backend-specific SQL.

### M3: checked queries and SQLite runtime

- Analyze the practical DML subset, discover both query declaration forms,
  generate Zig bindings, and implement the `zqlite` adapter.
- Gate: an example application builds and runs all four cardinalities against an
  in-memory SQLite database using generated and embedded queries.

### M4: PostgreSQL and shared behavior

- Implement PostgreSQL grammar and type-system differences and the `pg.zig`
  adapter.
- Gate: the same portable query fixtures pass on both backends, backend-specific
  fixtures work only on their declared backend, and row lifetime tests cover
  PostgreSQL draining and pool release.

### M5: migration execution and build integration

- Implement versioned migration state, operation journal, locking,
  upgrade/downgrade/repair operations, unified host command, runtime bundles,
  cache integration, and lazy flags.
- Gate: migration integration tests pass on SQLite and PostgreSQL, and the four-
  configuration build matrix proves disabled dependencies remain unused.

### M6: hardening and 0.1 release

- Add engine differential/fuzz suites, deterministic-generation checks, public
  API examples, compatibility fixtures, failure-recovery tests, and performance
  baselines with numeric stabilization gates.
- Gate: all documented examples compile, all public behavior has an integration
  test, and no open issue contradicts a normative statement in these documents.

## Design influences

SQLx demonstrates the value of ordinary SQL, typed parameters and results,
backend feature selection, streaming rows, and explicit `one`/`optional`/`many`
operations. sqlz differs by performing its SQL analysis in a dedicated offline
tool over migration-derived catalogs instead of macros or a live database. See
the [SQLx project overview](https://github.com/launchbadge/sqlx).

Alembic supplies the vocabulary and operational model for opaque revisions,
parent links, branches, merge points, heads, upgrade, downgrade, history, and
stamp. sqlz uses static SQL files instead of executable migration programs and
does not include autogeneration in 0.1. See Alembic's
[tutorial](https://alembic.sqlalchemy.org/en/latest/tutorial.html) and
[branch documentation](https://alembic.sqlalchemy.org/en/latest/branches.html).

Awebo's database code demonstrates a low-friction Zig interface built from
declarative query types, typed argument structs, typed column access, prepared
statements, and schema metadata. sqlz retains those ergonomic ideas while
removing manual SQL/metadata synchronization and compile-time SQL construction.
The relevant sources are
[Database.zig](https://codeberg.org/awebo-chat/awebo/src/branch/main/src/awebo/Database.zig),
[CommonQueries.zig](https://codeberg.org/awebo-chat/awebo/src/branch/main/src/awebo/Database/CommonQueries.zig),
and [tables.zig](https://codeberg.org/awebo-chat/awebo/src/branch/main/src/awebo/Database/tables.zig).
