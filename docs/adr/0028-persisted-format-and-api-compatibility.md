# ADR 0028: Persisted format and API compatibility

- Status: Accepted
- Date: 2026-09-03

## Context

Source APIs and durable database/config formats have different upgrade risks.

## Decision

Version public APIs with SemVer and every persisted protocol independently.
Later 0.x releases remain backward-readable for earlier 0.x persisted formats via
explicit upgrades.

## Alternatives considered

Treating 0.x persistence as disposable and one shared version number were rejected.

## Consequences

Format fixtures and upgrade paths are mandatory before releases.

## Normative references

- [Compatibility](../compatibility.md)
