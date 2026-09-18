# Implementation plan

This is the live implementation checklist for the first checked-query release.
PostgreSQL runtime support, migration execution, and the full CLI remain outside
this slice.

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
| Runtime | Native enums at the parameter and row boundary | Complete |
| Runtime | Connection-scoped owned rows and streaming owned conversion | Complete |
| Runtime | Typed connection options and the native pool wrapper | Complete |
| Codecs | Registered codec IDs resolved into generated bindings | Complete |
| Runtime | Unchecked scripts, transaction behavior, and scalar widening so applications need no driver handle | Complete |
| Acceptance | Convert examples to generated checked bindings | Complete |
| Acceptance | Example runs all four cardinalities through generated and embedded queries (M3 gate) | Complete |
| Hardening | Complete diagnostics, resource limits, and dependency matrix | Not started |
| Deferred | PostgreSQL runtime backend | Deferred |
| Deferred | PostgreSQL array wire binding/decoding, TLS, builtin catalog signatures, and live-engine conformance | Deferred |
| Deferred | Migration execution and full CLI | Deferred |

## Tracked divergences

These are places where the normative documents promise more than the code
currently does. They are listed so the gap stays deliberate rather than becoming
an undocumented rule, per [README.md](README.md).

| Promise | Document | State |
| --- | --- | --- |
| Diagnostics with stable codes, source spans, labels, and JSON rendering | [sql-checker.md](sql-checker.md) | checker failures are Zig error values today |
| Named `Row` and `OwnedRow` types per row-returning query | [sql-checker.md](sql-checker.md) | generated bindings carry an anonymous `.row` struct; the runtime supplies `Single(Row)`/`Owned(Row)` |
| General codec interface: `Binder`/`Decoder`, `borrows_result`, ownership hooks | [query-api.md](query-api.md) | only enum codecs are derived; `sqlz.assertCodec` rejects any other declaration |
| `sqlz.Uuid` built-in mapping | [query-api.md](query-api.md) | not implemented |
| Storage-class validation for non-STRICT SQLite | [type-system.md](type-system.md) | decoding range-checks integers; storage class is unchecked |
| Rollback failure poisons and discards the connection | [runtime.md](runtime.md) | the rollback result is currently ignored |
| Telemetry callbacks for lifecycle events | [errors-and-observability.md](errors-and-observability.md) | not implemented |
| Resource limits beyond `source_bytes` | [configuration.md](configuration.md) | declared and validated, not yet enforced |
| Automated build-input invalidation test | [testing.md](testing.md) | inputs are registered and verified by hand; no test yet |
| Generated metadata for embedded declarations, and a versioned cache-metadata file | [sql-checker.md](sql-checker.md) | embedded declarations run their own SQL, which SQLite accepts with named parameters; PostgreSQL will need the metadata |

## Current next steps

1. Add opt-in PostgreSQL live-engine conformance tests.
2. Add PostgreSQL array wire binding/decoding and TLS options.
3. Add PostgreSQL builtin catalog signatures.
4. Harden diagnostics, source limits, and the supported dependency matrix.
