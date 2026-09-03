# SQL checker and binding generator

## Purpose

`sqlz-check` is a host executable that parses migrations and queries, reconstructs
backend schemas, checks query contracts, and produces generated Zig modules. It
exists outside Zig comptime so it can recover from multiple errors and render
source-oriented diagnostics with labels and suggestions.

The checker is deterministic and offline. It never opens SQLite, connects to
PostgreSQL, reads a database URL, or asks a backend server to prepare a query.

## Inputs and outputs

The build helper supplies a machine-readable invocation containing:

- workspace-relative migration root;
- one or more named-SQL roots;
- one or more Zig roots containing `sqlz.Query` declarations;
- codec IDs and their accepted database type patterns;
- the backends to analyze;
- the required migration head, defaulting to the graph's sole head;
- cache and generated-output paths owned by Zig's build graph.

Inputs are canonicalized and deduplicated. A path outside the package root is
allowed only when the consumer explicitly registers it; diagnostics still avoid
embedding its absolute path into generated code.

Successful output contains:

- a Zig module for named `.sql` queries;
- backend SQL and checked metadata needed by embedded declarations;
- an embedded migration bundle when requested;
- a dependency manifest listing every file read;
- a versioned metadata file used for cache validation.

No generated output is replaced when checking fails.

## Front end

### Source manager

Files are read as UTF-8. A UTF-8 byte order mark is accepted and excluded from
source columns. Invalid UTF-8 produces a byte-accurate diagnostic and prevents
parsing that file. Source offsets are byte offsets; displayed columns count
Unicode scalar values and tabs use a fixed width of four for caret rendering.

Line endings may be LF or CRLF and are normalized only in the source manager's
line index. Original bytes participate in checksums and diagnostics.

### Lexer

The shared lexer recognizes:

- identifiers, quoted identifiers, keywords, numbers, operators, punctuation,
  comments, and statement terminators;
- ordinary and dialect-specific string literal forms;
- PostgreSQL dollar-quoted strings and `::` casts;
- SQLite bracket/backtick identifiers where the dialect permits them;
- sqlz named parameters of the form `:identifier`.

Tokens retain leading comments needed for directives and exact source spans.
The lexer does not decide whether a word is reserved in a particular syntactic
position; the dialect parser does.

### Parser

The parser uses a common AST with dialect extension nodes. It must recover at
commas, closing delimiters, clause boundaries, and statement terminators so one
malformed query can produce useful diagnostics without suppressing unrelated
queries.

The practical 0.1 query subset includes:

- `SELECT`, `INSERT`, `UPDATE`, and `DELETE`;
- `VALUES`, aliases, joins, subqueries, scalar subqueries, compound queries,
  grouping, aggregates, ordering, limits, and common table expressions;
- `CASE`, common unary/binary expressions, function calls, casts, `NULL`, and
  backend literals;
- `RETURNING`;
- SQLite and PostgreSQL conflict/upsert forms;
- PostgreSQL array and JSON operators when their types are otherwise supported;
- SQLite `PRAGMA` only through raw execution, not checked queries.

The migration DDL subset includes:

- create/drop/rename table;
- add, drop, and rename column where supported by the target dialect;
- primary, unique, foreign-key, check, and not-null constraints;
- create/drop index, including partial indexes;
- create/drop view;
- PostgreSQL schemas, enums, and domains at the level needed for registered
  codecs;
- SQLite `STRICT`, `WITHOUT ROWID`, generated columns, and common table options.

Triggers, stored procedures, arbitrary procedural blocks, extension-provided
grammar, virtual-table module internals, and full-text query languages are not
semantically checked in 0.1. A migration may carry explicitly opaque DDL only as
described below; a checked query that depends on an opaque object's inferred
shape requires catalog declarations or a codec override.

### Unsupported migration statements

Schema replay cannot silently skip a statement that may affect the catalog.
Each migration SQL file may use this directive immediately before an unsupported
statement:

