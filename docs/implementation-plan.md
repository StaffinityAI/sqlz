# Implementation plan

This is the dependency-ordered implementation plan for finishing sqlz 0.1. It is
the authority on implementation status; the other documents define normative
behavior. Update a slice when work is completed, split, deferred, or newly
discovered.

“Finished” means every required slice below satisfies its acceptance gate and the
0.1 release gate passes. Checkpoint migrations and history compaction are included
because the current M5 roadmap requires them, but implementation starts only after
[ADR 0036](adr/0036-checkpoint-migrations-and-history-compaction.md) is accepted or
superseded. The project-backed SQLite-to-PostgreSQL import has additional detail in
[sqlite-postgres-bootstrap-plan.md](sqlite-postgres-bootstrap-plan.md); keep both
trackers synchronized.

Status vocabulary:

- **Complete**: implemented and covered at the level required by the slice.
- **Partial**: a usable foundation exists, but the acceptance gate is not met.
- **Not started**: no production implementation exists.
- **Blocked**: work depends on an unresolved design or upstream issue.
- **Post-0.1**: deliberately outside the release scope.

## Current baseline

The following foundations are implemented and must remain green:

- strict versioned project configuration and revision-manifest parsing;
- migration discovery, DAG validation, deterministic ordering, offline catalog
  replay, and merge-parent catalog convergence for the implemented DDL subset;
- pinned `libpg_query`, direct protobuf-C AST traversal, portable named-parameter
  rewriting, and original-source position mapping;
- named `.sql` and embedded Zig query discovery, initial semantic checking for the
  implemented SQL/catalog subset, deterministic generated bindings, and build-cache
  module integration;
- SQLite and PostgreSQL checked-query runtimes with all four cardinalities,
  borrowed and owned rows, transactions, native pools, enum codecs, PostgreSQL
  one-dimensional arrays, and PostgreSQL runtime version enforcement;
- human and versioned JSON diagnostics, deterministic diagnostic accumulation,
  and rich diagnostics for the principal parser, graph, catalog, and query errors;
- lazy core-only, SQLite-only, PostgreSQL-only, both-backend, and PostgreSQL-TLS
  build configurations;
- runnable examples checked offline against both backend catalogs;
- an initial SQLite-to-PostgreSQL bootstrap with dedicated-schema reset,
  transactional PostgreSQL head replay, bound row transfer, sequence restoration,
  and one CI success path.

The main unfinished product spine is stateful migration planning and execution.
The checked-query surface is functional but still has source-manager, parser,
catalog, codec, generated-API, runtime-safety, observability, build, and release
hardening gaps.

## Ordered feature slices

### 1. Reconcile current-status documentation

**Status:** Partial

**Depends on:** Nothing

**Deliverables:**

- Update `README.md` and `docs/README.md` to say that both checked-query runtimes
  exist and stateful migration execution is the largest missing subsystem.
- Distinguish migration discovery/offline replay from database migration execution.
- Describe `bootstrap postgres` as an initial partial command, not the full CLI.
- Correct stale driver/Ziggy pins and unsupported build-option claims.
- Keep the divergence register at the end of this document current.

**Acceptance gate:** A checked documentation-status table lists each top-level
subsystem and matches this plan, the public README, and the codebase.

### 2. Fix source trust boundaries and configuration enforcement

**Status:** Partial

**Depends on:** Slice 1

**Deliverables:**

- Threat-model configured roots, symlinks, generated cache paths, dynamic SQL
  identifiers, state ownership, schema privileges, destructive commands, secrets,
  journals, and telemetry before their consumers are implemented.
- Canonicalize configured paths and reject file/directory symlink escapes unless an
  external root was explicitly registered by the build.
- Enforce revision count, query count, total registered source bytes, and diagnostic
  limits before large allocations or partial generated output.
- Define a fixed bootstrap maximum for reading `sqlz.ziggy`, then enforce the
  parsed `source_bytes` limit against the configuration file and every other input.
- Count configuration, migrations, SQL, Zig roots, supplements, checkpoint files,
  and `history.ziggy` consistently.
- Propagate `allow_untested_version`, `warnings_as_errors`, and migration lock
  timeout into generated/runtime configuration where applicable.
- Keep only the reviewed SQLite `bundled` capability profile in 0.1 unless another
  profile receives an explicit design and conformance matrix.

**Acceptance gate:** Boundary and boundary-plus-one fixtures exist for every
project-level limit, symlink escape fixtures fail closed, and a field-usage test or
documented deferral exists for every format-1 configuration field.

### 3. Complete source-manager and lexer correctness

**Status:** Partial

**Depends on:** Slice 2

**Deliverables:**

