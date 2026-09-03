# Checked query API

## Overview

sqlz supports two first-class ways to author a checked query:

1. put one named statement in a `.sql` file and let sqlz generate the complete
   Zig declaration; or
2. declare `sqlz.Query` in Zig with explicit parameter and row types, and let
   the external checker verify that metadata against the SQL.

Both forms use the same named-parameter syntax, cardinalities, executor
protocol, result handles, codec registry, and backend rules. SQL files minimize
metadata. Zig declarations keep a small query next to application code and make
domain types explicit. Neither form parses SQL at comptime.

## Named SQL files

A named SQL file contains exactly one statement and a leading directive block:

```sql
-- sqlz.name: get_user
-- sqlz.backends: sqlite, postgres
-- sqlz.cardinality: optional

SELECT id, display_name
FROM users
WHERE id = :id;
```

The recognized directives are:

| Directive | Required | Meaning |
| --- | --- | --- |
| `sqlz.name` | yes | Zig identifier used for the generated declaration |
| `sqlz.backends` | yes | comma-separated `sqlite`, `postgres`, or both |
| `sqlz.cardinality` | yes | `exec`, `one`, `optional`, or `many` |
| `sqlz.param.<name>` | no | registered codec ID overriding an inferred parameter type |
| `sqlz.column.<name>` | no | registered codec ID overriding an inferred result type |

Directives must precede the statement. Unknown or duplicate directives are
errors. Query names must be unique after Zig identifier normalization.

Two files may use the same query name only when their backend sets are disjoint.
This defines dialect variants of one logical query. Variants must have identical
cardinality, parameter names, result field names, Zig types, and nullability;
otherwise the checker reports both declarations. For example:

```sql
-- queries/search_users.sqlite.sql
-- sqlz.name: search_users
-- sqlz.backends: sqlite
-- sqlz.cardinality: many
SELECT id, display_name FROM users WHERE display_name LIKE :pattern;
```

```sql
-- queries/search_users.postgres.sql
-- sqlz.name: search_users
-- sqlz.backends: postgres
-- sqlz.cardinality: many
SELECT id, display_name FROM users WHERE display_name ILIKE :pattern;
```

The generator emits a declaration into the module configured as
`sqlz_queries`:

```zig
const queries = @import("sqlz_queries");

var result = try queries.get_user.fetchOptional(executor, .{ .id = user_id });
defer if (result) |*single| single.deinit();

if (result) |*single| {
    const user = single.row();
    std.debug.print("{d}: {s}\n", .{ user.id, user.display_name });
}
```

Generated source includes a comment pointing to the original SQL file, but no
absolute workspace path.

## Zig query declarations

An embedded query is a top-level or container-level constant initialized by a
direct call to `sqlz.Query`:

```zig
const sqlz = @import("sqlz");
const domain = @import("domain.zig");
const codecs = @import("codecs.zig");

pub const insert_user = sqlz.Query(.{
    .sql =
        \\INSERT INTO users (id, display_name)
        \\VALUES (:id, :display_name)
        \\RETURNING id, display_name;
    ,
    .backends = .{ .sqlite = true, .postgres = true },
    .cardinality = .one,
    .params = struct {
        id: domain.UserId,
        display_name: []const u8,
    },
    .row = struct {
        id: domain.UserId,
        display_name: []const u8,
    },
    .param_codecs = .{ .id = codecs.user_id },
    .column_codecs = .{ .id = codecs.user_id },
});
```

The `.row` field is omitted for `.exec`; it is required otherwise. `.params`
defaults to `struct {}`. Codec maps contain only overrides. The checker reports
missing and extra struct fields, wrong field order, nullability mismatches,
incompatible codecs, and SQL errors at the query declaration.

Discovery scans only Zig roots registered with `sqlz_build`. The SQL expression
must be one string literal or Zig multiline string literal. Concatenation,
formatting, function calls, conditional values, and imported SQL constants are
rejected because the checker does not execute Zig code. The declaration's
runtime type remains valid normal Zig code; only SQL analysis is external.

Embedded declarations expose the same method selected by cardinality as
generated declarations. An application must make its test or check step depend
on the returned `sqlz-check` step; compiling an embedded declaration alone is
not evidence that its SQL was checked.

## Backends and portability

Every query declares its backend set. A query targeting both backends is parsed
and checked independently against both migration-derived catalogs. It is not
restricted to a predeclared common grammar: it succeeds when the text is valid
and has the same typed contract on each backend.

If equivalent operations require different SQL, use disjoint variants with the
same query name. If the contracts differ, give the queries different names and
treat them as backend-specific API.

The checker always validates every declared backend. Runtime methods are emitted
only for adapters enabled in the current build, so checking portable SQL does
not fetch or link both drivers.