```sql
-- sqlz.opaque: no-schema-change
CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

`no-schema-change` permits execution but asserts that the statement does not
change objects visible to checked queries. It is invalid on a recognized schema-
changing statement. There is no general “ignore this DDL” directive.

Objects created through unsupported syntax must be described in a checked
catalog supplement registered with the build helper. Catalog supplements use a
versioned sqlz JSON format, are backend-specific, and may add types, functions,
operators, tables, or views. They cannot redefine migration-owned objects.

## Migration replay

The checker loads the revision graph according to [migrations.md](migrations.md),
validates it, and selects the requested head. Without an explicit head, exactly
one graph head must exist. It topologically orders the ancestors with revision
ID as the deterministic tie breaker for independent nodes.

For each analyzed backend it applies the effective upgrade stream:

1. parse common upgrade SQL;
2. apply common catalog operations;
3. parse that backend's upgrade SQL;
4. apply backend catalog operations.

Each revision is atomic in the in-memory catalog. A semantic DDL error rolls
back that revision's catalog changes before checking continues for independent
diagnostics.

The catalog tracks schemas, tables, views, columns, type identities, nullability,
defaults, generated expressions, keys, foreign keys, indexes, enum values,
domains, and known function/operator signatures. Every fact records its source
span and revision ID.

Downgrade SQL is parsed and type checked but does not produce the query-checking
catalog. In tests, applying all upgrades and then all reversible downgrades must
return to an empty user catalog.

## Query discovery

### SQL files

Registered roots are traversed recursively in bytewise relative-path order.
Files ending in `.sql` are parsed according to [query-api.md](query-api.md).
Hidden directories and Zig cache/output directories are skipped. Symlinked files
are rejected when they escape the registered root.

### Zig declarations

Registered `.zig` files are parsed with Zig's AST implementation. The checker
looks for direct `sqlz.Query(.{ ... })` initializers assigned to constants. It
does not infer aliases for `sqlz`, follow arbitrary imports, execute comptime
code, or evaluate expressions.

The following fields must therefore be statically readable:

- `.sql`: one ordinary or multiline string literal;
- `.backends`: a literal backend set;
- `.cardinality`: an enum literal;
- `.params` and `.row`: struct type expressions;
- optional codec maps: struct literals whose values name registered codecs.

Type expressions are preserved for generated compile assertions. The checker
maps built-in spellings directly and maps non-built-in fields through explicit
codec entries. A custom type without a codec is an error with help showing the
required map entry.

Duplicate discovery through overlapping roots is deduplicated by canonical file
and declaration span. Two declarations with the same fully qualified container
path and name are an error.

## Semantic analysis

Queries are analyzed separately for each declared backend.

### Names and scopes

Resolution covers qualified and unqualified columns, aliases, CTEs, correlated
subqueries, schemas, and result aliases. Ambiguous, missing, or inaccessible
names are errors. `SELECT *` is accepted, expanded in catalog order, and written
as explicit generated fields; a warning recommends explicit columns for stable
public APIs.

Result columns must have unique names that are valid Zig identifiers. SQL aliases
are the preferred fix. sqlz does not silently suffix duplicates or rewrite
invalid names. Zig keywords may be represented with Zig escaped identifiers in
generated code.

### Parameters

Each use of a named parameter contributes database-type and nullability
constraints. All uses must unify. Parameters not constrained by SQL require a
codec override. Missing and extra fields in an embedded `.params` struct are
errors; field order is irrelevant because binding uses parameter names.

The emitted positional order is first lexical appearance. Each backend SQL
variant records a source map so a runtime prepare error can still identify the
original named query in debug context.

### Result types and nullability

The analyzer infers a database type and nullability for every result expression.
Nullability accounts for schema constraints, literals, operators, aggregate
rules, `CASE`, scalar subqueries, and the nullable side of outer joins.

Unknown database types, polymorphic functions without enough context, and
ambiguous SQLite expressions require an explicit column codec. An inferred
nullable column cannot map to non-optional Zig. A user may explicitly widen a
known non-null column to optional.

For an embedded query, result names must match `.row` fields exactly. For a SQL
file, the generator chooses built-in Zig types or registered codec types. A
portable query must produce the same public Zig parameter and result contract on
all target backends, even when its emitted backend SQL differs.

### Cardinality checks

The explicit cardinality determines the generated method. The analyzer enforces
only facts that are sound:

- `.exec` rejects a result-producing statement;
- row cardinalities reject statements without a result shape;
- visibly impossible `.one` queries are errors;
- queries whose uniqueness cannot be proven remain valid;
- an unconstrained `.one` may receive a warning, never an error.

Warnings do not fail `sqlz-check` by default. The build helper offers
`warnings_as_errors`, defaulting to `false`.

## Diagnostics

Diagnostics use this stable shape:

```text
queries/get_user.sql:6:8: error[Q021]: column `nickname` does not exist
  |
