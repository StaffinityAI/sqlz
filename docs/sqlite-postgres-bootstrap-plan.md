# SQLite-to-PostgreSQL bootstrap implementation plan

Status: initial implementation available. Keep this document current as scope
changes, implementation slices land, or new constraints are discovered. The
general release checklist remains [implementation-plan.md](implementation-plan.md);
this document is the source of truth for the bootstrap feature.

The implemented slice provides the build-integrated command, project routing,
offline transfer planning, read-only SQLite validation, dedicated-schema reset,
transactional PostgreSQL migration replay, parameter-bound row transfer,
sequence restoration, and row-count validation. Migration state/checksums,
journaling, interactive confirmation, JSON output, and live PostgreSQL
integration coverage remain follow-up work.

## Goal

Add a build-integrated CLI command that initializes PostgreSQL from an existing
SQLite database belonging to a registered sqlz project:

```text
zig build sqlz -- bootstrap postgres \
    --project NAME \
    --from-sqlite PATH \
    [--wipe-postgres] \
    [--postgres-url URL]
```

The command creates the destination schema from the project's PostgreSQL
migration stream, then copies compatible data from SQLite. It is a one-time
bootstrap operation, not an incremental synchronization tool.

## Initial scope

- The source is an existing SQLite file structurally compatible with the
  registered project's SQLite migration catalog. A sqlz migration-state schema
  is not required when structural validation succeeds.
- The destination schema is created through the normal PostgreSQL migration
  planner and runner. SQLite DDL is never translated directly into PostgreSQL
  DDL.
- The default is fail-closed: without `--wipe-postgres`, any destination object
  or data outside an explicitly allowed empty baseline rejects the operation.
- `--wipe-postgres` is optional and defaults to false. It authorizes sqlz to
  remove the destination project's managed PostgreSQL schema and state before
  rebuilding it. The initial implementation requires `--yes`; interactive
  confirmation is not implemented yet.
- Wipe applies only to the configured project-managed PostgreSQL namespace and
  sqlz state schema. It must not drop the PostgreSQL database, roles,
  extensions, or unrelated schemas.
- The source is read from one stable SQLite snapshot. Destination migration and
  import use the strongest atomic boundary allowed by the migration transaction
  policies.
- Initial value support is NULL, checked integer conversions, floating-point
  values, text-like values, `bytea`, and an explicitly defined boolean
  conversion.
- Views, SQLite internal objects, sqlz internal state, and generated destination
  columns are not copied as table data.
- Backend schema differences without a proven direct mapping are rejected.
- Identifiers come only from validated catalogs and use dialect-aware quoting.
  Row values are always bound parameters.

## Wipe semantics and safety

The wipe option is intentionally narrower than "make this database empty."

1. Complete all source loading, migration graph validation, catalog comparison,
   live SQLite schema validation, destination capability checks, and transfer
   planning before destructive mutation.
2. Resolve the exact PostgreSQL schemas and objects owned by the registered
   project. Reject ambiguous ownership, shared managed schemas, unexpected
   objects, or insufficient privileges before dropping anything.
3. Acquire the same project-scoped PostgreSQL advisory lock used by migration
   commands before the final destination check and retain it through bootstrap.
4. Without `--wipe-postgres`, reject a destination containing managed schema
   objects, sqlz state, or application data. Connecting to a database that has
   unrelated schemas is allowed only when ownership boundaries are unambiguous.
5. With `--wipe-postgres`, print the destination identity and exact schemas that
   will be removed, then require confirmation according to the CLI safety
   contract. `--yes` confirms the operation but does not weaken preflight.
6. Drop and recreate only the project-managed namespace and sqlz state. Never
   issue `DROP DATABASE`, alter roles, or remove unrelated schemas/extensions.
7. When every PostgreSQL migration is transactional, include wipe, schema
   recreation, data import, validation, and state recording in one destination
   transaction. If any required migration is `transaction = never`, preflight
   must expose the reduced atomicity before confirmation and journal every
   committed boundary. Recovery behavior must be implemented and tested before
   such graphs are supported; until then, bootstrap rejects them.
8. A failure after a nontransactional destructive boundary must leave an
   explicit failed journal record and actionable recovery instructions. It must
   never be reported as a clean empty destination.

The initial implementation should prefer PostgreSQL schema isolation. Projects
that place managed objects in a shared schema such as `public` are not safely
wipable by dropping the schema. Support for enumerating and dropping only known
objects in shared schemas is deferred unless a complete ownership model is
implemented first.

## Command contract

The initial CLI shape is:

```text
zig build sqlz -- bootstrap postgres \
    --project NAME \
    --from-sqlite PATH \
    [--wipe-postgres] \
    [--yes] \
    [--postgres-url URL]
```

Behavior:

- `--project` may be inferred only under the normal single-registration rule.
- `--from-sqlite` is required and is opened read-only.
- `--postgres-url` or `DATABASE_URL` supplies the destination connection.
- `--wipe-postgres` never implies `--yes`.
- `--yes` has no destructive effect unless `--wipe-postgres` is also present.
- Human output reports preflight, table-level progress, validation, and the final
  result without row values or secrets.
