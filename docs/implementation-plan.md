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
| Migrations | Parse manifests and discover revision inputs | Not started |
| Catalog | Ordered, atomic migration replay and remaining 0.1 DDL | In progress |
| Parser | SQLite-only syntax validation and capability gates | Not started |
| Checker | Adapt query AST into checker IR | Not started |
| Checker | Resolve names and infer parameter/result types and nullability | Not started |
| Inputs | Discover named `.sql` files and embedded Zig declarations | Not started |
| Generator | Deterministic build-cache Zig binding generation | Not started |
| Acceptance | Convert examples to generated checked bindings | Not started |
| Hardening | Complete diagnostics, resource limits, and dependency matrix | Not started |
| Deferred | PostgreSQL runtime backend | Deferred |
| Deferred | Migration execution and full CLI | Deferred |

## Current next steps

1. Connect ordered revision inputs to parser-backed catalog replay.
2. Parse strict Ziggy manifests and discover migration directories/files.
3. Complete atomic replay and the remaining SQLite 0.1 DDL subset.
4. Introduce a typed query IR over the `libpg_query` tree.
5. Resolve the ten example query families and generate their Zig bindings.
