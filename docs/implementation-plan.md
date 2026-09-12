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
| Catalog | Replay common `CREATE TABLE` columns and constraints | In progress |
| Catalog | Migration discovery, ordering, and complete DDL replay | Not started |
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

1. Extend catalog replay with table constraints, indexes, ALTER TABLE, and DROP.
2. Discover and order migration inputs into the catalog.
3. Introduce a typed query IR over the `libpg_query` tree.
4. Resolve the ten example query families against the reconstructed schema.
5. Generate and compile their Zig bindings from the build cache.
