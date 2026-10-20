# sqlz design documents

Status: normative design for sqlz 0.1. The checker, generator, and checked-query
runtimes for SQLite and PostgreSQL are implemented for the current subset.
Revision discovery and offline catalog replay exist, but stateful database
migration planning and execution are the largest missing subsystem. The only
operational CLI path is the initial partial `bootstrap postgres` command.
[implementation-plan.md](implementation-plan.md) is the authority on what exists
today, including the places where code still trails these documents.

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

Unchecked SQL remains possible through the adapters themselves: a single
statement is `execute`/`fetch*` with SQL the checker never saw, and a
parameterless multi-statement script is `executeScript`. The raw `zqlite` and
`pg.zig` handles stay exposed for driver features sqlz does not model at all,
not for ordinary schema or PRAGMA work.

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
- [SQLite-to-PostgreSQL bootstrap plan](sqlite-postgres-bootstrap-plan.md) tracks
  the scoped design, destructive wipe policy, implementation phases, and status
  for project-backed database bootstrap.
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
- **Owned row**: a generated value that duplicates borrowed data with an
  allocator, either named per call or taken from the connection's owned-row
  scope.
- **Owned-row scope**: a connection-level allocator that allocator-less
  conversions use; a scope that releases wholesale makes each row's `deinit` a
  no-op.
- **Codec**: a stable ID whose database patterns live in `sqlz.ziggy` and whose
  Zig declaration is bound once in `build.zig`, letting checked queries name an
  application type.
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

## Current implementation status

This table is checked against the codebase and the ordered slices in
[implementation-plan.md](implementation-plan.md). “Partial” means useful
production code exists but the relevant 0.1 acceptance gates are not complete.

| Top-level subsystem | Status | Implemented now | Principal remaining work |
| --- | --- | --- | --- |
| Project configuration and source registration | Partial | strict format-1 configuration/manifests and broad build-input registration | trust boundaries, all project limits, field propagation, and atomic invalidation guarantees |
| Migration discovery and offline schema replay | Partial | revision discovery, DAG validation, deterministic ordering, supported DDL replay, and merge-parent convergence for SQLite/PostgreSQL catalogs | full documented DDL/profile surface, downgrade checking, opaque directives, builtins, and supplements |
| SQL parsing, checking, and diagnostics | Partial | pinned `libpg_query`, named-parameter rewriting, named/embedded query discovery, semantic checks for the current subset, and human/versioned JSON diagnostics | source-manager/lexer limits, complete SQL surface, builtin catalogs, warnings, and diagnostic hardening |
| Generated checked-query bindings | Partial | deterministic named-query generation, embedded declaration verification, and build-cache module integration | stable generated metadata/query IDs, embedded PostgreSQL metadata, and final `Row`/`OwnedRow` contract |
| SQLite checked-query runtime | Partial | all four cardinalities, borrowed/owned rows, transactions, native pools, typed options, and enum codecs | non-STRICT storage validation, engine version enforcement, custom codecs, and poisoned-cleanup handling |
| PostgreSQL checked-query runtime | Partial | all four cardinalities, borrowed/owned rows, transactions, native pools, enum codecs, one-dimensional arrays, and server-version enforcement | zio socket proof, live TLS, finalized server errors, cancellation/timeouts, and dirty-connection recovery |
| Build integration and examples | Partial | lazy core/SQLite/PostgreSQL/both/TLS builds, host/target separation, offline checking, and runnable checked examples | complete invalidation matrix, atomic outputs, semantic cache keys, cross compilation, and release hardening |
| Stateful database migrations | Not started | no database planner, state store, journal, lock, runner, or generated runtime migration bundle; discovery/replay above is offline only | ordinary planner through SQLite/PostgreSQL runners, status/history/plan operations, and the runtime bundle; checkpoint extensions are deferred to 0.2 |
| Build-integrated CLI | Partial | registered-project routing for `bootstrap postgres` only | unified command shell, read-only and migration commands, confirmation, versioned JSON, and shared output/errors |
| SQLite-to-PostgreSQL bootstrap | Partial (experimental in 0.1; deferred to 0.2) | dedicated-schema reset, transactional private head replay, bound row transfer, sequence restoration, and one CI success path | shared migration primitives/state/journal/lock, stronger inspection and mapping, confirmation/JSON, and safety matrix |
| Security, compatibility, CI, and release gates | Partial | core offline/service-backed gates, PostgreSQL 15-18 runtime matrix, and initial security design | traceability, full platform/engine/fuzz/recovery matrix, performance baselines, frozen formats/APIs, and release gate |

The current dependency pins are Ziggy
`0b61581980d6905dd4108a618d602f5778593122`, zqlite
`b519eea9b1a2b5fcad68af6d0629e717e8746684`, and pg.zig
`f6442abf3fb0bbcf1007fac4799607f35688a89e`. The supported public runtime build
options are `sqlite`, `postgres`, and `postgres_tls`; no `sqlite_system` option is
implemented or claimed for 0.1.

## Implementation roadmap

Each milestone ends with its stated acceptance gate. Early milestones are not
separate compatibility promises. The 0.1 release is the minimal production cut
defined in [implementation-plan.md](implementation-plan.md#01-production-cut). It
requires each milestone only within that cut; checkpoint compaction, builtin
catalog supplements, telemetry, and the supported bootstrap are deferred to 0.2.

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
  cache integration, and lazy flags. Checkpoint-based history compaction for
  empty-database bootstrap is deferred to 0.2.
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

Django's replacement migrations and Flyway's baseline migrations inform sqlz's
proposed checkpoint lifecycle: old and compacted histories coexist during rollout,
fresh databases use a cumulative bootstrap, and source pruning is a separate
confirmed phase. sqlz differs by requiring offline catalog equivalence for every
targeted backend and preserving immutable revision identity in a compacted-history
registry.

Awebo's database code demonstrates a low-friction Zig interface built from
declarative query types, typed argument structs, typed column access, prepared
statements, and schema metadata. sqlz retains those ergonomic ideas while
removing manual SQL/metadata synchronization and compile-time SQL construction.
The relevant sources are
[Database.zig](https://codeberg.org/awebo-chat/awebo/src/branch/main/src/awebo/Database.zig),
[CommonQueries.zig](https://codeberg.org/awebo-chat/awebo/src/branch/main/src/awebo/Database/CommonQueries.zig),
and [tables.zig](https://codeberg.org/awebo-chat/awebo/src/branch/main/src/awebo/Database/tables.zig).
