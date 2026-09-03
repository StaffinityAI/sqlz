# ADR 0014: Custom codecs and split registration

- Status: Accepted
- Date: 2026-09-03

## Context

Database type patterns are portable metadata; Zig types and modules are build
objects.

## Decision

Put stable codec IDs and database patterns in `sqlz.ziggy`; bind each ID exactly
once to `{module, declaration}` in `build.zig`.

## Alternatives considered

Encoding Zig build objects in config and discovering codecs by convention were
rejected.

## Consequences

Configuration and build registration are validated together.

## Normative references

- [Configuration](../configuration.md)
- [Type system](../type-system.md)