- JSON output follows the versioned CLI record contract and keeps incidental
  progress on stderr.
- Stable failures distinguish source mismatch, incompatible transfer mapping,
  nonempty destination, unsafe wipe boundary, unsupported value conversion,
  migration failure, row-copy failure, and post-copy validation failure.

## Execution flow

```text
load registered project
-> discover and validate migration graph
-> derive SQLite and PostgreSQL catalogs
-> open SQLite read-only
-> validate live SQLite schema
-> build a pure transfer plan
-> connect to PostgreSQL
-> resolve destination ownership and capabilities
-> preflight empty or wipe policy
-> acquire PostgreSQL project lock
-> repeat destination preflight under lock
-> confirm wipe when requested
-> begin PostgreSQL transaction
-> wipe managed namespace when requested
-> apply PostgreSQL migrations through the normal runner
-> begin stable SQLite read snapshot
-> copy planned tables
-> restore identity and sequence state
-> validate row counts and constraints
-> record successful migration/bootstrap state
-> commit PostgreSQL
-> release SQLite snapshot and PostgreSQL lock
```

No destination mutation occurs before the transfer plan and wipe boundary are
known to be valid.

## Work plan

### Phase 0: Normative design

Status: partially complete.

- Add bootstrap to [cli.md](cli.md), including `--wipe-postgres`, confirmation,
  output, and exit behavior.
- Add a proposed ADR for project-backed SQLite-to-PostgreSQL bootstrap and the
  managed-namespace wipe boundary.
- Update [security.md](security.md), [testing.md](testing.md), and migration
  documentation with the new destructive operation and credential/data privacy
  rules.
- Resolve whether 0.1 requires a dedicated PostgreSQL application schema. The
  recommended initial rule is that wipe support requires one.

Acceptance gate: the source identity, destination ownership boundary, wipe
behavior, supported conversions, and reduced-atomicity policy are unambiguous.

### Phase 1: CLI and migration prerequisites

Status: partially complete. The host command and project registration are
implemented. Bootstrap currently performs transactional head replay directly;
the shared stateful migration runner remains blocked by
[implementation-plan.md](implementation-plan.md).

- Implement the unified host CLI and registered-project routing.
- Implement the pure migration planner, PostgreSQL state schema, canonical
  checksums, advisory locking, journal, and PostgreSQL migration runner.
- Add confirmation plumbing shared by downgrade, state repair, journal prune,
  and bootstrap wipe.
- Add a destination inspection API that classifies an empty baseline, a managed
  sqlz project, unrelated schemas, and ambiguous/shared ownership.

Acceptance gate: the CLI can safely initialize and migrate an empty PostgreSQL
destination and can identify a wipe boundary without bootstrap-specific SQL.

### Phase 2: Pure transfer planning

Status: initial implementation complete; metadata and coverage hardening remain.

- Add `src/bootstrap.zig` with backend-neutral `TransferPlan`, `TablePlan`, and
  `ColumnPlan` types.
- Derive source and destination catalogs from the same registered migration
  graph used by checking.
- Include only compatible physical tables and writable destination columns.
- Exclude views, `sqlite_%` objects, and sqlz state objects.
- Require deterministic direct table/column mappings in the initial release.
- Reject missing tables, extra source application tables, incompatible types,
  generated destination columns without an omission rule, and unsupported custom
  PostgreSQL types.
- Extend catalog metadata only when a concrete transfer rule needs it.

Acceptance gate: pure unit tests cover portable schemas, backend divergence,
quoted identifiers, views, generated/identity columns, unsupported types, and
deterministic ordering.

### Phase 3: SQLite source inspection

Status: initial implementation complete; state identity, UTF-8 policy tests, and
concurrent-writer coverage remain.

- Add a bootstrap-specific SQLite reader that opens files read-only.
- Inspect `sqlite_schema` and relevant PRAGMAs and compare the live database to
  the expected SQLite catalog.
- Validate migration identity when sqlz state exists; otherwise require complete
  structural compatibility.
- Hold one stable read transaction for the export.
- Expose runtime SQLite values through a narrow dynamic scalar representation:

```zig
pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};
```

- Define invalid UTF-8, embedded NUL, and storage-class mismatch behavior.

Acceptance gate: temporary-file tests cover empty tables, all SQLite storage
classes, structural mismatch, optional state identity, read-only enforcement,
and snapshot stability under a concurrent writer.

### Phase 4: PostgreSQL destination reset and insertion

Status: initial implementation complete for dedicated schemas and row-at-a-time
insertion. Reusable wipe planning, prepare-once insertion, and live-engine tests
remain.

- Implement managed-namespace inspection and wipe as a reusable migration/CLI
  operation rather than inline bootstrap SQL.
- Make wipe return an auditable plan listing affected schemas and object classes
  before execution.
- Add a transfer-only dynamic parameter binding path for runtime-shaped rows.
- Generate INSERT statements from validated identifiers, prepare once per table,
  and bind every value.
- Implement checked scalar conversions and precise table/row diagnostics without
  logging values.
