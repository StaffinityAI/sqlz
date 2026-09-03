# ADR 0030: Documentation authority, ADR governance, and performance gates

- Status: Accepted
- Date: 2026-09-03

## Context

Design evolution needs a clear source of current truth and measurable performance
claims without inventing targets before implementation data exists.

## Decision

Reference design documents are normative; Nygard-style ADRs record history and are
superseded rather than rewritten. Establish the benchmark suite first, collect
baselines, then adopt numeric release gates before 0.1 stabilization.

## Alternatives considered

Treating ADRs as the live specification and choosing unsupported numeric targets
were rejected.

## Consequences

Cross-links must stay current and performance gates remain an explicit pre-release
deliverable.

## Normative references

- [Design index](../README.md)
- [Performance](../performance.md)
