# ADR 0040: PostgreSQL runtime version policy

- Status: Accepted
- Date: 2026-09-18

## Context

Project configuration selects a PostgreSQL compatibility profile from 15 through
18, but the runtime adapter currently authenticates without checking the connected
server. A connection to an older server can violate checked syntax/catalog
assumptions, while a newer untested server should not silently expand the support
claim. Pools and direct connections must apply the same rule.

## Decision

Treat the selected PostgreSQL profile as the minimum server major whose semantics
the project may require. After authentication and before returning a usable handle,
the adapter reads `server_version_num`, parses its numeric form, and applies:

- reject a server major lower than the selected profile;
- accept server majors from the selected profile through the highest tested major,
  currently 18;
- reject a server major above 18 unless `allow_untested_version` is true;
- never allow the override to accept a server older than the selected profile.

Direct connection and pool options carry the profile and override. Connections and
pools expose the detected version. Pool initialization validates its endpoint before
returning, and explicit pool acquisitions revalidate checkouts so replacement
connections cannot bypass policy.

Malformed or unsupported versions fail connection initialization with stable Zig
errors. Version override use is observable and will emit a telemetry event once the
telemetry interface is implemented.

## Alternatives considered

Exact-major matching was rejected because a profile is a compatibility floor, not
a deployment pin. Accepting every newer version was rejected because it would make
untested behavior an implicit support promise. Checking only in migration commands
was rejected because ordinary checked queries rely on the same profile assumptions.
Validating only the first pooled connection was rejected because replacement
connections could target a changed endpoint.

## Consequences

Opening a PostgreSQL connection performs one small version query. Pool checkout has
the same policy guarantee and may perform the query again. Applications can inspect
the detected version and explicitly opt into newer untested servers, but cannot
override an older-server mismatch.

## Normative references

- [Compatibility](../compatibility.md)
- [Configuration](../configuration.md)
- [Runtime](../runtime.md)
- [ADR 0016](0016-database-version-capability-and-namespace-profiles.md)
- [ADR 0038](0038-postgresql-live-engine-conformance.md)