- Accept a UTF-8 BOM while excluding it from displayed source columns; reject
  malformed UTF-8 with byte-accurate diagnostics.
- Keep source offsets byte-based, count display columns by Unicode scalar value,
  render tabs at width four, index LF and CRLF correctly, and preserve original
  bytes for checksums and excerpts.
- Recognize PostgreSQL dollar-quoted strings and all supported string, identifier,
  comment, cast, and operator contexts during named-parameter rewriting.
- Enforce `tokens_per_source` and `nesting_depth` during rewriting, parsing, Zig
  declaration discovery, and AST adaptation.
- Add parameter rewrite/source-map properties and fuzz targets for SQL bytes,
  directives, Zig declarations, and manifest inputs.

**Acceptance gate:** Golden fixtures cover BOM, malformed UTF-8, multibyte text,
tabs, LF/CRLF, every quote/comment form, dollar quotes, and rewritten positions;
arbitrary bytes and deep nesting cannot panic, hang, or bypass configured limits.

### 4. Complete the documented SQL and migration-DDL surface

**Status:** Partial

**Depends on:** Slice 3

**Deliverables:**

- Maintain a checked feature matrix for the practical query subset: SELECT,
  INSERT, UPDATE, DELETE, VALUES, joins, subqueries, compound queries, grouping,
  aggregates, ordering, limits, CTEs, CASE, expressions, casts, conflict/upsert
  forms, RETURNING, and supported PostgreSQL array/JSON operators.
- Maintain a checked feature matrix for create/drop/rename table; add/drop/rename
  column; primary, unique, foreign-key, check, and not-null constraints; partial
  indexes; views; PostgreSQL schemas/enums/domains; and SQLite STRICT,
  WITHOUT ROWID, generated columns, and supported table options.
- Implement profile/capability accept/reject gates for SQLite 3.45-3.53 and
  PostgreSQL 15-18 rather than accepting an unused profile value.
- Implement and validate `-- sqlz.opaque: no-schema-change`; reject it on known
  schema-changing statements and require supplements for visible opaque objects.
- Parse and type-check downgrade SQL and add upgrade-then-downgrade fixtures that
  restore an empty user catalog for every reversible history.
- Preserve atomic per-revision catalog replay and improve exact unsupported-syntax
  spans, especially for SQLite-normalized input.

**Acceptance gate:** Every row in the normative query/DDL matrix has positive,
negative, profile, and diagnostic fixtures; opaque-directive and reversible
round-trip suites pass on both backend catalogs.

### 5. Implement versioned builtin catalogs and project supplements

**Status:** Not started

**Depends on:** Slices 2-4

**Deliverables:**

- Add reviewed catalogs for supported SQLite profiles and PostgreSQL majors with
  types, aliases, scalar functions, aggregates, operators, casts, pragmas,
  nullability rules, provenance, and profile ranges.
- Implement reviewed type variables, equality constraints, coercions, overload
  selection, and array-element relationships required by those entries.
- Parse Ziggy supplements with backend/profile constraints, types, signatures,
  nullability, volatility where relevant, and codec patterns.
- Enforce resolution order: migration objects, project supplements, builtins.
- Reject duplicate identities, ambiguous overlapping signatures, migration-object
  redefinitions, and illegal builtin overrides.
- Include catalog/supplement identity and bytes in cache keys and the later
  migration semantic fingerprint.

**Acceptance gate:** A profile-by-feature fixture matrix covers overloads,
ambiguity, coercion, aggregate nullability, operators, casts, aliases, supplement
precedence, conflicts, and provenance for SQLite 3.45-3.53 and PostgreSQL 15-18.

### 6. Finish semantic diagnostics and warnings

**Status:** Partial

**Depends on:** Slices 4-5

**Deliverables:**

- Give every catalog, IR, inference, declaration, and unsupported-feature failure
  a stable code, primary/secondary spans, and actionable notes/fixes where possible.
- Replace token-heuristic attribution with AST/catalog origin data where available.
- Accumulate malformed SQL directives and embedded declarations across files.
- Implement the 0.1 warning registry, including non-STRICT SQLite schema use,
  `SELECT *`, visibly unconstrained `.one`, and explicitly allowed newer engines.
- Apply warning caps and `warnings_as_errors` consistently in human and JSON modes.
- Freeze the diagnostic/warning registry before compatibility fixtures are final.

**Acceptance gate:** Every registered error and warning code has deterministic
human/JSON golden coverage, multi-file discovery accumulates to the configured cap,
and no known checker failure uses an unexplained file-start fallback.

### 7. Complete builtin application types and general codecs

**Status:** Partial

**Depends on:** Slices 5-6

**Deliverables:**

