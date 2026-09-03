# ADR 0017: Handwritten parser scope and resource limits

- Status: Accepted
- Date: 2026-09-03

## Context

sqlz needs precise spans, recovery, dialect gates, and bounded behavior.

## Decision

Implement recursive-descent statements and Pratt expressions with source-owned
spans, recovery, configurable safe limits, fuzzing, and engine differential tests.

## Alternatives considered

Parser generators, driver parsers, and unbounded best-effort parsing were rejected.

## Consequences

Grammar maintenance is a core project responsibility.

## Normative references

- [Parser](../parser.md)
