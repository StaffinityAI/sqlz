# Security and trust boundaries

sqlz processes repository-controlled SQL/Ziggy/Zig source, database-controlled
metadata and errors, driver connections, and user-supplied CLI paths. None should
be assumed safe merely because checking occurs at build time.

## Threat model

The table names each boundary, what crosses it, and the control that holds it.
Rows whose consumer is not implemented yet fix the rule that consumer must follow.

| Boundary | Threat | Control | Status |
| --- | --- | --- | --- |
| Configured roots | A root path reads files outside the project | Lexical path rules in `config.validate`; canonical containment check in `inputs.Inputs.openRoot` | enforced |
| Symlinks in roots | A file or directory link reaches outside the project, loops, or duplicates sources | File links must resolve inside the project; directory links are never followed; both fail with S022 | enforced |
| Input size and count | Oversized or numerous sources exhaust memory or time | `source_bytes`, `registered_source_bytes`, `revisions`, `queries`, and `diagnostics` limits, checked before buffering; fixed 1 MiB bound for `sqlz.ziggy` | enforced; token and nesting limits in slice 3 |
| Generated cache paths | Generated code lands outside the build cache or collides | Output path is a build-system `addOutputFileArg` in the content-addressed cache; generated names come from validated identifiers | enforced; atomicity in slice 12 |
| Dynamic SQL identifiers | Schema or table names from configuration or catalogs inject SQL | Identifiers are validated or quoted by dialect-aware helpers, never concatenated raw; values are always bound | enforced for search path and bootstrap; required of migration state SQL |
| State ownership | A database is migrated by the wrong project or with forged state | `project_id` identity and checksum checks; state lives in a dedicated schema/table set | slices 15-16 |
| Schema privileges | Migration credentials exceed what deployment needs | Documented minimal privileges; sqlz never requests superuser or trigger disabling | slices 18-19 |
| Destructive commands | Downgrade, stamp, repair, or bootstrap reset destroy data | Explicit confirmation, lock, and identity checks; fail closed on any mismatch | slices 26-27 |
| Secrets | Connection strings or credentials leak into output | Never emitted in diagnostics, journals, telemetry, or JSON | enforced for current transports |
| Journals | Persisted journals leak SQL text, values, or credentials | Journals record only stable codes, revision IDs, and hashes | slice 17 |
| Telemetry | Events leak values or alter query semantics | Disabled by default; safe IDs and codes only; callback failure cannot change results | deferred to 0.2 |

## Source and generated files

Every file the checker reads goes through one input boundary that resolves the
canonical project root, rejects paths and symlinks that leave it, and charges
the read against the configured limits before parsing. Directory symlinks
inside roots are never followed. There is no external-root registration in 0.1,
so no input outside the directory holding `sqlz.ziggy` is ever read. Parser
limits prevent unbounded input, nesting, diagnostics, or project counts. Generated modules are written only to the
build cache using collision-resistant content keys; SQL identifiers are quoted by
dialect-aware helpers, never concatenated from unchecked runtime strings.

Static values use bound parameters. APIs that accept dynamic identifiers or raw
SQL are visibly unsafe/unchecked escape hatches and never claim type safety.

## Databases and migrations

Migration credentials should have only deployment-required privileges. The
dedicated PostgreSQL state schema has separately documentable ownership. Locks,
identity checks, checksums, state-version checks, and confirmations fail closed.
SQL migration files are trusted deployment code; sqlz does not sandbox DDL/DML.

Checkpoint SQL is equally trusted and has a larger blast radius because it is a
fresh-database bootstrap. Selection requires both missing sqlz state and an
explicit empty-destination classification; sqlz never treats an arbitrary
unmanaged schema as empty. Initialized sqlz state tables are allowed only when they
contain no applied history, checkpoint evidence, or incomplete command. Checkpoint
adoption executes no SQL and requires exact
identity, replacement-set, checksum, and catalog fingerprints. Finalization cannot
discover every deployment, so it requires an explicit operator assertion and
confirmation, never automatic age-based pruning.

## Secrets and diagnostics

Connection strings, credentials, SQL text, and parameter values are never emitted
to telemetry. Full backend errors remain available to callers but are documented
as sensitive. Journals persist only stable safe codes/context. JSON diagnostics
redact secrets and keep machine data on stdout with incidental logging on stderr.
Checkpoint journals and tombstones contain revision IDs and hashes but never SQL
text, credentials, or database contents.

Dependencies and builtin catalogs are pinned and reviewed. Release automation
verifies hashes, licenses, format fixtures, and supported-engine conformance.