- Implement `sqlz.Uuid` and audit `Json`, `Date`, `Timestamp`, and `TimestampTz`
  mappings across checking, portability, SQLite storage, and PostgreSQL wire data.
- Implement general `Binder`/`Decoder` hooks, backend implementations,
  `borrows_result`, distinct value/owned types, `cloneOwned`, and `deinitOwned`.
- Validate codec declarations and reject missing backend support, invalid ownership
  hooks, incompatible database patterns, and codecs pinned to builtin fields.
- Support nullable parameters/results and recursive owned conversion; permit arrays
  only where a codec explicitly defines safe behavior.
- Convert codec failures into owned sqlz errors without traps, leaks, value logging,
  or connection corruption.

**Acceptance gate:** Compile-pass/fail fixtures and live backend tests cover
borrowed/owned custom scalars, nullability, errors, UUIDs, and supported arrays;
`assertCodec` accepts documented non-enum codecs.

### 8. Stabilize generated and embedded query metadata

**Status:** Partial

**Depends on:** Slice 7

**Deliverables:**

- Resolve the `Row`/`OwnedRow` promise by emitting named declarations or revising
  the normative API before 0.1.
- Generate PostgreSQL positional SQL, ordered parameter metadata, source maps, and
  backend metadata for embedded declarations.
- Define versioned generated-query metadata separately from local cache keys and
  persisted migration fingerprints.
- Define stable query-ID derivation for preparation hints, telemetry, and debug
  context; exclude absolute paths/cosmetic edits and change IDs for semantic SQL or
  contract changes.
- Decide how imported/qualified `.params`/`.row` types are verified, or freeze a
  precise limitation with compile fixtures.
- Preserve deterministic namespaces, backend variant comparison, and lazy imports.

**Acceptance gate:** Embedded PostgreSQL queries execute live, named and embedded
queries expose one documented surface, metadata/query-ID vectors are stable, and
repeated generation is byte-identical for identical logical input.

### 9. Finalize runtime error and telemetry contracts

**Status:** Partial for errors; telemetry not started

**Depends on:** Slices 6-8

**Deliverables:**

- Finalize owned `sqlz.Error` fields for backend, operation, retry hint, SQLite
  extended code or PostgreSQL SQLSTATE, optional constraint/table/column fields,
  and sensitive native diagnostics.
- Define the redacted safe subset used by journals, JSON, and telemetry.
- Add an optional lifecycle callback framework and versioned event types for
  acquisition, query completion, failure, version override, migration, and
  checkpoint operations. Later slices emit their operation-specific events.
- Include only safe IDs, backend, duration, row count, category/code, project,
  revision, and checkpoint metadata.
- Guarantee callback failure or slowness cannot alter database semantics or result
  ownership.

**Acceptance gate:** Ownership/allocation-failure tests pass, redaction fixtures
cover the currently implemented transports, and the callback framework is disabled
by default, versioned, and noninterfering. Operation-specific event coverage is
owned by the slices implementing those operations.

### 10. Close SQLite runtime safety and version gaps

**Status:** Partial

**Depends on:** Slices 7 and 9

**Deliverables:**

- Validate non-STRICT SQLite storage classes before decoding all scalar, enum, and
  custom-codec values; retain narrow numeric range checks.
- Classify storage/type mismatches as structured invalid-data errors.
- Detect rollback or drain failure during cleanup, poison the connection, and
  discard pooled handles instead of reusing them.
- Enforce configured SQLite profile versions at connection and migration time:
  reject older engines and newer engines unless `allow_untested_version` is set;
  emit the documented warning/event for the allowed newer case.
- Cover direct, borrowed, transaction, stream, and pooled ownership modes with
  failure injection.

**Acceptance gate:** Wrong-storage-class, older/supported/newer-version, rollback,
drain, and pool-replacement matrices pass and match the runtime/type-system docs.

### 11. Close PostgreSQL runtime conformance gaps

**Status:** Partial; some pooled payload detail is blocked by pinned `pg.zig`
recovery behavior

**Depends on:** Slices 7 and 9

**Deliverables:**

- Prove direct and pooled operations on a zio-backed `std.Io` socket path.
- Add certificate-backed TLS tests for trusted CA, hostname validation, bad CA,
  bad hostname, and invalid certificate.
- Populate SQLSTATE and available server fields in the finalized error contract.
- Ensure failed rollback, drain, cancellation, or protocol recovery marks a
  connection dirty and causes pool replacement.
- Expose the connection-level cancellation/timeout primitives needed later by the
  migration runner; do not add the deferred portable checked-query options API.
- Track or update `pg.zig` so detailed pool-direct payloads are retained wherever
  the driver permits it.

