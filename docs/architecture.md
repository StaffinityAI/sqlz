# Architecture

## Overview

sqlz consists of a backend-neutral host toolchain, generated query and migration
modules, a small runtime core, and optional backend adapters.

```text
migration files ──> revision graph ──> dialect DDL parser ──> catalog
                                                               │
.sql queries ─────> source discovery ─┐                        │
                                     ├─> SQL parser ─> semantic checker
Zig Query values ─> Zig AST discovery┘                        │
                                                               ├─> diagnostics
codec declarations ────────────────────────────────────────────┤
                                                               └─> generated Zig
                                                                     │
                                      application <── sqlz runtime adapters
```

The host checker owns all SQL syntax and semantic analysis. Generated Zig owns
the statically typed call surface. Runtime adapters own binding values, invoking
the driver, decoding values, resetting or draining results, and translating
driver failures into sqlz errors.

## Component boundaries

### Source and diagnostics

The source layer assigns a stable file ID to every migration, SQL query, and Zig
query declaration. It stores original bytes and line-start offsets. Every lexer,
parser, catalog, and semantic node that can produce an error carries a source
span rather than a copied filename and line number.

The diagnostic layer accepts a primary span, message, severity, secondary
labels, notes, and help text. It renders compiler-style output to stderr. The
checker returns a non-zero status after rendering all independent errors it can
recover from; it does not stop at the first parse or semantic error.

### SQL syntax

The syntax package contains:

- one lexer that preserves comments and source positions and recognizes named
  `:parameters` without confusing PostgreSQL `::casts`;
- common AST nodes for statements, expressions, names, queries, and DDL;
- SQLite and PostgreSQL parser policies for dialect-specific constructs;
- a formatter used only for debugging and snapshot tests, not for rewriting
  user SQL.

The parser must not import either database driver. Unsupported syntax produces a
normal diagnostic rather than an `unreachable`, assertion failure, or inferred
meaning.

### Migration graph and catalog

The migration package loads revision manifests, validates their DAG, selects an
execution path, and exposes each backend's ordered SQL stream. The catalog
replayer parses the upgrade stream into an in-memory schema. Catalog changes are
applied by semantic DDL operations, not by running SQLite or PostgreSQL.

Catalog objects retain their originating revision and source span. A query error
can therefore point both to the query reference and to the migration that
declared or last changed the referenced object.

Query checking requires one effective graph head. A repository may contain
branches, but it must add a merge revision before the checker can choose a
single schema. Migration commands continue to understand multiple database
heads so they can repair or merge deployed histories.

### Query analyzer and generator

The query analyzer resolves names, scopes, joins, expressions, parameters,
result columns, database types, and nullability against a catalog and dialect.
It produces a backend-neutral checked-query intermediate representation (IR).
The IR contains no driver objects and includes:

- query name, source span, target backends, and cardinality;
- normalized named parameters in first-use order;
- backend-specific emitted SQL and positional parameter indexes;
- parameter database types and codec IDs;
- ordered result fields, database types, Zig types, and nullability;
- referenced catalog objects, used for diagnostics and cache fingerprints.

The generator consumes only this IR. It emits deterministic Zig source into the
build cache. File ordering, declaration ordering, and diagnostic ordering must
not depend on hash-map iteration.

### Runtime core

The always-available `sqlz` module contains backend-neutral public contracts:
cardinality, execution metadata, error classification, codecs, generated row
helpers, migration targets, and migration reports. It has no import of
`zqlite` or `pg`.

When enabled, `sqlz.sqlite` and `sqlz.postgres` expose adapters around native
connections, pools, transactions, statements, rows, and driver errors. Adapters
must expose access to the underlying driver value for unchecked operations.
They do not attempt to make connection construction identical: PostgreSQL needs
`std.Io` and authentication/network options, while SQLite needs a path and open
flags.

## Query build flow

1. The consumer registers migration, `.sql`, Zig-query, and codec roots through
   `sqlz_build`.
