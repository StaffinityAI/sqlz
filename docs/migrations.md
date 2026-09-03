# Migrations

## Model

sqlz migrations form one revision-directed acyclic graph shared by SQLite and
PostgreSQL. A revision has an opaque ID, zero or more parents, and optional SQL
for each backend. Parent links define order; filenames and timestamps do not.

The shared graph lets one application version name one logical schema state even
when backend DDL differs. A revision that changes only one backend remains a
logical no-op on the other backend and is recorded there, preserving the same
head IDs.

Migration autogeneration is not part of 0.1. The tool creates revision skeletons;
developers write and review SQL.

## Directory layout

The default root is `migrations/`. Each immediate child is one revision:

```text
migrations/
  a1b2c3d4e5f6_create_users/
    revision.json
    common.up.sql
    common.down.sql
    sqlite.up.sql
    sqlite.down.sql
    postgres.up.sql
    postgres.down.sql
```

The directory begins with the revision ID and an underscore followed by a
filesystem-safe descriptive slug. The manifest ID is authoritative. Directory
names must be unique; a mismatched prefix is an error.

Revision IDs are 12 lowercase hexadecimal characters generated from
cryptographically secure random bytes. They are not timestamps and have no
ordering meaning. Slugs use lowercase ASCII words separated by underscores and
are limited to 48 characters.

## Manifest

`revision.json` uses this versioned schema:

```json
{
  "format": 1,
  "revision": "a1b2c3d4e5f6",
  "parents": [],
  "description": "create users",
  "created_utc": "2026-09-03T12:00:00Z",
  "backends": ["sqlite", "postgres"],
  "reversible": true,
  "transaction": {
    "sqlite": "always",
    "postgres": "always"
  }
}
```

Rules:

- `format` must be `1`.
- `revision`, `parents`, and `description` are required.
- `parents` contains zero or more full revision IDs with no duplicates. Only a
  root has no parents.
- `created_utc` is informational RFC 3339 UTC and does not affect ordering.
- `backends` lists the backends whose schemas this revision changes. It has
  unique entries in canonical `sqlite`, `postgres` order.
- `reversible` states whether every targeted backend has an effective downgrade.
- `transaction` has exactly one entry per targeted backend. Values are `always`
  or `never`.
- SQLite supports only `always` in 0.1. PostgreSQL `never` is reserved for DDL
  such as `CREATE INDEX CONCURRENTLY` that cannot run in a transaction.
- Unknown fields are errors so a misspelled safety setting is never ignored.

A merge revision has two or more parents and may have an empty `backends` list.
Such a revision changes graph state without changing either schema. An ordinary
zero-SQL revision must also have multiple parents; accidental empty migrations
are otherwise rejected.

## Effective SQL

For a targeted backend, an upgrade executes:

1. `common.up.sql`, if present;
2. `<backend>.up.sql`, if present.

A downgrade reverses the layering:

1. `<backend>.down.sql`, if present;
2. `common.down.sql`, if present.

This lets common SQL create a table before backend-specific indexes on upgrade
and lets backend-specific objects be removed before the common table on
downgrade.

Every backend named in `backends` must have a non-empty effective upgrade.
Backend SQL for a backend absent from `backends` is an error. Common SQL applies
only to the named backends, not implicitly to every supported backend.

When `reversible` is `true`, every targeted backend must have a non-empty
effective downgrade. When it is `false`, down files are rejected to keep the
intent unambiguous. Crossing an irreversible revision during downgrade fails
during preflight before any revision is changed.

SQL files contain zero or more statements and may use the migration-only opaque
directive described in [sql-checker.md](sql-checker.md). Query directives and
named parameters are invalid in migration SQL.

## Graph validation

Before checking or executing anything, sqlz validates:

- manifest schema and directory/ID agreement;
- globally unique revision IDs;
- existing parent references;
- absence of self-edges and cycles;
- at least one root and one head;
- SQL/backend coverage and reversibility rules;
- deterministic topological ordering;
- a merge revision does not introduce an ambiguous backend schema.

Independent nodes are ordered by revision ID only to make plans and logs stable.
That tie breaker does not imply a dependency. A revision is eligible to apply
only after all parents are recorded.

Query checking defaults to the graph's sole head. If multiple heads exist, the
checker stops and lists them; the developer must add a merge revision or select
an explicit head for investigative use. Release builds should not select an
explicit divergent head.

## Database state

sqlz owns a table named `_sqlz_revisions` in the database's default application
schema:

```sql
revision       text primary key
checksum       text not null
state          text not null  -- applying, applied, or noop
applied_at     text not null  -- RFC 3339 UTC
execution_ms   integer null
```

There is one row for every applied graph node, including backend no-ops. The set
of applied rows, not one scalar version, represents the database's current
heads.

The checksum is SHA-256 over a canonical stream containing:

- the exact manifest bytes;
- relative names and exact bytes of effective up and down files;
- the backend name;
- the migration format version.

Previously applied checksums are verified before every mutating command. A
mismatch is an error that identifies the revision and changed file; sqlz never
updates a stored checksum automatically.

Unknown database revision IDs are errors because the local graph cannot safely
plan from them. Missing ancestor rows, an applied child with an unapplied parent,
and invalid state values are database-state errors.

## Targets and planning

Targets are:

- `base`: the empty applied set;
- a full revision ID;
- an unambiguous revision ID prefix of at least four characters;
- `head`: valid only when the source graph has one head;
- `heads`: all source heads;
- relative `+N` for upgrade and `-N` for downgrade from one current head.

Relative targets are rejected when the current or destination graph is branched.

