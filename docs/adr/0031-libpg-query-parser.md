# ADR 0031: libpg_query parser boundary

- Status: Accepted
- Date: 2026-09-12
- Supersedes: [ADR 0017](0017-handwritten-parser-scope-and-resource-limits.md)

## Context

Maintaining a handwritten grammar for the complete shared SQL surface duplicates
PostgreSQL parser work and makes real-world query coverage the project's largest
early risk. sqlz still needs portable named parameters, source-oriented
diagnostics, SQLite extensions, catalog resolution, and type/nullability analysis.

## Decision

Use pganalyze's `libpg_query`, pinned to release 18.0.0 (PostgreSQL 18.4), as the
syntax parser for common DML and PostgreSQL grammar. Rewrite portable `:name`
parameters to first-use `$N` ordinals before parsing and retain the name mapping.

Build the pinned C source with Zig for the selected target. Do not use a
platform-specific prebuilt archive. The checker consumes the resulting parse tree;
it does not run SQL parsing at Zig comptime.

`libpg_query` is not an SQLite parser. SQLite-only syntax is recognized and
validated by a narrow SQLite layer, while the shared subset is parsed through
`libpg_query`. Engine conformance tests remain required for both dialects.

## Alternatives considered

A handwritten recursive-descent/Pratt parser was rejected for the initial
version because its maintenance cost delays useful query coverage. A vendored
prebuilt Zig binding was rejected because its archive was platform-specific.
Using SQLite itself as the only parser was rejected because it does not produce
the shared PostgreSQL-oriented syntax tree required by the checker.

## Consequences

The parser dependency adds native C compilation and PostgreSQL/BSD-3-Clause
license obligations. PostgreSQL grammar tracks the pinned parser release.
Diagnostics and SQLite extensions require sqlz-owned adaptation around the parser,
but sqlz no longer owns a full common SQL grammar.

## Normative references

- [SQL parser](../parser.md)
- [Architecture](../architecture.md)
