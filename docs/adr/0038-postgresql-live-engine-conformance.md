# ADR 0038: PostgreSQL live-engine conformance

- Status: Accepted
- Date: 2026-09-18

## Context

Compile-only adapter tests cannot validate PostgreSQL authentication, protocol
state, server OIDs, SQLSTATE payloads, result draining, pooled checkout release,
transactions, arrays, enums/domains, or version-specific behavior. The supported
profile claim covers PostgreSQL 15 through 18, while ordinary developer hooks must
remain deterministic and database-free.

## Decision

Keep PostgreSQL compile/API tests in the offline/full Zig suite and maintain a
separate live integration binary selected by explicit build options. The binary
accepts host, port, database, username, password, and expected server major through
generated test options; it never discovers credentials from repository files.

Hosted CI runs the live suite against PostgreSQL 15, 16, 17, and 18 using isolated
service containers. The ordinary Compose-backed local gate remains pinned to 18 for
speed and reproducibility. Each live run creates uniquely named disposable objects,
validates the server major before testing, and removes its objects on success or
failure where possible.

The required live suite covers:

- authentication and retained `std.Io` initialization;
- all four cardinalities and scalar nullability;
- integer- and text-backed enums plus PostgreSQL enum/domain values;
- one-dimensional arrays, null arrays, and nullable elements;
- owned conversion and streaming row lifetime;
- commit, explicit rollback, and rollback-on-deinit;
- native pool checkout/release and early-stop drain/reuse;
- constraint SQLSTATE classification and copied error ownership;
- selected-server-version verification.

TLS has two levels of evidence. Every change compile-checks the TLS-enabled driver
configuration. Live TLS conformance runs only in a dedicated job/environment that
provides certificates and a TLS-enabled PostgreSQL service; a plain service must
not be presented as evidence for TLS runtime support.

## Alternatives considered

Mock protocol tests and compile-only coverage were rejected because they miss
driver/server interactions. Running all four majors in pre-commit was rejected due
to latency and Docker requirements. Testing only the newest PostgreSQL was rejected
because it cannot support the documented 15–18 profile range. Reading a developer's
ambient `DATABASE_URL` by default was rejected because it makes tests
non-reproducible and risks destructive operations against the wrong database.

## Consequences

The complete hosted gate becomes a PostgreSQL-major matrix and costs additional CI
time. Local development keeps one pinned Compose service and narrow adapter commands.
TLS runtime support remains provisional until its dedicated live job exists; compile
coverage alone is reported as such. Failures can be attributed to a concrete server
major and test capability.

## Normative references

- [Testing](../testing.md)
- [Compatibility](../compatibility.md)
- [Runtime](../runtime.md)
- [ADR 0029](0029-supported-platform-and-conformance-matrix.md)
- [ADR 0037](0037-offline-hooks-and-compose-backed-ci.md)
