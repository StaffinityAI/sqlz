# Build-system integration

## Goals

The build integration must:

- keep `zqlite` and `pg.zig` disabled and lazy by default;
- permit either or both in one consuming binary;
- build the checker and generator for the host during cross-compilation;
- expose explicit check and migration steps;
- generate query and migration modules only in Zig-managed cache paths;
- make all source dependencies visible to Zig's build graph;
- avoid requiring database credentials, a live server, or committed generated
  files for normal compilation.

## Package options

The sqlz dependency defines these backend options:

| Option | Default | Effect |
| --- | --- | --- |
| `sqlite` | `false` | enable the `zqlite` runtime adapter |
| `postgres` | `false` | enable the `pg.zig` runtime adapter |
| `sqlite_system` | `false` | ask `zqlite` to link the system SQLite library |
| `postgres_tls` | `false` | enable `pg.zig` OpenSSL/TLS support |

`sqlite_system` is invalid unless `sqlite` is enabled. `postgres_tls` is invalid
unless `postgres` is enabled. Backend-specific low-level options that sqlz later
forwards must use the `sqlite_` or `postgres_` prefix; adding one must not change
the default dependency graph.

The package manifest keeps `zqlite` and `pg` marked `.lazy = true`. `build.zig`
uses `b.lazyDependency` only inside the matching enabled branch. It must not call
`b.dependency`, import a driver build module, translate C headers, or create a
link dependency for a disabled backend.

Valid combinations are:

| `sqlite` | `postgres` | Result |
| --- | --- | --- |
| false | false | checker/core only; no runtime executor |
| true | false | SQLite runtime only |
| false | true | PostgreSQL runtime only |
| true | true | both statically available |

There is no implicit default backend and no runtime `AnyDatabase` selection.

## Published build and runtime API

The dependency's `build.zig` exports helper declarations. A consumer aliases the
build-script import separately from the runtime module:

```zig
const std = @import("std");
const sqlz_build = @import("sqlz");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enabled = .{ .sqlite = true, .postgres = false };
    const sqlz_dep = b.dependency("sqlz", .{
        .target = target,
        .optimize = optimize,
        .sqlite = enabled.sqlite,
        .postgres = enabled.postgres,
    });

    const checked = sqlz_build.addQueries(b, .{
        .dependency = sqlz_dep,
        .name = "app_queries",
        .migrations = b.path("migrations"),
        .sql_roots = &.{b.path("queries")},
        .zig_roots = &.{b.path("src")},
        .runtime_backends = enabled,
    });

    const migrations = sqlz_build.addMigrations(b, .{
        .dependency = sqlz_dep,
        .name = "app_migrations",
        .root = b.path("migrations"),
        .runtime_backends = enabled,
    });

    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sqlz", .module = sqlz_dep.module("sqlz") },
                .{ .name = "sqlz_queries", .module = checked.module },
                .{ .name = "sqlz_migrations", .module = migrations.module },
            },
        }),
    });

    _ = exe;
}
```

The exact exported contracts are:

```zig
pub const Backends = struct {
    sqlite: bool = false,
    postgres: bool = false,
};

pub const CodecRegistration = struct {
    id: []const u8,
    import_name: []const u8,
    module: *std.Build.Module,
    declaration: []const u8,
    sqlite_types: []const []const u8 = &.{},
    postgres_types: []const []const u8 = &.{},
};

pub const QueryOptions = struct {
    dependency: *std.Build.Dependency,
    name: []const u8,
    migrations: std.Build.LazyPath,
    sql_roots: []const std.Build.LazyPath = &.{},
    zig_roots: []const std.Build.LazyPath = &.{},
    catalog_supplements: []const std.Build.LazyPath = &.{},
    codecs: []const CodecRegistration = &.{},
    runtime_backends: Backends = .{},
    migration_head: ?[]const u8 = null,
    warnings_as_errors: bool = false,
};

pub const CheckedQueries = struct {
    module: *std.Build.Module,
    check_step: *std.Build.Step,
};

pub fn addQueries(b: *std.Build, options: QueryOptions) CheckedQueries;

pub const MigrationOptions = struct {
    dependency: *std.Build.Dependency,
    name: []const u8,
    root: std.Build.LazyPath,
    runtime_backends: Backends = .{},
    head: ?[]const u8 = null,
};

pub const EmbeddedMigrations = struct {
    module: *std.Build.Module,
    check_step: *std.Build.Step,
};

pub fn addMigrations(
    b: *std.Build,
    options: MigrationOptions,
) EmbeddedMigrations;

pub fn addMigrateStep(
    b: *std.Build,
    options: MigrationOptions,
) *std.Build.Step;
```

`CodecRegistration` associates a stable codec ID with a public codec declaration
in a module and backend database type patterns. `import_name` must be a valid,
unique Zig import name and `declaration` must be one public identifier; generated
code resolves the codec as `@field(@import(import_name), declaration)`. Type
patterns use canonical catalog names, are compared case-insensitively where the
dialect is case-insensitive, and may end in `*` for an explicitly registered
prefix family. Empty backend patterns mean the codec does not support that
backend. The registration contains no callback executed by the checker.

The runtime module is always named `sqlz`. With backend options enabled it
conditionally exposes `sqlz.sqlite` and/or `sqlz.postgres`. Referencing a
disabled namespace produces a direct compile error saying which dependency
option enables it. The core declarations used by embedded `sqlz.Query` values
remain available with no runtime backend.

