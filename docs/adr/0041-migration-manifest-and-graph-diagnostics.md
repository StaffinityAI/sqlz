# ADR 0041: Migration manifest and graph diagnostics

- Status: Accepted
- Date: 2026-09-18

## Context

Migration validation currently returns plain Zig errors. A project with several
independent invalid revision directories reports only the first failure, and graph
errors do not identify the manifest fields or other revisions involved. The shared
diagnostic transport and project accumulator now provide the necessary boundary.

## Decision

Add a diagnostic discovery API alongside the existing error-returning API. It reads
revision directories in deterministic bytewise order, continues after independent
manifest/file failures, and records stable `Mxxx` diagnostics. Existing callers may
keep fail-fast behavior through `discover`; code generation uses the diagnostic API.

Ziggy deserialization failures use Ziggy's native token location. Semantic manifest
validation uses a narrow field locator for top-level format-1 fields. Graph
diagnostics label every relevant revision manifest: duplicate IDs label both
definitions, missing parents label the child parent list, cycles label participating
revisions, and multiple heads label all heads. Invalid migration diagnostics prevent
catalog replay and query checking.

## Alternatives considered

Replacing Ziggy with a custom manifest parser was rejected. Reporting only directory
paths was rejected because the manifest is the actionable source. Converting the
existing fail-fast API in place was rejected because bootstrap and lower-level users
still rely on ordinary error unions.

## Consequences

Code generation reports independent migration failures up to the project diagnostic
limit before stopping. Field location for semantic errors is intentionally limited
to the supported manifest grammar and must remain covered by golden tests. Rich SQL
file statement spans and catalog-divergence object summaries remain later work.

## Normative references

- [Migrations](../migrations.md)
- [SQL checker](../sql-checker.md)
- [ADR 0020](0020-source-oriented-diagnostics-and-machine-output.md)
- [ADR 0039](0039-diagnostic-transport-and-codegen-boundary.md)