## Named parameters

Checked queries use `:name` in every dialect. Names must be valid Zig identifiers
and are case-sensitive. The lexer ignores parameter-like text in comments,
quoted strings, quoted identifiers, and dollar-quoted PostgreSQL strings. It
recognizes `value::type` as a PostgreSQL cast, not a parameter.

The generated parameter struct is ordered by first appearance. Reusing a name
reuses its ordinal and requires one argument:

```sql
SELECT id
FROM users
WHERE email = :identity OR display_name = :identity;
```

This emits one `identity` field. Before execution, sqlz rewrites parameters to
`?1`, `?2`, ... for SQLite and `$1`, `$2`, ... for PostgreSQL. Rewriting is done
from lexer spans, never by textual search and replace.

The semantic analyzer gathers constraints from every use. Conflicting uses are
an error. A parameter whose type cannot be inferred requires a
`sqlz.param.<name>` directive or a codec entry in the Zig declaration.

Dynamic identifiers, keywords, SQL fragments, sort directions, and list lengths
cannot be parameters. Applications must choose among separately checked static
queries or use a raw backend API for genuinely dynamic SQL.

## Cardinality and execution

Cardinality is an explicit API contract:

| Cardinality | Generated method | Return shape |
| --- | --- | --- |
| `exec` | `execute(executor, args)` | `!sqlz.ExecResult` |
| `one` | `fetchOne(executor, args)` | `!Single(Row)`; `error.NoRows` if empty |
| `optional` | `fetchOptional(executor, args)` | `!?Single(Row)` |
| `many` | `fetch(executor, args)` | `!Rows(Row)` |

`ExecResult.rows_affected` is `?u64`: both adapters provide a number when their
driver does, and `null` when the command has no meaningful count. Backend-
specific information such as SQLite's last inserted row ID stays on the native
adapter; portable code should use `RETURNING` when it needs generated values.

`one` and `optional` mean “fetch the first row with the stated empty-result
behavior.” They do not prove uniqueness. A query that relies on uniqueness must
express it through a unique constraint or query predicate. The checker may warn
when a `one` query is visibly unconstrained, but it must not reject valid SQL
based on a heuristic.

An `exec` query must not expose result columns. A statement with `RETURNING` must
use a row-returning cardinality. Multiple SQL statements in one checked query
are rejected.

## Result ownership

### Single rows

`Single(Row)` owns the native result or statement that keeps a borrowed row
valid. It is non-copyable by convention and must be deinitialized:

```zig
var single = try queries.get_user.fetchOne(executor, .{ .id = id });
defer single.deinit();

const row = single.row();
use(row.display_name); // valid until single.deinit()
```

`row()` returns a generated value containing scalars and borrowed slices. Calling
`deinit` invalidates every slice obtained from it. `deinit` is infallible and
performs the backend cleanup needed for this single-row operation.

### Multiple rows

`Rows(Row)` owns the native statement/result and exposes:

```zig
pub fn next(self: *Rows) !?Row;
pub fn drain(self: *Rows) !void;
pub fn deinit(self: *Rows) void;
```

A row returned by `next` is valid until the next `next`, `drain`, or `deinit`.
Iterating until `next` returns `null` fully consumes the result. A caller that
breaks early must call `drain` before `deinit` if it wants errors reported and a
PostgreSQL pooled connection reused:

```zig
var rows = try queries.list_users.fetch(executor, .{});
defer rows.deinit();

while (try rows.next()) |row| {
    if (shouldStop(row)) {
        try rows.drain();
        break;
    }
}
```

`deinit` always releases local resources. If PostgreSQL data remains unread and
`drain` was not called, the adapter must discard or mark the connection
unhealthy rather than returning it as reusable. It cannot hide a drain error in
an infallible destructor.

### Owned rows

Every generated row view with borrowed fields exposes:

```zig
pub fn toOwned(row: Row, allocator: std.mem.Allocator) !OwnedRow;
```

`OwnedRow` duplicates text, blob, JSON, and codec-declared borrowed fields.
Scalars are copied. It exposes `deinit(allocator)` and is independent of the
result after conversion. A row containing only scalars may use the same shape
for `Row` and `OwnedRow`, but both names remain available for generated API
stability.

Partial allocation failure frees all fields already copied. A custom codec must
provide ownership hooks when its decoded Zig type contains borrowed memory.

## Database and Zig types

The initial built-in portable mappings are:

| Zig type | SQLite | PostgreSQL |
| --- | --- | --- |
| `bool` | integer boolean | `boolean` |
| `i16`, `i32`, `i64` | checked conversion from integer | `smallint`, `integer`, `bigint` |
| `f32`, `f64` | real | `real`, `double precision` |
| `[]const u8` | text | text-compatible types |
| `sqlz.Blob` | blob | `bytea` |
| `sqlz.Uuid` (`[16]u8`) | 16-byte blob | `uuid` |
| `sqlz.Json` | text | `json` or `jsonb` |
| `sqlz.Date` | ISO date text | `date` |
| `sqlz.Timestamp` | signed microseconds from Unix epoch | timestamp without time zone |
| `sqlz.TimestampTz` | signed UTC microseconds from Unix epoch | timestamp with time zone |

`?T` maps SQL `NULL` for every supported `T`. A nullable expression cannot map
to a non-optional Zig field. A non-null SQL expression may map to `?T` only with
an explicit override; widening to optional is safe but should remain visible in
the declaration.

Unsigned integers have no default portable mapping because PostgreSQL lacks
matching integer types and SQLite stores signed 64-bit integers. Applications
may use a checked custom codec.

SQLite type analysis uses declared type names, affinity, constraints, expression
rules, and explicit casts. It never claims stronger runtime typing than those
facts justify. Ambiguous SQLite expressions require an override.

## Custom codecs

A codec has a stable string ID used by SQL directives and a Zig declaration
registered through `sqlz_build`. Its contract supplies:

- the Zig value type;
- accepted database type patterns per backend;
- parameter encoding for each enabled backend;
- result decoding for each enabled backend;
- whether the decoded value borrows result storage;
- `cloneOwned` and `deinitOwned` when it borrows or owns resources.

A codec declaration has this structural interface, with backend methods required
only for backends that the registration supports:

```zig
pub const user_id = struct {
    pub const sqlz_codec_id = "user_id";
    pub const Value = UserId;
    pub const Owned = UserId;
    pub const borrows_result = false;

    pub fn bindSqlite(
        binder: *sqlz.sqlite.Binder,
        index: u32,
        value: Value,
    ) !void;
    pub fn decodeSqlite(
        decoder: *const sqlz.sqlite.Decoder,
        index: u32,
    ) !Value;

    pub fn bindPostgres(
        binder: *sqlz.postgres.Binder,
        index: u32,
        value: Value,
    ) !void;
    pub fn decodePostgres(
        decoder: *const sqlz.postgres.Decoder,
        index: u32,
    ) !Value;
};
```

When `borrows_result` is `true`, `Owned` may differ from `Value` and the codec
must also define:

```zig
pub fn cloneOwned(allocator: std.mem.Allocator, value: Value) !Owned;
pub fn deinitOwned(allocator: std.mem.Allocator, value: *Owned) void;
```

When it is `false`, generated code copies `Value` into `Owned`; both types must
therefore be identical and ownership hooks must be absent. Binder and decoder
are narrow adapter types rather than raw driver values, keeping codec code
testable and making parameter/result indexes consistently zero-based.

The generated module verifies the Zig codec shape and `sqlz_codec_id` at
compilation. The external checker maps a Zig override such as `codecs.user_id`
through the build registration's `import_name` and `declaration`, then uses the
registered ID and database patterns to validate SQL. Query source must use the
same import name registered with the build helper. Codec IDs and
import/declaration pairs must be unique; changing a registration participates in
the query cache fingerprint.

Enums and ID newtypes should normally use codecs instead of manually converting
at every call. A codec is responsible for range validation and returns a decode
error rather than trapping on invalid database data.

## Executors, connections, and transactions

Checked methods accept a backend adapter implementing sqlz's static executor
protocol. Public adapters cover:

- `sqlz.sqlite.Conn`, `sqlz.sqlite.Pool`, and `sqlz.sqlite.Transaction`;
- `sqlz.postgres.Conn`, `sqlz.postgres.Pool`, and
  `sqlz.postgres.Transaction`.

Construction remains backend-specific. Each wrapper exposes `raw()` for driver
features outside sqlz's checked surface.

`begin` returns a transaction owning or borrowing one native connection.
`commit` and `rollback` consume its active state. Dropping an active transaction
without either operation attempts rollback; explicit `rollback` is required
when the caller needs rollback errors. Nested transactions/savepoints are not a
0.1 guarantee.

Queries executed in a transaction must receive that transaction as executor.
A result handle must be drained or deinitialized before commit or rollback.

## Preparation and caching

Generated queries are always parameterized. Each adapter may use the driver's
preferred prepare/cache mechanism:

- SQLite prepares per connection and resets a statement after use. A connection
  may cache statements by generated query ID.
- PostgreSQL uses `pg.zig` preparation behavior and must not share a prepared
  statement across unrelated connections.

Preparation is an optimization, not part of application-visible correctness.
Cache eviction must finalize or release native statements. A schema-change error
may invalidate and reprepare once; other errors are returned without implicit
retry.