## Host tools

The package publishes internal host artifacts for checking/generation and
migration commands. `sqlz_build` obtains them from the supplied dependency; a
consumer does not locate binaries or invoke private paths itself.

During a cross build:

- checker, generator, and migration command artifacts target `b.graph.host`;
- application modules and runtime adapters target the consumer's target;
- generated Zig source is target-independent except for imports selected by the
  runtime backend set;
- no target executable is run on the host.

The checker itself does not depend on either driver. The migration command links
only the enabled backend adapters because it connects to a real database.

## Build steps

### `sqlz-check`

The first `addQueries` or `addMigrations` call creates the top-level
`sqlz-check` step. Later calls add their `check_step` as dependencies of the same
aggregate. Running:

```text
zig build sqlz-check
```

validates every registered migration set and query set and produces cached
generated modules.

Each generated module's compile step depends on its checker/generator run, so an
application importing a named-SQL module cannot compile stale generated output.
Application and library test steps must additionally depend on the relevant
`check_step`; examples in sqlz documentation always show that edge. Unrelated
targets that import neither a generated module nor an embedded query registry do
not run the checker.

Embedded Zig queries produce no source binding for their handwritten API, so
their containing test/check step must depend explicitly on `check_step`. This is
why `CheckedQueries` exposes the step even when `module` contains only generated
verification metadata.

### `sqlz-migrate`

`addMigrateStep` creates or contributes to the top-level `sqlz-migrate` step:

```text
zig build sqlz-migrate -- status --backend sqlite --database app.db
zig build sqlz-migrate -- upgrade head --backend postgres
```

Only one migration root may contribute to this command in 0.1. Registering a
second root is a build configuration error. The command supports only runtime
backends enabled for the dependency; selecting a disabled backend prints an
actionable error and never causes Zig to fetch that driver implicitly.

The step depends on graph and SQL validation before launching the command. CLI
arguments after `--` pass through unchanged. Connection details are runtime
arguments or environment variables and never participate in the normal query-
generation cache key.

### Project tests

The package itself exposes:

- `zig build test`: backend-neutral unit and generated-code tests;
- `zig build test-sqlite`: SQLite adapter and in-memory migration tests;
- `zig build test-postgres`: PostgreSQL tests requiring `SQLZ_DATABASE_URL`;
- `zig build test-integration`: aggregate of enabled backend integration tests;
- `zig build test-build-matrix`: isolated consumer fixtures for all flag
  combinations.

PostgreSQL integration tests skip with an explicit message only when invoked
without `SQLZ_DATABASE_URL`; CI jobs that promise PostgreSQL set
`SQLZ_REQUIRE_POSTGRES=1`, turning absence into failure.

## Generated paths and dependencies

`addQueries` and `addMigrations` use `addRunArtifact` plus declared output files
or directories. They never write into `src/`, `queries/`, `migrations/`, or a
caller-provided tracked directory.

Every registered input path is passed as a build dependency. Directory roots
are accompanied by a deterministic discovered-file manifest so adding, removing,
or renaming a query or migration invalidates the step. The generator writes:

```text
<zig-cache>/.../<name>/queries.zig
<zig-cache>/.../<name>/migrations.zig
<zig-cache>/.../<name>/sqlz-metadata.json
```

These are conceptual locations owned by Zig; consumers must use returned
`LazyPath`/module handles and must not rely on their physical cache paths.

## Backend examples

### Core/checker only

```zig
const sqlz_dep = b.dependency("sqlz", .{
    .target = target,
    .optimize = optimize,
});
```

This supports parser tooling and embedded query declarations but exposes no
executor.

### SQLite only

```zig
const sqlz_dep = b.dependency("sqlz", .{
    .target = target,
    .optimize = optimize,
    .sqlite = true,
});
```

Only `zqlite` is requested. The application opens connections through
`sqlz.sqlite` and does not compile `pg.zig` or its dependencies.

### PostgreSQL only

```zig
const sqlz_dep = b.dependency("sqlz", .{
    .target = target,
    .optimize = optimize,
    .postgres = true,
    .postgres_tls = true,
});
```

Only `pg.zig` and its selected TLS dependencies are requested. No SQLite C
source or headers enter the build.

### Both

```zig
const sqlz_dep = b.dependency("sqlz", .{
    .target = target,
    .optimize = optimize,
    .sqlite = true,
    .postgres = true,
});
```

Both namespaces and generated execution paths are available. Query declarations
still decide whether each query targets one or both backends.

## Build-matrix acceptance tests

Each matrix case uses a minimal external consumer package and a fresh local
cache:

1. Core-only builds the checker and core module while the driver source trees
   are unavailable; success proves neither lazy dependency is required.
2. SQLite-only makes `pg.zig` unavailable, builds and runs a checked in-memory
   query, and inspects link inputs for absence of PostgreSQL/OpenSSL artifacts.
3. PostgreSQL-only makes `zqlite` unavailable, compiles a checked query, and
   inspects compile/link inputs for absence of SQLite C artifacts.
4. Both compiles one portable query and one query unique to each backend in one
   executable.
5. Cross-target builds run the host checker successfully and only compile, never
   execute, target artifacts.
6. Repeated generation with identical inputs produces byte-identical modules;
   a failed generation leaves the prior cache entry untouched but unusable for a
   changed input key.

The test must validate actual dependency acquisition/build behavior, not merely
the absence of a public import.
