# SQL parser

The checker uses pganalyze's `libpg_query` as its common SQL and PostgreSQL parser.
The dependency is pinned to release 18.0.0, which embeds the PostgreSQL 18.4
parser, and is compiled from source for the selected Zig target. SQL parsing is a
host-tool operation and never runs at Zig comptime.

## Pipeline

Bytes are retained by a source manager and decoded as UTF-8. Portable named
parameters are lexically rewritten to PostgreSQL `$N` parameters in first-use
order, preserving a mapping back to their names and original source. The rewritten
statement is parsed by `libpg_query`; its protobuf/JSON tree is adapted into the
checker IR and analyzed only after a usable statement was returned.

The parameter lexer handles quoted identifiers, escaped strings, comments, and
named `:parameters`. A colon inside a string, quoted identifier, comment, cast, or
operator is never a parameter. The PostgreSQL scanner and grammar remain owned by
`libpg_query`.

## Grammar and versions

The common query grammar covers SELECT, INSERT, UPDATE, DELETE, WITH, conflict
clauses, and RETURNING through `libpg_query`. Dialect policies add capability
checks. A narrow SQLite syntax layer handles SQLite-only forms such as pragmas,
`INSERT OR IGNORE`, and table options; those forms are not presented unchanged to
the PostgreSQL parser.

The adapted AST preserves qualification, aliases, joins, conflict clauses,
returning clauses, casts, null tests, ordering, and source locations. Identifier
comparison follows the backend: unquoted PostgreSQL names fold to lowercase,
quoted names are exact, and SQLite lookup follows SQLite semantics.

## Recovery

The checker converts parser errors and cursor positions back through the parameter
rewrite map. Diagnostics contain a primary span, labels, notes, stable code,
backend/profile, and actionable fix when known. Independent query files continue
after a failed statement; semantic analysis does not run for that statement.

## Limits and conformance

The parser wrapper enforces the limits in [configuration.md](configuration.md).
Tests use real-world acceptance queries, golden adapted ASTs and diagnostics,
property tests, and fuzzing of the parameter rewrite boundary. Differential CI
sends accepted syntax to every supported PostgreSQL major and SQLite capability
profile. Engine acceptance does not replace semantic checking, but disagreement is
a release-blocking issue unless documented as an intentional subset.