**Acceptance gate:** The PostgreSQL 15-18 direct/pool matrix covers zio, TLS,
SQLSTATE ownership, dirty cleanup, connection-level cancellation/timeout primitives,
and version overrides; any upstream limitation is linked and narrowly documented.

### 12. Prove build invalidation and atomic cache behavior

**Status:** Partial

**Depends on:** Slices 2, 5, and 8

**Deliverables:**

- Test same-cache edits, additions, removals, and nested SQL, Zig, Ziggy, migration,
  and supplement inputs. Register checkpoint and `history.ziggy` candidate inputs
  now; their semantic invalidation tests land with slices 21-24.
- Define local content-addressed cache keys separately from generated-query metadata
  and persisted migration fingerprints.
- Test generated config paths, exact root-bounded registration, directory watches,
  multiple projects, ambiguous routing, codec bindings, and cross compilation.
- Prove disabled drivers are not fetched, imported, linked, or embedded.
- Use atomic output replacement; failure/interruption must leave the previous valid
  cache entry intact and stale output must not compile as a successful check.
- Remove `sqlite_system` from the 0.1 contract, or design runtime version/compile-
  option verification that proves compatibility with a reviewed capability profile.

**Acceptance gate:** Build fixtures cover every invalidation transition, warm cache
hit, generation failure point, project/backend combination, and host/target split.

### 13. Close migration and bootstrap design gates

**Status:** Blocked

**Depends on:** Slices 1-2

**Deliverables:**

- Accept or supersede ADR 0036 and update the 0.1 scope if checkpoint compaction is
  removed or materially changed.
- Accept a bootstrap ADR covering project-backed transfer, managed namespace
  ownership, destructive wipe boundaries, state identity, and atomicity limits.
- Settle physical state table/schema names, advisory-lock key derivation, safe
  statement-journal boundaries, and the public migration result identifiers.
- Record the security decisions for privileges, ownership, confirmations, journal
  payloads, and destination inspection before runner implementation.

**Acceptance gate:** Accepted/superseding ADRs and implementation notes leave no
open architectural decision required by slices 14-29.

### 14. Implement the ordinary migration planner

**Status:** Not started

**Depends on:** Slices 2, 4, and 13

**Deliverables:**

- Model format-1 physical applied revisions, unknown state, and unavailable SQL
  without checkpoint concepts.
- Parse `base`, full IDs, unambiguous prefixes, `head`, `heads`, `+N`, and `-N`.
- Compute deterministic upgrade/downgrade plans across linear, branch, and merge
  graphs with backend no-op nodes.
- Reject invalid applied ancestry, retained children on downgrade, ambiguous or
  unknown targets, unsupported transaction policy, and missing downgrade SQL.
- Preflight irreversible revisions before mutation.
- Keep the planner backend-neutral and reusable by CLI, runtime, and bootstrap.

**Acceptance gate:** A named planner matrix covers every target form, valid/invalid
partial applied set, branch/merge order, no-op node, downgrade safety, ambiguity,
and irreversible preflight without a database connection.

### 15. Implement canonical migration identity and checksums

**Status:** Not started

**Depends on:** Slices 5, 12-14

**Deliverables:**

- Define canonical manifest, content, effective-SQL, and parent-set checksums.
- Define a persisted semantic project fingerprint separately from cache keys,
  excluding cosmetic paths/descriptions and including migration interpretation,
  profiles, supplements, codec database patterns, and later history metadata.
- Add stable cross-run fixture vectors and format versions.
- Detect edited applied SQL/manifests, parent rewrites, project UUID mismatch,
  semantic configuration drift, and unknown revisions.

**Acceptance gate:** Fixed vectors prove stable hashes; cosmetic edits remain
cosmetic, semantic edits change the expected digest, and each mismatch has a stable
runtime/CLI error.

### 16. Implement the ordinary versioned database state store

**Status:** Not started

**Depends on:** Slices 9, 13-15

**Deliverables:**

- Create versioned SQLite reserved tables and the PostgreSQL state schema/tables
  for metadata, applied revisions, command runs, and revision/statement steps.
- Implement initialization, reading, validation, and forward-only transactional
  upgrades under a migration lock.
- Store project identity, semantic fingerprint, revision checksums, parent sets,
  application times, and state format version.
- Reject newer unknown formats, invalid ancestry, unknown revisions, edited
  checksums, project mismatch, and incompatible semantic fingerprints.
- Expose one backend-neutral ordinary state snapshot.

**Acceptance gate:** SQLite and PostgreSQL initialize/read/upgrade/corruption
fixtures produce equivalent logical snapshots for the same ordinary history.

### 17. Implement the durable operation journal and recovery model

**Status:** Not started

**Depends on:** Slices 13 and 16

