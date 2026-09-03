# ADR 0010: sqlz runtime wrappers and handle ownership

- Status: Accepted
- Date: 2026-09-03

## Context

Generated queries need a consistent API without pretending native handles have
identical ownership.

## Decision

Use thin sqlz wrappers with distinct owned and borrowed connection types and a
sealed executor interface. Keep explicit native-handle escape hatches.

## Alternatives considered

Accepting raw drivers directly and one wrapper with a runtime ownership flag were
rejected.

## Consequences

Adapters stay small but are required for each driver release line.

## Normative references

- [Runtime](../runtime.md)
