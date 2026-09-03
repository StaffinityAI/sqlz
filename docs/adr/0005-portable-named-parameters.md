# ADR 0005: Portable named parameters

- Status: Accepted
- Date: 2026-09-03

## Context

SQLite and PostgreSQL use different native placeholder syntax.

## Decision

Author checked queries with repeated, ordered-by-first-use `:name` parameters and
lower them to backend placeholders.

## Alternatives considered

Native placeholders and positional-only portable placeholders were rejected.

## Consequences

Lexing must distinguish parameters from casts, strings, comments, and operators.

## Normative references

- [Query API](../query-api.md)
