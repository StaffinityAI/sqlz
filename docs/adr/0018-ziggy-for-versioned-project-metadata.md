# ADR 0018: Ziggy for versioned project metadata

- Status: Accepted
- Date: 2026-09-03

## Context

Configuration, migration manifests, and catalog supplements need readable,
schema-validated versioned metadata.

## Decision

Use Ziggy for `sqlz.ziggy`, `revision.ziggy`, and catalog supplements. Pin commit
`0b61581980d6905dd4108a618d602f5778593122` for Zig 0.16.0 compatibility.

## Alternatives considered

JSON, ad hoc Zig syntax, and an unpinned Ziggy dependency were rejected.

## Consequences

All formats carry versions and the pin needs compatibility fixtures.

## Normative references

- [Configuration](../configuration.md)
- [Catalogs](../catalogs.md)
- [Migrations](../migrations.md)
