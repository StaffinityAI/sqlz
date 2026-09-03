# ADR 0025: Migration locking, transactions, and timeouts

- Status: Accepted
- Date: 2026-09-03

## Context

Concurrent migrators and SQL-controlled transactions can corrupt state.

## Decision

The runner acquires a backend-specific project lock, defaults to a configurable
30-second timeout, owns transaction boundaries, and never runs unlocked. Manifests
declare `always` or `never` per targeted backend; SQLite supports only `always` in
0.1. Migration SQL may interleave DDL and DML but not control transactions.

## Alternatives considered

Infinite waits, best-effort unlocked execution, and author-managed transactions
were rejected.

## Consequences

Atomicity differences are explicit and journaled.

## Normative references

- [Migrations](../migrations.md)
- [CLI](../cli.md)
