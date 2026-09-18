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

## Checkpoints and history compaction

A checkpoint is an alternate root used only to create an empty database at the
schema state of an existing historical revision. It is distinct from a merge:
a merge joins multiple heads while retaining their ancestors; a checkpoint
replaces replay of a closed ancestor set for fresh databases.

Checkpoint metadata is introduced by a migration manifest format newer than
format 1. The tagged declaration contains:

- `through`: the historical revision whose resulting schema the checkpoint
  represents;
- `replaces`: the exact canonical ancestor closure through that revision,
  including `through` itself;
- `scope`: `empty_database` in the initial implementation.

The planned format-2 shape is:

```ziggy
.format_version = 2,
.revision = "ffffffffffff",
.parents = [],
.description = "checkpoint through 9abc1234def0",
.created_utc = "2026-09-18T12:00:00Z",
.backends = [.sqlite, .postgres],
.reversible = false,
.transaction = .{ .sqlite = .always, .postgres = .always },
.kind = .{ .checkpoint = .{
  .through = "9abc1234def0",
  .replaces = [
    "aaaaaaaaaaaa",
    "bbbbbbbbbbbb",
    "9abc1234def0",
  ],
  .scope = .empty_database,
} },
```

Ordinary format-2 manifests use `.kind = .revision`; format-1 manifests are
interpreted identically to `.kind = .revision`. A checkpoint ID shares the global
revision-ID namespace and cannot collide with an ordinary revision, another
checkpoint, or a finalized historical ID.

A checkpoint has no parents, is irreversible in the initial implementation, and
uses the same common/backend SQL files and transaction policies as ordinary
revisions. Its effective upgrade SQL must be non-empty for every targeted backend.
The replacement set must exist, be closed under parents, have exactly `through`
as its sole head, target every backend named by the checkpoint, and contain no
revision outside the ancestor closure of `through`.
Backend coverage may be a subset of the historical boundary for bootstrap, but
source finalization requires every backend targeted by each removed revision to be
covered at the same `through` boundary. A shared/common revision cannot be pruned
while any of its target backends still relies on historical replay.

Checkpoint nodes are excluded from ordinary DAG root/head counting, branch merge
validation, and query-head selection. They form a separate bootstrap index keyed
by logical `through` revision. Descendant revisions continue to reference the
ordinary historical graph; planners project a selected checkpoint to the logical
applied closure through `through`.

For each targeted backend, validation replays the original ancestor closure and
the checkpoint independently and requires equivalent catalog snapshots. Object
identity, type identity, constraints, indexes, views, and other checked catalog
facts participate in equivalence. DML effects do not; authors are responsible for
the suitability of checkpoint SQL for an empty database. Opaque catalog directives
reduce or prevent the equivalence proof and must be reported explicitly.

Checkpoint SQL may include deterministic seed/reference DML required by a fresh
database. Such DML is checksummed and executed, but catalog equivalence cannot
prove its data result. Review output lists DML-bearing checkpoint files and final
verification requires an explicit author acknowledgement. Environment-specific,
row-copying, or live-data transformation SQL is invalid for `empty_database`
checkpoints.

The planner selects a checkpoint only when the destination has no applied sqlz
migration history and destination inspection confirms the allowed empty baseline.
The sqlz internal state schema/tables may already exist, but the applied set,
checkpoint/adoption records, and incomplete command set must be empty. Configured
application namespaces must contain no user objects; backend/system objects and
sqlz's internal objects are ignored. It chooses
the eligible checkpoint whose `through` revision is the unique maximal ancestor
of the requested target. Two candidates with the same `through`, or incomparable
maximal candidates, are ambiguous and rejected rather than ordered by timestamp or
ID. It then continues with descendants after
`through`; the checkpoint revision itself is bootstrap evidence, not a replacement
public head. A database with any applied historical revision never jumps to a
checkpoint and continues along the original graph.

Adoption at or beyond `through` requires the database's applied closure to contain
every revision in `replaces` with matching parents and checksums. Merely having a
descendant ID is insufficient when state is inconsistent. A checkpoint-bootstrapped
database may downgrade descendants back to the logical `through` boundary but not
below it.

Checkpoint and historical sources coexist until explicit finalization. New
revisions must not depend on the checkpoint ID or on revisions strictly inside a
finalized replacement set; they continue from `through` or its descendants. A
checkpoint may not replace another checkpoint until the earlier transition has
been finalized. Downgrade across a checkpoint boundary is unsupported in the
initial implementation.

Finalization is a destructive source-history operation, not a database migration.
It verifies replacement metadata and current project state, emits the exact files
eligible for removal, requires confirmation, and records a durable tombstone in
`migrations/history.ziggy`. Databases record bootstrap/adoption evidence when they
are individually migrated or adopted; finalization cannot mutate unknown remote
deployments. The versioned history registry
stores pruned revision IDs, canonical parent sets, checksums, replacement
checkpoint IDs, and logical boundaries, but never executable SQL. It cannot prove
that every deployment in the world has crossed the boundary; that remains an
operator assertion. Source deletion occurs as a separate version-control change
and must not silently rewrite an existing manifest or checksum.

The planned registry shape is a versioned list sorted by revision ID:

```ziggy
.format_version = 1,
.entries = [.{
  .revision = "aaaaaaaaaaaa",
  .parents = [],
  .manifest_checksum = "...",
  .content_checksum = "...",
  .checkpoint = "ffffffffffff",
  .through = "9abc1234def0",
}],
```

The registry itself has a canonical checksum included in semantic configuration,
runtime bundles, and database checkpoint state.

After finalization, a database at or beyond `through` remains recognizable and can
continue with later descendants. A database below `through` cannot be upgraded
because its required SQL has intentionally been pruned; planning fails with a
specific error that names the unavailable revisions and checkpoint. Operators must
run an older source release containing those migrations or perform an explicit
repair. Revision IDs listed in the history registry remain permanently reserved.

For offline checking after pruning, history-registry entries are virtual graph
nodes carrying identity but no SQL. The validated checkpoint catalog is the schema
snapshot at `through`; the checker applies live descendants from that snapshot and
still targets the ordinary logical head. If the checkpoint source needed for that
snapshot is missing or fails verification, checking fails closed.

Repeated compaction is supported only after the previous checkpoint is finalized.
A later checkpoint's `replaces` list names the complete logical ancestor closure,
including pruned ordinary IDs from `history.ziggy` and live ordinary IDs through
the new boundary. The verifier composes the prior checkpoint snapshot with the live
suffix. It never treats a checkpoint ID as an ancestor or permits nested coexistence
transitions.

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
equivalent CLI/runtime planning on both engines. Checkpoint fixtures additionally
cover catalog equivalence, fresh selection, partial historical deployments,
adoption at/beyond the boundary, coexistence, ambiguous checkpoints, source
finalization, and refusal to cross a checkpoint on downgrade.
