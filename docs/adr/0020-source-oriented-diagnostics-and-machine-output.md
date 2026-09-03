# ADR 0020: Source-oriented diagnostics and machine output

- Status: Accepted
- Date: 2026-09-03

## Context

Developers and CI need the same failures in different representations.

## Decision

Diagnostics have stable codes, spans, labels, notes, and fixes. Render human text
or versioned JSON; JSON alone uses stdout and progress/diagnostics use stderr.

## Alternatives considered

Free-form strings and JSON mixed with logs were rejected.

## Consequences

Diagnostic schemas and exit codes require golden compatibility tests.

## Normative references

- [CLI](../cli.md)
- [Errors and observability](../errors-and-observability.md)
