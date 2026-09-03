# Design completeness audit

This audit is the exhaustive 0.1 design-document gap register as of 2026-09-03.
“Resolved” means a normative design document and an Accepted ADR exist; it does
not imply an implementation exists. No known architectural decision remains open.

| Area | Required decision/detail | Resolution | Normative document | Milestone |
| --- | --- | --- | --- | --- |
| Scope | supported backends and non-goals | Resolved | [architecture.md](architecture.md) | M1 |
| Builds | lazy backend dependencies and combinations | Resolved | [build-integration.md](build-integration.md) | M5 |
| Checking | offline, host-time, migration-derived schema | Resolved | [sql-checker.md](sql-checker.md) | M1–M4 |
| Parser | architecture, recovery, versions, limits | Resolved | [parser.md](parser.md) | M1–M2 |
| Types | coercion, nullability, overloads, arrays | Resolved | [type-system.md](type-system.md) | M2–M4 |
| Catalogs | builtins, Ziggy supplements, precedence | Resolved | [catalogs.md](catalogs.md) | M2–M4 |
| Queries | authoring, parameters, cardinality, namespace | Resolved | [query-api.md](query-api.md) | M3–M4 |
| Generation | cache-only output and ownership APIs | Resolved | [sql-checker.md](sql-checker.md) | M3 |
| Runtime | wrappers, executors, pools, transactions | Resolved | [runtime.md](runtime.md) | M3–M4 |
| Errors | payload ownership, privacy, telemetry | Resolved | [errors-and-observability.md](errors-and-observability.md) | M3–M5 |
| Config | schema, roots, profiles, codecs, projects | Resolved | [configuration.md](configuration.md) | M1 |
| Migrations | DAG, files, convergence, transactions | Resolved | [migrations.md](migrations.md) | M1–M5 |
| State | identity, checksums, journal, upgrades | Resolved | [migration-state.md](migration-state.md) | M5 |
| CLI | unified commands, JSON, confirmations | Resolved | [cli.md](cli.md) | M5 |
| Compatibility | SemVer, formats, Zig/DB/platform matrix | Resolved | [compatibility.md](compatibility.md) | M6 |
| Testing | component, engine, build, and platform suites | Resolved | [testing.md](testing.md) | M1–M6 |
| Performance | benchmark method and gate timing | Resolved | [performance.md](performance.md) | M6 |
| Security | trust, paths, injection, secrets, privileges | Resolved | [security.md](security.md) | M1–M6 |
| Governance | normative docs versus ADR history | Resolved | [adr/README.md](adr/README.md) | Continuous |

## Explicitly deferred beyond 0.1

- additional drivers, dynamic backend loading, attached SQLite databases, and full
  PostgreSQL polymorphism or multidimensional arrays;
- live-database query introspection and SQL parsing during Zig comptime;
- checking queries against several rolling-deploy migration revisions;
- portable cancellation, timeouts, fetch sizing, and generic query options;
- a sqlz-owned pool or statement cache;
- automatic proof of DML convergence at merge revisions;
- direct generated mapping of named `.sql` rows into arbitrary domain structs;
- Windows runtime support guarantees.

## Implementation-time details still to specify

These do not alter architecture and should be settled in implementation notes or
small follow-up ADRs when evidence exists: exact public identifier spelling,
physical internal-table names and DDL, the complete diagnostic-code registry,
every catalog entry and dialect grammar production, concrete benchmark thresholds,
release/CI provider configuration, and driver-version pins. A material change to a
decision above requires a superseding ADR.
