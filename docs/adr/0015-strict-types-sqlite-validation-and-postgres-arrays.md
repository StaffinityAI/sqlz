# ADR 0015: Strict types, SQLite validation, and PostgreSQL arrays

- Status: Accepted
- Date: 2026-09-03

## Context

Portable static safety must account for SQLite dynamic storage and PostgreSQL
arrays.

## Decision

Allow only lossless implicit coercions. Warn for non-STRICT SQLite schemas and
validate storage/range at decode time. Support typed one-dimensional PostgreSQL
arrays with borrowed iteration and owned collection; reject multidimensional arrays.

## Alternatives considered

Permissive coercion, rejecting all non-STRICT tables, and complete array support
were rejected.

## Consequences

Some valid engine SQL needs explicit casts; decoders can return validation errors.

## Normative references

- [Type system](../type-system.md)