- Reset sequences/identities from imported values after table transfer.

Acceptance gate: live PostgreSQL tests prove unrelated schemas survive wipe,
shared or ambiguous schemas are rejected, values cannot inject SQL, conversion
overflows fail, row failures roll back, and sequence next-values are correct.

### Phase 5: Bootstrap orchestration

Status: initial implementation complete. Stateful migration recording,
interactive confirmation, structured diagnostics, and JSON output remain.

- Add the `bootstrap postgres` command and compose the planner, source reader,
  destination inspector, wipe operation, migration runner, and row writer.
- Run all non-mutating preflight before confirmation and repeat destination
  checks while holding the advisory lock.
- Reject nonempty destinations by default.
- Require both `--wipe-postgres` and confirmation/`--yes` before reset.
- Apply migrations and record normal migration state before reporting success.
- Validate imported row counts and PostgreSQL constraints before commit.
- Add structured progress and terminal records for human and JSON output.

Acceptance gate: an existing compatible SQLite file bootstraps both an empty
PostgreSQL destination and, with explicit authorization, a previously managed
destination; failures do not leave partial transactional results.

### Phase 6: End-to-end hardening

Status: not started.

- Add fixtures for primary/foreign keys, cycles, nulls, uniqueness and checks,
  large text, blobs, quoted identifiers, empty tables, and sequence restoration.
- Test source mismatch, destination drift, unknown objects, lock contention,
  confirmation refusal, credential redaction, interruption, and retry behavior.
- Verify `--wipe-postgres` is false by default and `--yes` alone never wipes.
- Add a PostgreSQL version matrix and a fixture large enough to establish a
  row-at-a-time performance baseline.
- Update this plan after each implementation slice and record newly deferred
  behavior rather than silently expanding scope.

The CI integration suite now creates a temporary SQLite file containing users,
optional profiles, and sessions; invokes the public build-integrated bootstrap
command; and validates every transferred value plus both restored PostgreSQL
identity sequences. A separate disposable PostgreSQL smoke test has also
verified default nonempty-destination rejection, managed-schema wipe, and
preservation of an unrelated `public` table.

Acceptance gate: all documented safety properties have integration coverage and
the public command examples pass against supported PostgreSQL versions.

## Initial type policy

The transfer planner owns conversions; PostgreSQL is not used as an implicit
best-effort coercion engine.

| SQLite runtime value | Initial PostgreSQL targets | Rule |
| --- | --- | --- |
| NULL | nullable supported columns | reject for non-null destination |
| INTEGER | integer types | checked width conversion |
| INTEGER | boolean | only 0 and 1 are accepted |
| REAL | floating-point types | checked finite/range policy |
| TEXT | text-like types | explicit UTF-8 policy |
| BLOB | `bytea` | preserve exact bytes |

UUIDs, timestamps, JSON, numeric/decimal, enums, arrays, domains, custom codecs,
and alternate boolean encodings remain unsupported until each has an explicit
conversion and test matrix.

## Deferred scope

- Arbitrary SQLite schema inference or DDL translation.
- Import without a registered sqlz project.
- Merge, upsert, or synchronization with an existing PostgreSQL dataset.
- User-defined table and column mappings.
- Dropping a PostgreSQL database or unrelated schemas.
- Safe wipe of project objects mixed into a shared schema.
- Disabling triggers or requiring superuser privileges.
- Resumable/per-table commits and partial retry.
- PostgreSQL COPY protocol and other bulk-load optimizations.
- Nontransactional migration graphs until destructive recovery semantics are
  implemented and tested.
- Automatic conversion of types outside the initial type policy.

## Progress tracker

| Work item | Status |
| --- | --- |
| Scope and initial wipe policy documented | Complete |
| Normative CLI/security/migration docs updated | Partial |
| Bootstrap ADR accepted | Not started |
| Unified CLI prerequisite | Partial: bootstrap command only |
| PostgreSQL migration runner prerequisite | Not started |
| Pure transfer planner | Initial implementation complete |
| SQLite live source inspector | Initial implementation complete |
| PostgreSQL managed-namespace inspector/wipe | Initial dedicated-schema implementation complete |
| Dynamic PostgreSQL row insertion | Initial row-at-a-time implementation complete |
| Bootstrap orchestration | Initial implementation complete |
| End-to-end and safety test suite | Core successful bootstrap path automated in CI; wipe/failure matrix remains |
| Performance baseline | Not started |

## Open decisions

- Whether bootstrap and wipe require a dedicated PostgreSQL application schema
  in the first release. Initial implementation: yes; `public` and multiple-entry
  search paths are rejected.
- Whether the sqlz state schema may be shared by multiple registered projects.
  Recommended: no for the initial wipe implementation.
- Whether an empty destination may contain explicitly allowlisted extensions and
  unrelated schemas. Recommended: yes, provided managed ownership is
  unambiguous.
- Whether finite SQLite REAL values may target PostgreSQL `numeric`. Recommended:
  defer until decimal conversion semantics exist.
- Whether source tables absent from PostgreSQL may be explicitly excluded.
  Initial implementation: reject rather than silently omit application data.
