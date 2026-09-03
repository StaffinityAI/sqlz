# Architecture decision records

ADRs record why a consequential choice was made. The current design documents in
the parent directory are normative; ADRs are immutable history except for status
and links to a superseding record.

Statuses are Proposed, Accepted, Deprecated, and Superseded. Accepted records may
be replaced only by a new ADR. Records use [0000-template.md](0000-template.md).

## Index

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](0001-sql-toolkit-scope-and-supported-backends.md) | Toolkit scope and supported backends | Accepted |
| [0002](0002-lazy-static-backend-selection.md) | Lazy static backend selection | Accepted |
| [0003](0003-offline-migration-derived-sql-checking.md) | Offline migration-derived checking | Accepted |
| [0004](0004-dual-query-authoring-model.md) | Dual query authoring model | Accepted |
| [0005](0005-portable-named-parameters.md) | Portable named parameters | Accepted |
| [0006](0006-explicit-query-cardinality.md) | Explicit query cardinality | Accepted |
| [0007](0007-query-namespaces-variants-and-generated-rows.md) | Namespaces, variants, and generated rows | Accepted |
| [0008](0008-build-cache-only-generated-bindings.md) | Cache-only generated bindings | Accepted |
| [0009](0009-borrowed-row-views-and-owned-conversion.md) | Borrowed and owned rows | Accepted |
| [0010](0010-sqlz-runtime-wrappers-and-handle-ownership.md) | Runtime wrappers and ownership | Accepted |
| [0011](0011-native-pools-preparation-and-query-controls.md) | Native pools and preparation | Accepted |
| [0012](0012-payload-errors-privacy-and-telemetry.md) | Payload errors, privacy, telemetry | Accepted |
| [0013](0013-transaction-cleanup-and-rollback.md) | Transaction cleanup | Accepted |
| [0014](0014-custom-codecs-and-split-registration.md) | Custom codecs | Accepted |
| [0015](0015-strict-types-sqlite-validation-and-postgres-arrays.md) | Strict typing and arrays | Accepted |
| [0016](0016-database-version-capability-and-namespace-profiles.md) | Database profiles | Accepted |
| [0017](0017-handwritten-parser-scope-and-resource-limits.md) | Parser and limits | Accepted |
| [0018](0018-ziggy-for-versioned-project-metadata.md) | Ziggy metadata | Accepted |
| [0019](0019-builtin-catalogs-supplements-and-polymorphism.md) | Catalog model | Accepted |
| [0020](0020-source-oriented-diagnostics-and-machine-output.md) | Diagnostics and machine output | Accepted |
| [0021](0021-manual-revision-dag-and-migration-file-layout.md) | Revision DAG and files | Accepted |
| [0022](0022-merge-convergence-and-head-only-query-checking.md) | Merge convergence and head checking | Accepted |
| [0023](0023-migration-identity-checksums-and-state-schema.md) | Migration identity and state | Accepted |
| [0024](0024-applied-state-and-operation-journal.md) | Applied state and journal | Accepted |
| [0025](0025-migration-locking-transactions-and-timeouts.md) | Migration locking | Accepted |
| [0026](0026-unified-build-integrated-cli-and-runtime-migrator.md) | Unified CLI and migrator | Accepted |
| [0027](0027-versioned-project-config-and-multi-project-builds.md) | Project config and multiple projects | Accepted |
| [0028](0028-persisted-format-and-api-compatibility.md) | Compatibility | Accepted |
| [0029](0029-supported-platform-and-conformance-matrix.md) | Platform and conformance matrix | Accepted |
| [0030](0030-documentation-authority-adr-governance-and-performance-gates.md) | Documentation governance and performance | Accepted |