**Deliverables:**

- Record append-only command runs and ordered revision/statement steps using only
  the safe error subset.
- Update applied state only at successful transaction boundaries; do not add a
  global dirty bit.
- Define recovery choices for transactional failure, partially executed PostgreSQL
  `never` revisions, connection loss, cancellation, and interrupted commands.
- Retain journals indefinitely by default and define confirmed, auditable pruning.
- Never persist SQL, parameters, values, credentials, or full native diagnostics.

**Acceptance gate:** A named failure-injection matrix reconstructs every supported
interrupted state from state plus journal and requires explicit action whenever
continuation is ambiguous.

### 18. Implement the SQLite migration runner

**Status:** Not started

**Depends on:** Slices 10 and 14-17

**Deliverables:**

- Acquire an immediate write transaction with configured busy/lock timeout; never
  run unlocked.
- Initialize/upgrade state and validate identity/checksums before execution.
- Preflight the whole plan, execute each revision transactionally, update applied
  state only on success, and journal command/revision boundaries.
- Execute downgrade SQL in correct reversed layering/order and enforce irreversible
  boundaries.
- Return shared structured plan/progress/status/result values.
- Emit migration lifecycle telemetry through the Slice 9 framework.

**Acceptance gate:** Integration coverage includes linear/branch/merge upgrade,
downgrade, lock timeout, SQL rollback, interruption/retry, state upgrade,
identity/checksum drift, journal visibility, and poisoned connection handling.

### 19. Implement the PostgreSQL migration runner

**Status:** Not started

**Depends on:** Slices 11 and 14-17

**Deliverables:**

- Acquire a project-scoped advisory lock with configured timeout; never run
  unlocked.
- Initialize/upgrade state and perform the same full-plan/identity validation as
  SQLite.
- Execute `always` revisions atomically and `never` revisions statement by
  statement with durable journal boundaries.
- Define splitting/execution and recovery after partial nontransactional work,
  connection loss, cancellation, or server failure.
- Support upgrade/downgrade and dirty-connection replacement.
- Use the Slice 11 cancellation/timeout primitives for lock and recovery behavior.
- Emit migration lifecycle telemetry through the Slice 9 framework.

**Acceptance gate:** PostgreSQL 15-18 tests cover transactional/nontransactional
revisions, lock timeout, connection loss, cancellation, partial-step recovery,
upgrade/downgrade, and identity/checksum drift. This slice does not depend on the
SQLite runner.

### 20. Add ordinary migration status, history, and plan operations

**Status:** Not started

**Depends on:** Slices 14-19

**Deliverables:**

- Expose shared read-only state validation, target resolution, status, history, and
  plan operations.
- Return structured records for runtime callers plus concise human and versioned
  JSON representations.
- Distinguish applied, pending, unknown, invalid, irreversible, and unavailable-SQL
  states.
- Never prompt or request mutation privileges for read-only operations.

**Acceptance gate:** A checked output matrix proves equivalent SQLite/PostgreSQL
state facts and equivalent runtime, human, and JSON plans for shared fixtures.

### 21. Implement checkpoint manifest format and planner extension

**Status:** Blocked on Slice 13

**Depends on:** Slices 13-20

**Deliverables:**

- Preserve format-1 ordinary semantics and add format-2 tagged revision/checkpoint
  manifests.
- Validate no-parent/irreversible rules, `through`, exact `replaces`, scope,
  backend coverage, non-empty SQL, replacement closure, single logical head, and
  global/finalized ID reservation.
- Exclude checkpoint nodes from ordinary root/head/merge/query-head logic.
- Extend planner types with physical application, logical coverage, checkpoint
  bootstrap evidence, and alternate empty-database paths.
- Add checkpoint/history fields to semantic fingerprints without changing ordinary
  format-1 checksum meaning.

**Acceptance gate:** Format-1 compatibility remains byte-stable; format-2 and
planner fixtures cover closure, coverage, collision, ambiguity, coexistence,
partial deployment, and finalized-ID reuse.

### 22. Verify checkpoint equivalence and fresh selection

**Status:** Not started

**Depends on:** Slice 21

**Deliverables:**

- Replay the original ancestor closure and checkpoint independently per backend and
  compare object/type/constraint/index/view catalog facts.
- Report object-level divergence and reduced proof from opaque directives.
- Detect DML-bearing checkpoint files, never claim data equivalence, and require
  explicit author acknowledgement.
- Permit selection only for an empty applied set, no incomplete command/evidence,
  and no user objects in managed namespaces.
- Select the unique maximal eligible checkpoint; reject duplicate or incomparable
  maximal candidates; support `--no-checkpoint`.

