# ADR 0004: Dual query authoring model

- Status: Accepted
- Date: 2026-09-03

## Context

Large SQL benefits from dedicated files while nearby domain code benefits from
embedded declarations.

## Decision

Support named `.sql` files and statically discoverable `sqlz.Query` declarations.

## Alternatives considered

Only external files, only Zig strings, and runtime-only query construction were
rejected.

## Consequences

The checker needs SQL file conventions and limited Zig source discovery.

## Normative references

- [Query API](../query-api.md)