Upgrade computes the target's ancestor closure, subtracts applied revisions, and
applies the remaining nodes in topological order. Downgrade removes applied
nodes outside the target closure in reverse topological order. It refuses to
remove a revision while retaining an applied child.

The complete plan is validated before execution: graph, checksums, effective SQL,
reversibility, backend support, transaction policy, and current database state.
Planning failure makes no database changes.

## Locking and atomicity

Only one sqlz migration operation may mutate a database at a time.

### PostgreSQL

The runner obtains a session-level advisory lock before inspecting migration
state and holds it until the operation ends. The two-key lock uses the current
database OID as its namespace and a fixed sqlz migration key, avoiding contention
between databases in the same cluster.

For an `always` revision, the runner:

1. commits an `applying` state row;
2. begins a transaction;
3. executes all effective SQL statements in order;
4. updates the row to `applied` or `noop` with timing;
5. commits.

Failure rolls back schema changes and leaves `applying` visible for diagnosis.

For a `never` revision, the runner records `applying`, executes statements one
at a time outside a transaction, and marks the row applied only after all
succeed. Failure may leave partial database changes and always leaves the dirty
row. No later mutating command runs until an operator repairs state.

### SQLite

SQLite migration runs use one outer `BEGIN IMMEDIATE` transaction, which is also
the migration lock. Each revision uses a savepoint for accurate error context.
All selected revisions and state changes commit together. On failure the outer
transaction rolls back, so another process sees the pre-run schema and state.

SQLite `transaction: "never"` is rejected in 0.1. Busy/locked errors are returned
according to the connection's configured busy timeout; sqlz does not add an
unbounded retry loop.

## Dirty state and repair

An `applying` row is dirty state. Mutating commands refuse to run while any dirty
row exists. Read-only commands continue and highlight the dirty revision.

Recovery is intentionally manual:

1. inspect the database and the failed revision;
2. complete or reverse partial SQL outside sqlz as appropriate;
3. run `stamp <target> --repair --yes` to replace recorded state with the target
   ancestor closure and current checksums.

`--repair` is required to clear dirty rows. It prints every state change before
prompting unless `--yes` was supplied. The runtime API exposes repair only
through a separately named unsafe operation; normal startup migration cannot
stamp or repair.

## Command surface

Commands run through:

```text
zig build sqlz-migrate -- <command> [arguments]
```

Common connection arguments are `--backend sqlite|postgres` and
`--database <path-or-uri>`. `--database` takes precedence over
`SQLZ_DATABASE_URL`. The CLI never reads a checked-in credential file and
redacts passwords in output.

Commands:

- `revision --message <text> --backend <name>...` creates a child of the sole
  head with a manifest and empty up/down files. `--parent <id>` is required when
  multiple heads exist.
- `merge --message <text> <head>...` creates a graph-only revision whose parents
  are the supplied heads.
- `upgrade [target]` applies to `head` by default and prints the plan before
  execution.
- `downgrade <target>` reverts to an explicit target; there is no dangerous
  implicit default.
- `current` displays database heads, dirty rows, and source-graph relationship.
- `history [--from <target>] [--to <target>]` prints deterministic revision
  history without connecting unless `current` is used as a target.
- `heads` lists source heads and indicates which are applied.
- `branches` lists branch points, their children, and merge descendants.
- `status` validates source graph, database state, checksums, and pending plan
  without changing either.
- `stamp <target> --yes` replaces recorded state without executing SQL.
  `--repair` is additionally required if state is dirty or inconsistent.

All mutating commands support `--dry-run`, which performs complete preflight and
prints revisions and SQL filenames without connecting in a transaction or
changing state. `revision` and `merge` are filesystem-generating commands and do
not accept `--dry-run`.

## Runtime migration API

`sqlz_build` can generate an embedded migration module. Applications import it
and invoke:

```zig
const app_migrations = @import("sqlz_migrations");

const report = try app_migrations.migrator.upgrade(executor, .head);
```

The generated module contains manifests, effective SQL, graph edges, and source
checksums. It does not read migration files at runtime. The public operations
are:

```zig
pub fn planUpgrade(executor: anytype, target: sqlz.MigrationTarget) !Plan;
pub fn upgrade(executor: anytype, target: sqlz.MigrationTarget) !Report;
pub fn planDowngrade(executor: anytype, target: sqlz.MigrationTarget) !Plan;
pub fn downgrade(executor: anytype, target: sqlz.MigrationTarget) !Report;
pub fn current(executor: anytype, allocator: std.mem.Allocator) !CurrentState;
```

The runtime API does not create revisions, merge source graphs, stamp, repair,
or accept arbitrary database URLs. The caller supplies an initialized backend
executor and owns logging or presentation. `Report` includes starting and final
heads, ordered revision results, no-op revisions, and elapsed time.

Automatic startup migration should call `upgrade(.head)` and fail application
startup on any error. sqlz does not downgrade automatically.

## Migration tests

- Manifest tests cover every validation rule and unknown field.
- Graph tests cover roots, linear histories, branches, merges, cycles, missing
  parents, prefixes, closures, and deterministic plans.
- File tests cover common/backend ordering, missing effective SQL, irreversible
  revisions, CRLF, and checksum changes.
- SQLite integration tests cover new databases, existing histories, concurrent
  attempts, rollback of a multi-revision run, no-op nodes, and downgrade.
- PostgreSQL integration tests cover advisory locking, per-revision rollback,
  dirty non-transactional failure, repair, branches, and checksum drift.
- Runtime bundle tests prove embedded and filesystem-loaded graphs plan and
  execute identically.
