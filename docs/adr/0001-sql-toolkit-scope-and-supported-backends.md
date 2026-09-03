# ADR 0001: SQL toolkit scope and supported backends

- Status: Accepted
- Date: 2026-09-03

## Context

sqlz needs a useful initial scope without hiding driver differences.

## Decision

Build a SQLx-like Zig toolkit supporting only zqlite and pg.zig in 0.1, with
checked queries, runtime wrappers, and migrations.

## Alternatives considered

A driver-neutral framework with many initial backends and a checker-only library
were rejected as too broad or incomplete.

## Consequences

The two backends define the initial portability surface; additions require an ADR.

## Normative references

- [Architecture](../architecture.md)
