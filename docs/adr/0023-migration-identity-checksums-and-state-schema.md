# ADR 0023: Migration identity, checksums, and state schema

- Status: Accepted
- Date: 2026-09-03

## Context

The runner must reject the wrong project, rewritten history, and incompatible
internal state.

## Decision

Store a configured UUIDv4, semantic configuration fingerprint, revision checksums,
parents, and state format version. PostgreSQL uses a configurable `sqlz` schema;
SQLite uses reserved `main` tables. Upgrade state forward automatically under lock.

## Alternatives considered

Path-derived identity, checksums alone, and manual state upgrades were rejected.

## Consequences

Rebind is explicit and newer unknown state versions fail closed.

## Normative references

- [Migration state](../migration-state.md)
