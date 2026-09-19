# Implementation plan

This is the live implementation checklist for the first checked-query release.
SQLite and the initial PostgreSQL runtime are implemented. Migration execution,
the full CLI, and release hardening remain.

The project-backed SQLite-to-PostgreSQL import is tracked separately in
[sqlite-postgres-bootstrap-plan.md](sqlite-postgres-bootstrap-plan.md). Keep its
progress tracker synchronized as prerequisite or bootstrap-specific work lands.

## Recommended Remaining Sequence

This is the source of truth for work ordering. Keep it current whenever a slice
is completed, split, deferred, or newly discovered.

1. Complete the remaining PostgreSQL conformance edges: cancellation/timeouts,
   runtime version-policy overrides, zio-backed sockets, certificate-backed TLS,
   and detailed SQLSTATE payloads after the pg.zig recovery limitation is fixed.
2. Convert manifest, graph, catalog, and semantic query-analysis failures onto
   richer component-specific source labels/fixes. Parser syntax spans and
   deterministic query-file accumulation up to the configured limit are complete.
3. Add PostgreSQL builtin catalogs for functions, aggregates, operators, casts,
   type aliases, and profile-specific behavior.
4. Implement the pure migration planner: applied sets, target parsing, ancestor
   closures, deterministic upgrade/downgrade plans, ancestry safety, and
   irreversible-revision preflight. Its data model must distinguish physical
   application, logical checkpoint coverage, and alternate empty bootstrap paths.
5. Implement canonical checksums, project/configuration identity, the versioned
   database state schema, and forward-only state upgrades, reserving explicit
   checkpoint evidence and compacted-history registry fields.
6. Implement the SQLite migration runner with locking, transactional execution,
   applied-state updates, journaling, and interruption/failure tests.
7. Implement the PostgreSQL migration runner with advisory locking,
   transactional and nontransactional revisions, statement journaling, and
   recovery behavior.
8. Implement checkpoint migrations and history compaction: the new manifest
   format, replacement-closure validation, per-backend catalog equivalence,
   fresh bootstrap selection, historical adoption, durable tombstones, and
   confirmed finalization.
9. Generate runtime migration bundles and add the unified build-integrated CLI,
   sharing the planner and runners between runtime and host commands.
10. Complete hardening: resource limits, build invalidation, differential and
   fuzz tests, platform coverage, telemetry/security, and performance baselines.
11. Reconcile all normative documentation and tracked divergences, run every
    public example and compatibility fixture, and enforce the 0.1 release gate.

