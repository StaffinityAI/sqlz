# Migrations

sqlz uses an Alembic-like directed acyclic graph shared by SQLite and PostgreSQL.
A revision has an opaque ID, zero or more parents, and optional backend-specific
SQL. Parent edges—not timestamps or filenames—define order. Autogeneration/schema
diffing is outside 0.1.

## Files

```text
migrations/
  a1b2c3d4e5f6_create_users/
    revision.ziggy
    common.up.sql
    common.down.sql
    sqlite.up.sql
    sqlite.down.sql
    postgres.up.sql
    postgres.down.sql
```

IDs are 12 random lowercase hexadecimal characters. The directory prefix must
match the manifest. A format-1 manifest is:

```ziggy
{
  format_version: 1,
  revision: "a1b2c3d4e5f6",
  parents: [],
  description: "create users",
  created_utc: "2026-09-03T12:00:00Z",
  backends: [sqlite, postgres],
  reversible: true,
  transaction: { sqlite: always, postgres: always },
}
```

Unknown fields are errors. Parents are full unique IDs. `created_utc` is
informational. Backend entries are unique and canonical. Every targeted backend
needs non-empty effective upgrade SQL and, when reversible, downgrade SQL.
`transaction` has one policy per targeted backend: `always` or `never`; SQLite
supports only `always` in 0.1. PostgreSQL `never` permits reviewed operations such
as `CREATE INDEX CONCURRENTLY` while leaving boundary control to the runner. Merge
revisions have two or more parents and may be SQL-free; other accidental empty
revisions are rejected.

## Effective SQL

Upgrade runs `common.up.sql` then `<backend>.up.sql`; downgrade reverses that
layering. Common files apply only to listed backends. Files may interleave DDL and
DML. They must not contain transaction-control statements because the runner owns
transaction boundaries. Query annotations and named parameters are invalid in
migration SQL. Unsupported schema operations require a reviewed opaque catalog
directive and reduce the associated proof as documented by the checker.

## Graph and schema convergence

Validation covers manifests, IDs, parent existence, cycles, roots/heads, backend
coverage, downgrade completeness, and deterministic topological ordering. A node
is eligible only after all parents are applied. Independent eligible nodes are
ordered by ID solely for deterministic plans.

At a merge, the checker replays every parent path and requires equivalent resulting
schema catalogs for each backend. It cannot prove that DML effects converge; this
is explicitly the migration author's responsibility. Query checking targets the
sole graph head in 0.1. Multiple heads require a merge (or an explicit
investigative head outside release checking). Rolling-deployment checking against
several revisions is deferred.

## Planning and execution

Targets are `base`, a full or unambiguous ID prefix, `head`, `heads`, and linear
`+N`/`-N` forms. The planner computes ancestor closures, validates the complete
plan before mutation, upgrades topologically, and downgrades in reverse order. It
never removes a revision while retaining a child or crosses an irreversible
revision.

The runner acquires a project-scoped backend lock with a configurable 30-second
default timeout and never falls back to unlocked execution. PostgreSQL uses an
advisory lock and wraps `always` revisions in a transaction; SQLite uses an
immediate write transaction and busy timeout. A `never` revision is journaled
statement by statement. Backend operations that cannot satisfy the declared
policy are rejected during preflight.

## State, repair, and runtime use

Project UUID, semantic fingerprint, checksums, applied nodes, and command/step
journal semantics are normative in [migration-state.md](migration-state.md).
Mismatched identity, edited applied files, unknown revisions, or invalid ancestry
fail closed. Repair, rebind, downgrade, and prune are explicit confirmed actions.

The host command is `zig build sqlz -- ...`, documented in [cli.md](cli.md). The
runtime migration module embeds the same validated graph and exposes plan, status,
upgrade, and downgrade operations over a sqlz connection. It uses identical locks,
state upgrades, checksums, journaling, and structured Results; it does not shell out
or read source files at runtime.

## Tests

Fixtures cover linear histories, branches, merges from every parent path, no-op
backend nodes, irreversible preflight, checksum drift, identity mismatch, lock
contention/timeouts, interrupted journal steps, automatic state upgrades, and
equivalent CLI/runtime planning on both engines.
