# Implementation plan

This is the live implementation checklist for the first checked-query release.
PostgreSQL runtime support, migration execution, and the full CLI remain outside
this slice.

| Phase | Work item | Status |
| --- | --- | --- |
| Acceptance | Ten independently runnable, test-reused real-world examples | Complete |
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
| Catalog | Deterministic, atomic common + SQLite migration replay | Complete |
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
| Runtime | Native enums at the parameter and row boundary | Complete |
| Runtime | Connection-scoped owned rows and streaming owned conversion | Complete |
| Runtime | Typed connection options and the native pool wrapper | Complete |
| Codecs | Registered codec IDs resolved into generated bindings | Complete |
| Runtime | Unchecked scripts, transaction behavior, and scalar widening so applications need no driver handle | Complete |
| Acceptance | Convert examples to generated checked bindings | Complete |
| Hardening | Complete diagnostics, resource limits, and dependency matrix | Not started |
| Deferred | PostgreSQL runtime backend | Deferred |
| Deferred | Migration execution and full CLI | Deferred |

## Current next steps

1. Harden diagnostics, source limits, and the supported dependency matrix.
