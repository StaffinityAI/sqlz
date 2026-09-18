# ADR 0037: Offline hooks and Compose-backed CI

- Status: Accepted
- Date: 2026-09-18

## Context

The existing hk pre-commit hook ran `zig build test`, which mixed deterministic
host checks with SQLite runtime coverage and PostgreSQL adapter compile checks.
It provided no live PostgreSQL evidence, while making every commit pay for the
largest available suite. Database-backed end-to-end tests also need a
reproducible service lifecycle rather than an undocumented developer database.

## Decision

Separate validation into two named gates managed by mise.

`mise run check` delegates to hk and contains only formatting and
`zig build test-offline`. The offline build step must not use Docker, connect to
a database, or require network access. hk pre-commit hooks run this gate's
steps, never the integration gate.

`mise run ci` is the complete local and hosted CI entry point. It runs the
offline gate, starts the pinned PostgreSQL major from `compose.yaml`, runs the
full Zig suite, and runs `zig build test-integration`. Integration coverage must
exercise the actual SQLite runtime and an actual PostgreSQL server. The command
owns service teardown and removes its disposable volume even after failure or
interruption.

Hosted CI may add service-container matrices beyond the single local Compose
service. ADR 0038 defines the PostgreSQL 15–18 matrix and keeps it on the complete
gate rather than pre-commit.

Narrow Zig build steps remain available for adapter-focused development, but
support claims and merge gates use `mise run ci` rather than assembling an
ad-hoc subset.

## Alternatives considered

Running Docker-backed tests in pre-commit was rejected because hook latency and
service availability would make commits unreliable. Using a developer-managed
PostgreSQL instance was rejected because versions, credentials, state, and
cleanup would vary. Mocking PostgreSQL or retaining compile-only coverage was
rejected because it cannot validate protocol, authentication, execution,
decoding, streaming, or transaction behavior.

## Consequences

Local hooks remain fast and deterministic, while CI gains real coverage for
both supported engines. Contributors need Docker only for the complete gate,
not for ordinary commits. CI time includes image startup and live integration
tests, and changes to the supported PostgreSQL major must update Compose and the
documented compatibility matrix together.

## Normative references

- [Testing](../testing.md)
- [Compatibility](../compatibility.md)
- [ADR 0038](0038-postgresql-live-engine-conformance.md)
