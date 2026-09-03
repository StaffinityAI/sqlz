# ADR 0003: Offline migration-derived SQL checking

- Status: Accepted
- Date: 2026-09-03

## Context

Comptime parsing gives poor multi-error diagnostics, while live database checking
is nondeterministic and awkward in builds.

## Decision

A host tool parses migrations, reconstructs schemas, and checks queries offline.
No SQL parsing or semantic analysis occurs in Zig comptime.

## Alternatives considered

Comptime evaluation and mandatory live database introspection were rejected.

## Consequences

The custom parser and catalogs are substantial maintained components.

## Normative references

- [SQL checker](../sql-checker.md)
