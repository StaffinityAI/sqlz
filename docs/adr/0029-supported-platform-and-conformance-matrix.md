# ADR 0029: Supported platform and conformance matrix

- Status: Accepted
- Date: 2026-09-03

## Context

Support claims require concrete toolchain, engine, and operating-system evidence.

## Decision

Guarantee Zig 0.16.0; run full tests on x86_64 Linux and arm64 macOS; compile-check
Windows. Differential-test every SQLite 3.45–3.53 profile and PostgreSQL 15–18.

## Alternatives considered

“Latest” versions and equal unsupported platform claims were rejected.

## Consequences

CI capacity scales with the declared database matrix.

## Normative references

- [Testing](../testing.md)
- [Compatibility](../compatibility.md)
