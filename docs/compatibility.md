# Compatibility policy

## Toolchain and engines

sqlz 0.1 guarantees exactly Zig 0.16.0. Other Zig releases may work but are not a
compatibility promise. Supported database profiles are SQLite 3.45–3.53 and
PostgreSQL 15–18. Defaults are SQLite 3.53 and PostgreSQL 15 compatibility.

Profiles govern accepted syntax and offline catalogs. Runtime version checks reject
older engines and, by default, versions newer than the tested range. The explicit
`allow_untested_version` setting permits only the newer case with a warning/event.

## APIs and persisted data

Public Zig APIs follow Semantic Versioning. During 0.x, a minor release may change
source APIs with release notes, while patch releases remain compatible. Persisted
configuration, migration manifests, generated query metadata consumed across build
steps, CLI JSON, and database state all carry independent format versions.

Persisted formats written by an earlier 0.x release remain readable by later 0.x
releases through explicit format upgrades. Forward-incompatible newer formats are
rejected, never guessed. Generated Zig is an implementation artifact and need not
be source-compatible or committed.

Driver and Ziggy revisions are pinned. Updating a pin requires the relevant
conformance, format, runtime, and generated-binding fixtures. Dropping a database
or platform version requires release notes and ordinarily a minor release.

## Platforms

0.1 runs the complete runtime test suite on x86_64 Linux and arm64 macOS. Windows
is compile-check-only and is not a runtime support promise.