**Acceptance gate:** A named checkpoint matrix covers schema equivalence,
divergence, opaque proof, DML acknowledgement, empty baseline, ambiguity,
historical coexistence, and refusal to jump from partial history on both backends.

### 23. Implement checkpoint state, adoption, and finalization

**Status:** Not started

**Depends on:** Slices 17 and 21-22

**Deliverables:**

- Add a forward state upgrade for bootstrap/adoption evidence and replacement
  tombstones without fabricating ordinary applied rows.
- Persist checkpoint ID, `through`, replacement digest, SQL checksum, catalog
  fingerprints, registry checksum, and adoption evidence.
- Adopt only after exact revision, parent, checksum, replacement, and catalog proof;
  execute no checkpoint SQL.
- Implement confirmed finalization that emits exact removable sources and writes a
  sorted versioned `history.ziggy` without deleting files.
- Treat history entries as non-executable virtual nodes, reserve IDs permanently,
  and fail specifically for below-boundary upgrades after pruning.
- Support repeated compaction only after the previous transition is finalized.
- Emit checkpoint validation, selection, adoption, and finalization telemetry.

**Acceptance gate:** Fixtures cover bootstrap/adoption evidence, drift, pruning,
below/at/beyond-boundary states, downgrade refusal, registry tampering, interrupted
finalization, and repeated compaction.

### 24. Generate runtime migration bundles and APIs

**Status:** Not started

**Depends on:** Slices 14-23

**Deliverables:**

- Generate a versioned migration module containing validated manifests, enabled
  backend SQL, checksums, graph data, checkpoint paths, and history tombstones.
- Keep backend-specific data lazy and deterministic.
- Expose runtime `plan`, `status`, `upgrade`, and `downgrade` using the exact shared
  planner, locks, state upgrades, runners, journal, and result values.
- Never read repository migration files or shell out at runtime.
- Add backward-read bundle metadata fixtures.

**Acceptance gate:** Runtime/host planning matches for all migration fixtures, both
backend runners execute generated bundles, and disabled backends add no bundle code
or dependency. Checkpoint/history input edits, additions, and removals invalidate
the generated bundle and checker metadata.

### 25. Implement the unified build-integrated CLI shell

**Status:** Partial; bootstrap-only routing exists

**Depends on:** Slices 6, 12, and 20

**Deliverables:**

- Route `zig build sqlz -- <command>` across registered projects; infer a project
  only when unambiguous.
- Share argument parsing, connection options, confirmation, output, redaction, and
  exit classification.
- Emit concise human output and JSON-only stdout with versioned records.
- Implement interactive confirmation and noninteractive `--yes`, failing before a
  mutation transaction when authorization is absent.
- Implement `init`, `check`, `status`, `history`, `plan`, `revision create`, and
  `revision merge` without schema autogeneration.

**Acceptance gate:** A command matrix covers grammar, multi-project routing,
stdout/stderr, exit codes, JSON versions, confirmation, redaction, and refusal
without mutation.

### 26. Add migration, state, journal, and checkpoint CLI commands

**Status:** Not started

**Depends on:** Slices 18-25

**Deliverables:**

- Add migration upgrade and confirmed downgrade.
- Add state init, stamp, repair, and rebind with strict preflight and journal entries.
- Add journal show and confirmed prune.
- Add checkpoint create, verify, adopt, and finalize with DML acknowledgement and
  exact removable-file output.
- Report lock timeouts, physical/logical coverage, selected replay path, and
  recovery requirements in human and JSON formats.

**Acceptance gate:** CLI/runtime plans are equivalent and every command has named
human/JSON, confirmation, failure, and backend integration fixtures where relevant.

### 27. Harden bootstrap transfer planning and source inspection

**Status:** Partial

**Depends on:** Slices 2, 7, 10, and 15-16

**Deliverables:**

- Extend catalog metadata only as needed for physical/writable tables, generated,
  default, and identity columns, constraints, and sequences.
- Require deterministic direct mappings; reject missing/extra tables, incompatible
  nullability/types, generated columns without omission rules, unsupported custom
  types, and silent data omission.
- Validate source sqlz state identity when present; otherwise require complete
  structural compatibility.
- Hold a stable read-only snapshot and test concurrent writers.
- Define UTF-8, embedded-NUL, storage-class, integer-width, finite-real, boolean,
  text, and blob conversion rules without logging values.
- Prepare inserts once per table, bind all values, restore identities, and validate
  counts/constraints before commit.

**Acceptance gate:** Pure and temporary-file matrices cover backend divergence,
quoted identifiers, views, generated/identity columns, every SQLite storage class,
state/structure mismatch, snapshot stability, overflow, and deterministic order.

### 28. Converge bootstrap on shared migration and CLI primitives

