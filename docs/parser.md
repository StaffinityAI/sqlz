# SQL parser

The checker uses pganalyze's `libpg_query` as its common SQL and PostgreSQL parser.
The dependency is pinned to release 18.0.0, which embeds the PostgreSQL 18.4
parser, and is compiled from source for the selected Zig target. SQL parsing is a
host-tool operation and never runs at Zig comptime.

## Pipeline

Bytes are retained by a source manager and validated as UTF-8. A shared,
dialect-aware lexer bounds the source's tokens and nesting, then portable named
parameters are rewritten to PostgreSQL `$N` parameters in first-use order,
preserving a mapping from every rewritten byte back to its original offset. A
leading byte order mark is rewritten as spaces, so no offset moves. The rewritten
statement is parsed by `libpg_query`. The protobuf-C parse tree is unpacked into
the generated `PgQuery__*` structs and traversed directly by the catalog and
checker adapters. The parser pipeline does not produce, parse, or traverse JSON.
Semantic analysis starts only after a usable typed tree was returned.

The lexer handles quoted identifiers, standard and `E'...'` escape strings,
dollar-quoted strings, nested PostgreSQL block comments, line comments, casts,
operators, and named `:parameters`. A colon inside a string, quoted identifier,
comment, cast, or operator is never a parameter. Brackets quote identifiers in
SQLite and subscript arrays in PostgreSQL. Lexing never fails: an unterminated
form runs to the end of the source and the grammar reports it. The PostgreSQL
scanner and grammar remain owned by `libpg_query`.

## Grammar and versions

The common query grammar covers SELECT, INSERT, UPDATE, DELETE, WITH, conflict
clauses, and RETURNING through `libpg_query`. Dialect policies add capability
checks. A narrow SQLite syntax layer handles SQLite-only forms such as pragmas,
`INSERT OR IGNORE`, and table options; those forms are not presented unchanged to
the PostgreSQL parser.

The SQLite layer masks `AUTOINCREMENT`, trailing `STRICT`, and `WITHOUT ROWID`
for host-side structural analysis, and maps `INSERT OR IGNORE` to its plain
insert shape. It also normalizes numeric separators for profiles 3.46 and newer.
Forms both grammars accept but lex differently are rejected rather than guessed
at: dollar quotes and `$name` parameters, `E'...'` strings, and nested block
comments.
Masking and normalization preserve byte positions; generated/runtime SQL remains
the original SQLite text.

Validation rejects PostgreSQL-only forms before semantic checking, including
`SELECT INTO`, row-locking clauses, `DISTINCT ON`, `GROUP BY DISTINCT`, `::`
casts, `ILIKE`, `SIMILAR TO`, insert overriding clauses, `DELETE USING`, and CTE
search/cycle clauses. These gates inspect the unpacked protobuf-C AST wherever
the distinction is structural; no secondary serialized AST is produced.

The adapted AST preserves qualification, aliases, joins, conflict clauses,
returning clauses, casts, null tests, ordering, and source locations. Identifier
comparison follows the backend: unquoted PostgreSQL names fold to lowercase,
quoted names are exact, and SQLite lookup follows SQLite semantics.

## Recovery

The checker converts parser errors and cursor positions back through the parameter
rewrite map. `libpg_query` reports a character position, which is converted to a
byte offset before mapping. A NUL byte fails the parse, since `libpg_query`
would otherwise stop reading at it. Diagnostics contain a primary span, labels, notes, stable code,
backend/profile, and actionable fix when known. Independent query files continue
after a failed statement; semantic analysis does not run for that statement.

## Limits and conformance

The parser wrapper enforces the token and nesting limits in
[configuration.md](configuration.md) before `libpg_query` runs, checking SQLite
text as both lexers see it. Its grammar and
tree serializer recurse once per nesting level, so the library is always built
optimized: unoptimized frames overflow an 8 MiB stack within a few hundred
levels. Tests use real-world acceptance queries, golden adapted ASTs and
diagnostics, property tests over generated and arbitrary bytes, and fuzz targets
for SQL bytes, directives, Zig declarations, and revision manifests. Differential CI
sends accepted syntax to every supported PostgreSQL major and SQLite capability
profile. Engine acceptance does not replace semantic checking, but disagreement is
a release-blocking issue unless documented as an intentional subset.
