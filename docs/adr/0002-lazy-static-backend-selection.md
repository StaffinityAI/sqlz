# ADR 0002: Lazy static backend selection

- Status: Accepted
- Date: 2026-09-03

## Context

Consumers should not fetch, compile, or link unused drivers.

## Decision

All runtime backends are disabled by default and selected statically per project.
The host checker remains backend-neutral and loads only offline dialect/catalog data.

## Alternatives considered

Always including both drivers and runtime dynamic loading were rejected for build
cost and complexity.

## Consequences

Every backend combination needs build-matrix coverage.

## Normative references

- [Build integration](../build-integration.md)