6 | SELECT nickname FROM users WHERE id = :id;
  |        ^^^^^^^^ unknown column
  |
migrations/a1b2c3d4e5f6_create_users/common.up.sql:4:3: note: `users` is declared here
  |
4 |   display_name TEXT NOT NULL
  |   ------------ available column
  = help: did you mean `display_name`?
```

Rules:

- Error codes are stable within the 0.x series and grouped by source (`S`),
  migration graph (`M`), catalog (`C`), query (`Q`), codec (`T`), and generator
  (`G`).
- Primary messages describe the failed contract, not parser internals.
- Secondary labels point to conflicting parameter uses, result declarations, or
  migration facts when relevant.
- Expected-token lists are capped and sorted by usefulness.
- Paths are workspace-relative when possible.
- Color is automatic on terminals and disabled by `NO_COLOR` or `--color=never`.
- `--format=json` emits one JSON object per diagnostic for editor and CI use.
- Independent errors are accumulated; the default cap is 100 and is configurable.

The checker exits `0` on success, `1` for checked-source errors, and `2` for
invalid invocation, I/O failure, or an internal failure. Internal failures must
identify themselves as bugs and must not masquerade as user SQL diagnostics.

## Binding generation

Generated declarations contain:

- an argument struct in first-use parameter order;
- `Row` and `OwnedRow` types for row-returning queries;
- exactly one cardinality-appropriate public execution method;
- backend-specific static SQL and parameter mapping hidden from the caller;
- compile assertions for codec contracts and embedded Zig metadata;
- query IDs stable for identical logical inputs, used by statement caches and
  debug context.

The generator never copies SQL comments into executable string data unless the
driver requires them. It preserves statement semantics while replacing named
parameters with backend positions. It does not reformat expressions, reorder
clauses, inject `LIMIT`, or otherwise optimize user SQL.

Generated declarations are sorted by public query name. Generated code contains
the format version and a content hash, not a wall-clock timestamp.

## Incremental behavior

The checker computes per-revision catalog snapshots and per-query analysis keys.
A change invalidates:

- the changed migration and every descendant catalog snapshot;
- queries referencing a changed object, plus queries with wildcard expansion;
- all queries for a backend when a catalog supplement or dialect version changes;
- queries using a changed codec.

Correctness does not depend on fine-grained invalidation. The implementation may
initially rerun all analysis under one deterministic cache key, then add granular
caching without changing public behavior.

## Test strategy

- Lexer tests cover every quoting/comment form and `:name` versus `::cast`.
- Parser snapshots cover common AST and dialect extensions, malformed input, and
  recovery after errors.
- Catalog tests replay real migration sequences and verify object-origin spans.
- Semantic fixtures include success and failure pairs for names, scopes, joins,
  CTEs, parameters, operators, result names, types, and nullability.
- Portable fixtures run against both catalogs and compare public contracts.
- Golden diagnostic tests assert messages, labels, paths, and source excerpts.
- Generator tests compare bytes across repeated runs and compile the output.
- Fuzz tests feed arbitrary bytes to lexers, parsers, directive readers, and
  graph manifests; no input may cause undefined behavior or an uncontrolled
  panic.
