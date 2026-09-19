# Compatibility policy

## Toolchain and engines

sqlz 0.1 guarantees exactly Zig 0.16.0. Other Zig releases may work but are not a
compatibility promise. Supported database profiles are SQLite 3.45–3.53 and
PostgreSQL 15–18. Defaults are SQLite 3.53 and PostgreSQL 15 compatibility.

Hosted live conformance runs the PostgreSQL adapter against each supported major.
The local Compose gate uses PostgreSQL 18. TLS-enabled pg.zig builds are compile
checked; live TLS remains a separate evidence requirement and is not yet a 0.1
runtime compatibility claim.

Runtime handles — connections, pools, transactions, and streaming cursors — and
the host pipeline accept any `std.Io` implementation the application supplies;
sqlz depends on the interface, not on a runtime. The test
suite runs against `std.Io.Threaded` throughout, and `zig build test-zio` and
`zig build test-zio-host` repeat runtime and host coverage against
[zio](https://github.com/lalinsky/zio) to keep a third-party implementation
honest. `std.Io.Evented` is not claimed for 0.16.0: on macOS it resolves to
`std.Io.Dispatch`, whose `deinit` does not compile in that release.

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

Checkpoint manifests, replacement metadata, state tombstones, and runtime bundle
metadata are persisted formats. Ordinary format-1 revisions remain valid and keep
their immutable meaning. Checkpoint support uses a newer manifest format rather
than assigning replacement semantics to existing fields. Once a release accepts a
checkpoint manifest or records checkpoint state, later 0.x releases must continue
to read it or perform an explicit state/manifest upgrade. Finalized historical IDs
remain reserved and cannot be reused. The versioned `migrations/history.ziggy`
registry is likewise backward-readable persisted project metadata; deleting or
rewriting entries without an explicit format-aware compaction operation is a
compatibility violation.

Driver and Ziggy revisions are pinned. Updating a pin requires the relevant
conformance, format, runtime, and generated-binding fixtures. Dropping a database
or platform version requires release notes and ordinarily a minor release.

## Platforms

0.1 runs the complete runtime test suite on x86_64 Linux and arm64 macOS. Windows
is compile-check-only and is not a runtime support promise.
