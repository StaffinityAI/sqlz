# ADR 0021: Manual revision DAG and migration file layout

- Status: Accepted
- Date: 2026-09-03

## Context

Teams need reviewable branches, merges, and backend-specific SQL.

## Decision

Use manually authored immutable revision directories with `revision.ziggy` and
per-backend up/down SQL. Allow interleaved DDL/DML; the runner owns transaction
control.

## Alternatives considered

Timestamp-only chains, generated schema diffs, JSON manifests, and transaction
statements inside migration SQL were rejected.

## Consequences

Authors own revision intent and downgrade content.

## Normative references

- [Migrations](../migrations.md)
