# SQL parser

The checker contains a handwritten, error-recovering SQL parser. It performs no
SQL parsing in Zig comptime. Statements use recursive descent and expressions use
a Pratt parser with dialect- and profile-specific parselets.

## Pipeline

Bytes are retained by a source manager, decoded as UTF-8, tokenized with exact
byte spans, parsed into an arena-owned AST, and analyzed only if a usable statement
was recovered. Tokens and AST nodes refer to immutable source slices; callers must
keep the source manager alive for the complete checking invocation.

The lexer handles quoted identifiers, escaped strings, dollar-quoted PostgreSQL
strings, comments, numeric forms, named `:parameters`, and dialect operators. A
colon inside a string, comment, cast, or operator is never a parameter.

## Grammar and versions

The common grammar covers schema statements needed for replay and SELECT, INSERT,
UPDATE, DELETE, and WITH queries. Dialect modules add SQLite and PostgreSQL forms.
Every non-common production has a minimum/maximum profile gate and capability
requirements. Unsupported syntax receives a targeted diagnostic; it is never
silently accepted as opaque SQL when schema or result inference depends on it.

Operator binding powers are tables reviewed against the supported engines. The
AST preserves qualification, aliases, joins, conflict clauses, returning clauses,
casts, null tests, ordering, and source spans. Identifier comparison follows the
backend: unquoted PostgreSQL names fold to lowercase, quoted names are exact, and
SQLite lookup follows SQLite semantics.

## Recovery

Recovery synchronizes at statement terminators, clause starters, comma-delimited
lists, and balanced closing delimiters. Diagnostics contain a primary span,
labels, notes, stable code, backend/profile, and actionable fix when known. Later
analysis does not cascade from explicitly poisoned nodes.

## Limits and conformance

The parser enforces the limits in [configuration.md](configuration.md). Tests use
golden ASTs and diagnostics, property tests, mutation tests, and fuzzing. Differential
CI sends accepted syntax to every supported PostgreSQL major and SQLite capability
profile. Engine acceptance does not replace semantic checking, but disagreement is
a release-blocking parser issue unless documented as an intentional subset.
