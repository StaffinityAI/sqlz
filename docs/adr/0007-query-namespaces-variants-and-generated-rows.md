# ADR 0007: Query namespaces, variants, and generated rows

- Status: Accepted
- Date: 2026-09-03

## Context

Multiple SQL roots and backend variants need deterministic names and result types.

## Decision

Require root aliases, derive nested namespaces from paths, support explicit backend
variants, and generate `Row`/`OwnedRow` for named SQL. Domain structs use embedded
queries or manual mapping.

## Alternatives considered

A flat namespace and automatic arbitrary struct mapping were rejected as ambiguous.

## Consequences

Moving a query changes its generated namespace.

## Normative references

- [Configuration](../configuration.md)
- [Query API](../query-api.md)