2. The host tool hashes its version, configuration, and registered inputs.
3. It loads and validates the shared migration graph.
4. For every selected backend, it resolves the single head and replays upgrade
   SQL into a catalog.
5. It discovers named SQL files and static `sqlz.Query` declarations. Zig
   discovery uses Zig's AST and accepts literal strings only; it does not
   evaluate arbitrary Zig expressions.
6. It parses and checks every declaration for every backend named by that
   declaration, regardless of which runtime backend is enabled. This prevents a
   portable query from silently rotting on a developer who enables only one
   driver.
7. It emits all diagnostics. If no errors occurred, it atomically replaces the
   cached generated module and metadata.
8. Zig compiles the generated module with imports only for enabled runtime
   adapters. A checked query targeting a disabled backend remains checked but
   cannot be executed through that backend in the current build.

Embedded `sqlz.Query` declarations use Zig types for their runtime contract.
The checker reads their static syntax and codec annotations; generated
compile-time assertions verify that referenced Zig types implement the declared
codec. SQL parsing, name resolution, and type inference remain exclusively in
the host checker. A Zig compiler type error may therefore report a malformed
codec implementation, but never an SQL syntax or schema error.

## Backend adaptation

| Concern | SQLite / `zqlite` | PostgreSQL / `pg.zig` | Shared guarantee |
| --- | --- | --- | --- |
| Connection setup | file/URI and open flags | `std.Io`, network and auth options | setup remains backend-specific |
| Pools | synchronous acquire/release | fallible acquire with timeout | both implement the executor protocol |
| Parameters | `?N` generated from `:name` | `$N` generated from `:name` | one typed argument struct |
| Row storage | SQLite statement-owned values | result-buffer-owned values | row views never outlive their result |
| Many rows | statement iterator with stored error | fallible network iterator | `next()` is always fallible |
| Early stop | reset/finalize statement | drain result before reuse | public rows expose `drain()` |
| Prepared statements | driver statement wrapper | server/client statement wrapper | adapter controls preparation policy |
| Raw access | underlying `zqlite` value | underlying `pg` value | explicit `raw()` escape hatch |

The common API is a shared convention, not a runtime virtual interface. Generated
query functions are statically specialized for the executor type supplied by
the application. Enabling both backends does not add an `anytype` runtime tag or
force the application to pay for dynamic dispatch.

## Errors

Build-time failures are diagnostics and process exit status. Runtime operations
return errors; the library never logs, panics, exits, or retries without an
explicit caller policy.

The runtime core defines a small classification enum for portable handling:

```zig
pub const ErrorClass = enum {
    constraint,
    unavailable,
    timeout,
    cancelled,
    protocol,
    invalid_data,
    other,
};
```

Backend adapters retain the original error and expose `classifyError`. Generated
queries use inferred error sets where practical and do not erase native driver
errors into a single `anyerror` value. Decode failures name the query and column
in debug context but do not allocate error strings on the success path.

## Cache and reproducibility

Generated files live under Zig's build cache and are never source inputs. A
cache key includes:

- sqlz checker and generator version;
- complete bytes and relative paths of migration and query inputs;
- migration target head and backend set;
- codec registry and query configuration;
- generated API format version.

Absolute workspace paths, database credentials, timestamps, and hash-map order
must not affect generated bytes. Output is written to a temporary cache entry
and renamed only after successful checking, so a failed run cannot leave a
partially updated module.

## Concurrency and ownership

sqlz adds no global mutable runtime state. Pools retain their driver's thread-
safety properties. A transaction and any rows borrowed from it remain tied to
the same native connection. The generated API does not allow a result handle to
be copied; `deinit`, `drain`, commit, and rollback receive mutable pointers where
needed to make ownership visible.

Zig cannot encode every borrow lifetime in the type system. The API therefore
uses short-lived row views, documents their exact invalidation points, supplies
owned conversion, and tests misuse-prone transitions. Debug builds may poison
or assert invalid result states, but release correctness must not depend on
those assertions.
