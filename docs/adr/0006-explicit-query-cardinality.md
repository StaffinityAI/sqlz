# ADR 0006: Explicit query cardinality

- Status: Accepted
- Date: 2026-09-03

## Context

SQL syntax rarely proves whether callers expect zero, one, or many rows.

## Decision

Expose explicit `exec`, `one`, `optional`, and `many` operations with cardinality
errors where actual results violate the contract.

## Alternatives considered

Inferring cardinality universally and returning one universal cursor were rejected.

## Consequences

Intent is visible and checked, with small deliberate API duplication.

## Normative references

- [Query API](../query-api.md)
