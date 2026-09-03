# ADR 0022: Merge convergence and head-only query checking

- Status: Accepted
- Date: 2026-09-03

## Context

A revision DAG can reach a merge through several schemas, while rolling-deploy
compatibility multiplies checking states.

## Decision

Validate schema convergence from every merge-parent path. Authors remain
responsible for DML convergence. Check queries against the sole configured head in
0.1; defer multi-revision checking.

## Alternatives considered

Checking one arbitrary path and mandatory rolling-window checking were rejected.

## Consequences

Merges are deterministic for schema shape but cannot prove equivalent data.

## Normative references

- [Migrations](../migrations.md)
- [SQL checker](../sql-checker.md)
