# ADR 0013: Transaction cleanup and rollback

- Status: Accepted
- Date: 2026-09-03

## Context

Dropping an active transaction must not leak it back into a pool.

## Decision

Explicit commit/rollback return detailed Results. Transaction `deinit` attempts
rollback; rollback failure poisons and discards the connection.

## Alternatives considered

Implicit commit and silently returning a failed connection were rejected.

## Consequences

Pool adapters need a discard path and cleanup telemetry.

## Normative references

- [Runtime](../runtime.md)
