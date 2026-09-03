# ADR 0012: Payload errors, privacy, and telemetry

- Status: Accepted
- Date: 2026-09-03

## Context

Zig error unions cannot retain structured native diagnostics, which may also be
sensitive.

## Decision

Return allocator-owned `sqlz.Result(T)` payload errors. Preserve full backend
detail for callers, but exclude SQL, parameters, and full messages from optional
structured telemetry and migration journals.

## Alternatives considered

Error unions alone and globally logging backend messages were rejected.

## Consequences

Errors require `deinit`; telemetry has a deliberately limited schema.

## Normative references

- [Errors and observability](../errors-and-observability.md)
