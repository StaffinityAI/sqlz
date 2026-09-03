# ADR 0009: Borrowed row views and owned conversion

- Status: Accepted
- Date: 2026-09-03

## Context

Always allocating row data is expensive, but driver buffers have short lifetimes.

## Decision

Return borrowed row views by default and provide explicit allocator-backed
`OwnedRow` conversion with `deinit`.

## Alternatives considered

Always-owned rows and undocumented borrowed slices were rejected.

## Consequences

Lifetimes and invalidation points are part of the public contract.

## Normative references

- [Runtime](../runtime.md)
