# ADR 0019: Builtin catalogs, supplements, and polymorphism

- Status: Accepted
- Date: 2026-09-03

## Context

Offline checking needs reproducible builtins plus extension metadata.

## Decision

Commit reviewed Ziggy catalogs per profile; accept project supplements. Model
simple type variables/equality/nullability/array relations and implement complex
builtins as checker intrinsics.

## Alternatives considered

Live catalog queries and reproducing PostgreSQL's entire polymorphic resolver were
rejected.

## Consequences

Catalog provenance and conflict rules are part of review.

## Normative references

- [Catalogs](../catalogs.md)
