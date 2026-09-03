# ADR 0026: Unified build-integrated CLI and runtime migrator

- Status: Accepted
- Date: 2026-09-03

## Context

Separate build steps fragment configuration and command discovery, while deployed
applications may need programmatic migration.

## Decision

Expose `zig build sqlz -- ...` for init, check, revision, status, migration, state,
and journal commands. Also expose a runtime migrator using the same planner/state
logic.

## Alternatives considered

Separate `sqlz-check`/`sqlz-migrate` steps and CLI-only migrations were rejected.

## Consequences

One host command needs stable subcommand and JSON contracts.

## Normative references

- [CLI](../cli.md)
- [Build integration](../build-integration.md)
