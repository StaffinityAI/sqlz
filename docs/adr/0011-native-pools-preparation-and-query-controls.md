# ADR 0011: Native pools, preparation, and query controls

- Status: Accepted
- Date: 2026-09-03

## Context

Drivers already implement backend-specific pooling and preparation semantics.

## Decision

Wrap native pools and leave preparation/statement caching to drivers. Offer no
portable timeout, cancellation, fetch-size, or generic options API in 0.1.

## Alternatives considered

A sqlz pool/cache and a lowest-common-denominator controls API were rejected.

## Consequences

Advanced controls require explicit backend escape hatches.

## Normative references

- [Runtime](../runtime.md)
