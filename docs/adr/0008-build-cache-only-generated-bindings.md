# ADR 0008: Build-cache-only generated bindings

- Status: Accepted
- Date: 2026-09-03

## Context

Committed generated Zig causes drift and merge noise.

## Decision

Generate deterministic modules in the Zig build cache and wire their paths through
build dependencies and directory watch inputs.

## Alternatives considered

Writing into `src` and runtime reflection were rejected.

## Consequences

The build graph must make generation precede compilation and expose diagnostics.

## Normative references

- [Build integration](../build-integration.md)
