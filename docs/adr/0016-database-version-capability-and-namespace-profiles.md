# ADR 0016: Database version, capability, and namespace profiles

- Status: Accepted
- Date: 2026-09-03

## Context

Syntax/catalog behavior varies by version, SQLite build, and PostgreSQL namespace.

## Decision

Support SQLite 3.45–3.53 and PostgreSQL 15–18, defaulting to SQLite 3.53 and PG15
compatibility. Configure SQLite capabilities, PostgreSQL search path, and SQLite
`main` only. Reject engines outside tested bounds unless newer versions are
explicitly allowed.

## Alternatives considered

One timeless dialect and accepting any runtime version were rejected.

## Consequences

Catalogs and conformance tests are profile-indexed.

## Normative references

- [Compatibility](../compatibility.md)
- [Configuration](../configuration.md)