**Status:** Partial

**Depends on:** Slices 19-20 and 25-27

**Deliverables:**

- Replace private head replay with the shared PostgreSQL planner/runner, state,
  checksums, lock, and journal.
- Reuse a destination inspector/wipe planner that classifies empty baseline,
  matching project, unrelated schemas, and ambiguous/shared ownership.
- Emit an auditable affected-object plan; preserve unrelated schemas and reject
  mixed ownership.
- Run non-mutating preflight before confirmation and repeat destination checks under
  the advisory lock.
- Support interactive confirmation, `--yes`, human/JSON records, stable errors,
  redaction, and configured lock timeout.

**Acceptance gate:** Bootstrap uses no private migration execution path, leaves
valid ordinary state/journal evidence, and safely handles empty and explicitly
wiped managed destinations.

### 29. Complete bootstrap safety and version coverage

**Status:** Partial

**Depends on:** Slice 28

**Deliverables:**

- Add fixtures for keys, cycles, nulls, uniqueness/checks, large text/blobs, quoted
  identifiers, empty tables, and sequence restoration.
- Test source mismatch, destination drift, unknown objects, shared ownership, lock
  contention, confirmation refusal, credential redaction, row rollback,
  interruption, and retry.
- Prove wipe defaults false and `--yes` alone never wipes.
- Run PostgreSQL 15-18 and establish a versioned row-at-a-time baseline.
- Keep UUID/timestamp/JSON/numeric/enum/array/domain/custom-codec conversions,
  mappings, synchronization, resumability, and COPY deferred until designed.

**Acceptance gate:** Every safety row in the bootstrap test matrix passes on the
supported PostgreSQL majors and public command examples match the implementation.

### 30. Complete security and privacy verification

**Status:** Partial

**Depends on:** Slices 2 and 9-29

**Deliverables:**

- Verify every early threat-model decision against final code and tests.
- Ensure dynamic identifiers originate in validated catalogs and use dialect-aware
  quoting; keep values bound.
- Test redaction across human/JSON output, runtime errors, journals, telemetry,
  URLs, backend diagnostics, and checkpoint/bootstrap data.
- Fail closed on privilege, ownership, identity, confirmation, lock, and format
  failures.
- Add dependency hash/license and builtin-catalog provenance checks.

**Acceptance gate:** A security traceability table maps every promise in
`security.md` to a test, automation check, or explicit documented trust assumption.

### 31. Complete platform, engine, differential, fuzz, and recovery CI

**Status:** Partial

**Depends on:** Feature slices as they land

**Deliverables:**

- Run full runtime suites on x86_64 Linux and arm64 macOS; compile-check Windows.
- Add SQLite 3.45-3.53 differential/profile jobs and retain PostgreSQL 15-18 jobs.
- Add certificate TLS, zio PostgreSQL, cross-compilation, state/lock/recovery,
  checkpoint, CLI, and bootstrap failure jobs.
- Add parser, catalog, declaration, graph, and planner fuzz/property suites with
  retained regression corpora.
- Keep the pre-commit/offline gate deterministic and service-free.

**Acceptance gate:** A checked CI matrix exactly matches `testing.md` and
`compatibility.md`, with a named job or documented local gate for every row.

### 32. Establish performance baselines and numeric gates

**Status:** Not started

**Depends on:** Slices 8, 18-19, 24, and 29

**Deliverables:**

- Benchmark cold/warm checking, parser throughput, catalog/migration replay,
  planning/state writes, generated size/compile time, row decoding, streaming,
  pools, runtime migration, and bootstrap transfer.
- Compare wrappers with direct drivers where fair.
- Version hardware class, build mode, engines, fixtures, repetitions, variance,
  allocations, memory, and cache hit/miss results.
- Set numeric regression, variance, memory, and generated-growth gates.

**Acceptance gate:** Every benchmark named in `performance.md` or this slice has a
reproducible runner, recorded baseline, owner, and enforced numeric threshold.

### 33. Freeze formats, APIs, compatibility, and release documentation

**Status:** Not started

**Depends on:** Slices 1-32

**Deliverables:**

- Freeze versions for configuration, manifests, history registry, query metadata,
  migration bundles, CLI JSON, and database state.
- Add backward-read fixtures and reject unknown newer formats.
- Freeze public identifiers, runtime/query/migration APIs, diagnostic codes,
  command grammar, and exit classes under the documented SemVer policy.
- Reconcile normative docs, code, tests, examples, status banners, and limitations.
- Remove closed divergences and preserve intentional ones explicitly.

**Acceptance gate:** A checked feature-to-doc-to-test traceability manifest has no
missing required 0.1 row and all persisted-format compatibility fixtures pass.

