# Security and trust boundaries

sqlz processes repository-controlled SQL/Ziggy/Zig source, database-controlled
metadata and errors, driver connections, and user-supplied CLI paths. None should
be assumed safe merely because checking occurs at build time.

## Source and generated files

Configuration paths are normalized, bounded by registered roots, and protected
against traversal and symlink surprises. Parser limits prevent unbounded input,
nesting, diagnostics, or project counts. Generated modules are written only to the
build cache using collision-resistant content keys; SQL identifiers are quoted by
dialect-aware helpers, never concatenated from unchecked runtime strings.

Static values use bound parameters. APIs that accept dynamic identifiers or raw
SQL are visibly unsafe/unchecked escape hatches and never claim type safety.

## Databases and migrations

Migration credentials should have only deployment-required privileges. The
dedicated PostgreSQL state schema has separately documentable ownership. Locks,
identity checks, checksums, state-version checks, and confirmations fail closed.
SQL migration files are trusted deployment code; sqlz does not sandbox DDL/DML.

## Secrets and diagnostics

Connection strings, credentials, SQL text, and parameter values are never emitted
to telemetry. Full backend errors remain available to callers but are documented
as sensitive. Journals persist only stable safe codes/context. JSON diagnostics
redact secrets and keep machine data on stdout with incidental logging on stderr.

Dependencies and builtin catalogs are pinned and reviewed. Release automation
verifies hashes, licenses, format fixtures, and supported-engine conformance.