| Phase | Work item | Status |
| --- | --- | --- |
| Acceptance | Independently runnable, test-reused real-world examples | Complete |
| Acceptance | Red test checkpoint before implementation | Complete |
| Runtime | Backend-neutral query contracts and owned-value helpers | Complete |
| Runtime | SQLite connections, cardinalities, rows, errors, and transactions | Complete |
| Runtime | Application-supplied `std.Io` at connection initialization | Complete |
| Runtime | Compatibility coverage for third-party `std.Io` runtimes (zio) | Complete |
| Boundaries | Host pipeline verified runtime-agnostic on a non-std `std.Io` | Complete |
| Boundaries | Core-only target without database driver or parser linkage | Complete |
| Boundaries | Host parser separated from SQLite runtime | Complete |
| Configuration | Pin and use Ziggy for strict project configuration | Complete |
| Parser | Pin and compile `libpg_query` from source | Complete |
| Parser | Traverse the typed protobuf-C AST directly, without JSON | Complete |
| Parser | Portable named parameters and original-source diagnostic mapping | Complete |
| Catalog | Replay common tables, columns, keys, indexes, ALTER, and DROP | Complete |
| Migrations | Validate revision IDs, graph shape, and deterministic ordering | Complete |
| Migrations | Parse manifests and discover revision inputs | Complete |
| Migrations | Discover and validate common, SQLite, and PostgreSQL upgrade/downgrade SQL | Complete |
| Catalog | Deterministic, atomic common + SQLite migration replay | Complete |
| Catalog | Deterministic, atomic common + PostgreSQL migration replay | Complete |
| Catalog | Reject divergent migration merge-parent catalogs | Complete |
| Catalog | PostgreSQL schema-qualified objects and configured `search_path` resolution | Complete |
| Catalog | PostgreSQL enum/domain replay, enum extension, and custom-type drops | Complete |
| Catalog | Remaining SQLite 0.1 DDL objects and constraints | Complete |
| Parser | SQLite-only syntax validation and capability gates | Complete |
| Checker | Adapt statements, relations, parameters, and result names into IR | Complete |
| Checker | Column-reference expression IR with aliases and outer-join facts | Complete |
| Checker | Resolve projected columns, scalar types, and nullability | Complete |
| Checker | Infer parameters from comparisons, writes, and pagination | Complete |
| Checker | Infer literals, common functions, arithmetic, casts, and scalar subqueries | Complete |
| Checker | Resolve recursive CTE output shapes used by the samples | Complete |
| Checker | General set-operation typing and conflicting constraints | Complete |
| Inputs | Parse and deterministically discover named `.sql` files | Complete |
| Inputs | Discover and validate embedded Zig declarations | Complete |
| Inputs | Verify declared `.params`/`.row` structs and codec maps against the SQL | Complete |
| Build | Register discovered project inputs so edits and additions re-check | Complete |
| Generator | Deterministic, Zig-AST-validated binding source emission | Complete |
| Generator | Deterministic root/path namespace assembly | Complete |
| Generator | Build-cache module integration | Complete |
| Generator | PostgreSQL-only and portable shared-text query generation with contract comparison | Complete |
| Generator | Disjoint SQLite/PostgreSQL query variants with static executor dispatch | Complete |
| Generator | Backend SQL and ordered parameter-name metadata | Complete |
| Checker | PostgreSQL domain base-scalar inference and exact custom-type codec matching | Complete |
| Checker | PostgreSQL one-dimensional array inference and multidimensional rejection | Complete |
| Generator | Borrowed array contracts with nullable element and array nullability metadata | Complete |
| Runtime | Recursive owned cloning/deinitialization for array-shaped rows | Complete |
| Runtime | PostgreSQL owned/borrowed connections, scalar execution, rows, and transactions | Complete |
| Runtime | PostgreSQL native pool wrapper, pooled executor methods, and dirty-connection replacement | Complete |
| Runtime | PostgreSQL one-dimensional array binding/decoding for built-ins and derived enums | Complete |
| Build | Lazy SQLite/PostgreSQL runtime facade and TLS flag validation | Complete |
| Build | Core, SQLite, PostgreSQL, both-backend, and PostgreSQL-TLS compile matrix | Complete |
| Diagnostics | Stable diagnostic transport, human/JSON rendering, and codegen exit/output contract | Complete |
| Diagnostics | Parser original-source spans and labels | Complete |
| Diagnostics | Deterministic query-file error accumulation and configured cap | Complete |
| Diagnostics | Manifest/graph/catalog/query semantic labels and suggested fixes | Not started |
| Acceptance | Live PostgreSQL CRUD, rows, owned values, transactions, arrays, enums/domains, pools, and version checks | Complete |
| Acceptance | Hosted live PostgreSQL 15–18 conformance matrix | Complete |
| Acceptance | Certificate-backed PostgreSQL TLS and cancellation conformance | Not started |
| Runtime | Native enums at the parameter and row boundary | Complete |
| Runtime | Connection-scoped owned rows and streaming owned conversion | Complete |
| Runtime | Typed connection options and the native pool wrapper | Complete |
| Codecs | Registered codec IDs resolved into generated bindings | Complete |
| Runtime | Unchecked scripts, transaction behavior, and scalar widening so applications need no driver handle | Complete |
| Acceptance | Convert examples to generated checked bindings | Complete |
| Acceptance | Example runs all four cardinalities through generated and embedded queries (M3 gate) | Complete |
| Acceptance | Every example query checks offline against both SQLite and PostgreSQL catalogs | Complete |
| Hardening | Complete remaining diagnostics, resource limits, and dependency matrix | Not started |
| Deferred | PostgreSQL runtime backend | Deferred |
| Deferred | PostgreSQL builtin catalog signatures and remaining live-engine conformance | Deferred |
| Deferred | Migration execution and full CLI | Deferred |
| Deferred | Checkpoint migrations and history compaction | Deferred |
| Deferred | Checkpoint manifest v2 and compacted-history registry format | Deferred |
| Deferred | Checkpoint equivalence, selection, adoption, and finalization workflows | Deferred |

## Tracked divergences

These are places where the normative documents promise more than the code
currently does. They are listed so the gap stays deliberate rather than becoming
an undocumented rule, per [README.md](README.md).

| Promise | Document | State |
| --- | --- | --- |
| Diagnostics with stable codes, source spans, labels, and JSON rendering | [sql-checker.md](sql-checker.md) | transport/rendering and process contracts exist; most checker components still return Zig errors without real spans or accumulation |
| Named `Row` and `OwnedRow` types per row-returning query | [sql-checker.md](sql-checker.md) | generated bindings carry an anonymous `.row` struct; the runtime supplies `Single(Row)`/`Owned(Row)` |
| General codec interface: `Binder`/`Decoder`, `borrows_result`, ownership hooks | [query-api.md](query-api.md) | only enum codecs are derived; `sqlz.assertCodec` rejects any other declaration |
| `sqlz.Uuid` built-in mapping | [query-api.md](query-api.md) | not implemented |
| Storage-class validation for non-STRICT SQLite | [type-system.md](type-system.md) | decoding range-checks integers; storage class is unchecked |
| Rollback failure poisons and discards the connection | [runtime.md](runtime.md) | the rollback result is currently ignored |
| Telemetry callbacks for lifecycle events | [errors-and-observability.md](errors-and-observability.md) | not implemented |
| Resource limits beyond `source_bytes` | [configuration.md](configuration.md) | declared and validated, not yet enforced |
| Automated build-input invalidation test | [testing.md](testing.md) | inputs are registered and verified by hand; no test yet |
| Generated metadata for embedded declarations, and a versioned cache-metadata file | [sql-checker.md](sql-checker.md) | embedded declarations run their own SQL, which SQLite accepts with named parameters; PostgreSQL will need the metadata |
| Detailed PostgreSQL SQLSTATE payloads on every query failure | [errors-and-observability.md](errors-and-observability.md) | the pinned pg.zig recovery path clears some server payloads before the wrapper can copy them; safe owned errors remain available |