### 34. Pass the sqlz 0.1 release gate

**Status:** Not started

**Depends on:** Slices 1-33

**Deliverables:**

- Run formatting, offline, runtime, integration, fuzz/property, platform/engine,
  compatibility, security, and performance gates from clean and warm caches.
- Verify deterministic query generation and migration bundles.
- Run every public example and CLI success/failure/recovery workflow.
- Query the release-blocker issue set defined by project labels and close or defer
  every item without contradicting normative 0.1 behavior.
- Publish exact Zig, driver, Ziggy, engine, platform, TLS, and deferred-scope claims.

**Acceptance gate:** The release checklist, CI matrix, traceability manifest,
format fixtures, benchmark gates, examples, and defined release-blocker query are
all green; remaining work is only the post-0.1 scope below.

## Dependency summary

The critical path is:

1. Source/checker/runtime foundations: slices 1-12.
2. Design decisions and ordinary migration core: slices 13-20.
3. Checkpoint extension: slices 21-23.
4. Runtime migration and unified CLI: slices 24-26.
5. Bootstrap hardening and convergence: slices 27-29.
6. Release verification and stabilization: slices 30-34.

SQLite and PostgreSQL runners branch independently from the shared planner, state,
and journal. Ordinary migration work remains separate from checkpoint extensions.
Query/catalog/codec hardening may proceed in parallel with the ordinary migration
core where the listed dependencies permit it. No CLI or bootstrap feature may grow
a private planner, state store, journal, or migration runner.

## Tracked current divergences

| Promise or contract | Current state | Closing slice |
| --- | --- | --- |
| Current status is consistent across public docs | Root and docs index understate implemented PostgreSQL/checker work | 1 |
| All configuration limits and path boundaries are enforced | Only part of the limits and lexical path checks are active | 2-3 |
| Source manager follows BOM/UTF-8/column/line-ending rules | Position mapping exists; the full contract lacks coverage | 3 |
| Full documented query/DDL subset, opaque directives, and downgrade checks | A practical subset exists; unsupported and round-trip gaps remain | 4 |
| Versioned builtin catalogs and supplements | Narrow hard-coded semantics exist; supplements are not loaded | 5 |
| Complete diagnostics and warning policy | Core cases are rich; some failures are generic and warnings are absent | 6 |
| General codecs and documented builtin application types | Derived enums work; general codecs and UUID are absent | 7 |
| Named rows, embedded backend metadata, stable query IDs | Generated/embedded metadata remains incomplete | 8 |
| Detailed structured errors and telemetry | Basic owned errors exist; telemetry is absent | 9 |
| Non-STRICT validation, SQLite version policy, rollback poisoning | Partial range checks/runtime cleanup exist | 10 |
| PostgreSQL zio sockets, live TLS, detailed pooled errors | Plain TCP and TLS compilation exist | 11 |
| Automated invalidation, atomic output, semantic cache keys | Inputs are broadly registered but guarantees are incomplete | 12 |
| Stateful ordinary migration planner/state/journal/runners | Only graph discovery and offline replay exist | 14-20 |
| Checkpoints/history compaction | Designed, ADR still Proposed, no code exists | 13, 21-23 |
| Runtime migration module | Not generated | 24 |
| Full unified CLI | Bootstrap-only operational routing exists | 25-26 |
| Bootstrap uses normal state/runner and full safety matrix | Private head replay and initial transfer path exist | 27-29 |
| Full security/platform/fuzz/performance/compatibility gates | Core CI exists; release matrix is incomplete | 30-34 |

## Explicit post-0.1 scope

Do not add these to the critical path unless normative scope is deliberately
changed:

- additional database drivers, dynamic backend loading, or runtime `AnyDatabase`;
- ORM/model persistence, relationships, active record, or a query-builder DSL;
- migration autogeneration or schema diffing;
- live-database query checking or SQL analysis during Zig comptime;
- attached SQLite databases, complete dialect-extension parity, full PostgreSQL
  polymorphism, or multidimensional PostgreSQL arrays;
- checking queries against several rolling-deployment revisions;
- a public portable cancellation/query-timeout/fetch-size/generic options API;
- a sqlz-owned pool or statement cache;
- automatic proof of DML convergence at merge revisions;
- direct generated mapping of named SQL rows into arbitrary domain structs;
- Windows runtime support guarantees;
- nested transactions/savepoints as a guaranteed API;
- bootstrap without a registered project, arbitrary SQLite DDL inference,
  user-defined table/column mappings, merge/upsert synchronization, shared-schema
  wipe, trigger disabling/superuser assumptions, resumable per-table commits, COPY
  optimization, or automatic conversions outside the explicitly tested policy.
