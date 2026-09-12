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
| Boundaries | Core-only target without database driver or parser linkage | Complete |
| Boundaries | Host parser separated from SQLite runtime | Complete |
| Configuration | Pin and use Ziggy for strict project configuration | Complete |
| Parser | Pin and compile `libpg_query` from source | Complete |
| Parser | Portable named parameters and original-source diagnostic mapping | Complete |
| Catalog | Replay common tables, columns, keys, indexes, ALTER, and DROP | Complete |
| Migrations | Validate revision IDs, graph shape, and deterministic ordering | Complete |
| Migrations | Parse manifests and discover revision inputs | Complete |
| Catalog | Deterministic, atomic common + SQLite migration replay | Complete |
| Catalog | Remaining SQLite 0.1 DDL objects and constraints | In progress |
| Parser | SQLite-only syntax validation and capability gates | Not started |
| Checker | Adapt statements, relations, parameters, and result names into IR | Complete |
| Checker | Column-reference expression IR with aliases and outer-join facts | Complete |
| Checker | Resolve projected columns, scalar types, and nullability | Complete |
| Checker | Infer parameters from comparisons, writes, and pagination | Complete |
| Checker | Infer non-column expressions, functions, CTEs, and conflicts | In progress |
| Inputs | Discover named `.sql` files and embedded Zig declarations | Not started |
| Generator | Deterministic build-cache Zig binding generation | Not started |
| Acceptance | Convert examples to generated checked bindings | Not started |
| Hardening | Complete diagnostics, resource limits, and dependency matrix | Not started |
| Deferred | PostgreSQL runtime backend | Deferred |
| Deferred | Migration execution and full CLI | Deferred |

## Current next steps

1. Add typed expressions and resolve names/types/nullability for the query families.
2. Complete the remaining SQLite 0.1 DDL subset and dialect gates.
3. Discover named SQL inputs and generate deterministic Zig bindings.
4. Convert the examples to generated bindings.
5. Harden diagnostics, source limits, and the supported dependency matrix.
