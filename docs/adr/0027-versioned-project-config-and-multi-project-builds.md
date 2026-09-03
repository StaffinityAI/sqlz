# ADR 0027: Versioned project config and multi-project builds

- Status: Accepted
- Date: 2026-09-03

## Context

Checker and migrator inputs need one portable definition, and monorepos may contain
several independent databases.

## Decision

Use checked-in versioned `sqlz.ziggy`. Build code registers one or more uniquely
named projects; `--project` is required only when ambiguous.

## Alternatives considered

Build-Zig-only configuration and one global project were rejected.

## Consequences

Config validation and command routing are first-class behavior.

## Normative references

- [Configuration](../configuration.md)
- [Build integration](../build-integration.md)
