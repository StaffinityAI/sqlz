# Build-system integration

The integration keeps zqlite and pg.zig lazy, runs analysis on the host, writes
generated Zig only to the build cache, and supports several sqlz projects in one
build.

## Dependency options

| Option | Default | Effect |
| --- | --- | --- |
| `sqlite` | `false` | fetch/build the zqlite runtime adapter |
| `postgres` | `false` | fetch/build the pg.zig runtime adapter |
| `sqlite_system` | `false` | use system SQLite; requires `sqlite` |
| `postgres_tls` | `false` | enable driver TLS; requires `postgres` |

The package manifest marks both drivers lazy. `build.zig` calls
`b.lazyDependency` only in its enabled branch. A disabled driver is not fetched,
imported, compiled, translated, or linked. Core/checker-only, SQLite-only,
PostgreSQL-only, and both-backend builds are mandatory test configurations. There
is no implicit default backend or runtime `AnyDatabase`.

## Build API

The current Zig 0.16 checked-query contract is:

```zig
const tool = sqlz_build.addTool(b, .{ .dependency = sqlz_dep });
const app_db = tool.addProject(.{
    .name = "app",
    .config = b.path("sqlz.ziggy"),
});

exe.root_module.addImport("sqlz", sqlz_dep.module("sqlz"));
exe.root_module.addImport("app_queries", app_db.queries_module);
exe.step.dependOn(app_db.check_step);
```

The exported shapes are:

```zig
pub const ToolOptions = struct {
    dependency: *std.Build.Dependency,
};

pub const CodecBinding = struct {
    id: []const u8,
    module: *std.Build.Module,
    declaration: []const u8,
};

pub const ProjectOptions = struct {
    name: []const u8,
    config: std.Build.LazyPath,
    codecs: []const CodecBinding = &.{},
};

pub const Project = struct {
    queries_module: *std.Build.Module,
    check_step: *std.Build.Step,
};

pub const Tool = struct {
    pub fn addProject(self: *Tool, options: ProjectOptions) Project;
};

pub fn addTool(b: *std.Build, options: ToolOptions) *Tool;

/// Registers a project's candidate inputs on a run step. `addProject` calls
/// this itself; a build that drives the tool directly calls it explicitly.
pub fn addProjectInputs(
    b: *std.Build,
    run: *std.Build.Step.Run,
    config: std.Build.LazyPath,
) void;
```

## Caching and re-checks

The tool discovers its own inputs, so the configuration file alone does not
describe what the generated module depends on. `addProject` registers every
`.sql`, `.zig`, and `.ziggy` file under the project directory as an input of the
check step, skipping hidden directories, `zig-out`, `zig-cache`, and `zig-pkg`.
Editing a query, adding one, or removing one therefore re-runs the checker;
without those inputs the step would report a cache hit and a drifted query would
keep its previously generated bindings. A configuration supplied as a generated
path cannot be enumerated at configure time and keeps the narrower dependency on
the file itself.

The current SQLite-first slice has this smaller build contract. `addProject`
requires a unique name and returns a generated query module plus its internal
check step. Each codec binding is passed to the checker and added to the
generated module as an import named `sqlz_codec_<id>`; a configured ID without a
binding, or a binding the configuration never declares, fails the check.
Runtime-backend registration and the embedded-migration module will extend these
structures in later phases.

`sqlz.ziggy` owns paths, profile selection, root aliases, supplements, limits,
project identity, and database codec patterns. Build registration owns only Zig
build objects, selected runtime backends, and the strict codec ID to
`{module, declaration}` binding described in [configuration.md](configuration.md).

## Host and target separation

The checker, generator, and CLI target `b.graph.host`. Application modules and
driver adapters target the consumer target. The checker never links a driver.
Commands that connect to a database contain only the runtime adapters enabled for
that project. Cross builds never execute target artifacts on the host.

## Command and compile graph

The public command is:

```text
zig build sqlz -- init
zig build sqlz -- check [--project app]
zig build sqlz -- migrate upgrade head --project app ...
```

See [cli.md](cli.md) for its contract. Generated modules depend on successful
checking, so stale output cannot compile. Targets containing embedded
`sqlz.Query` declarations explicitly depend on the returned `check_step` even if
they import no generated named-query module.

All configuration, migration, SQL, Zig discovery roots, catalogs, and supplements
are registered as build inputs. On Zig 0.16, directory roots use
`std.Build.Step.addDirectoryWatchInput`, while individual lazy paths remain normal
step inputs. Output paths are content-addressed from tool version, all input bytes,
profiles, semantic configuration, and codec IDs. Absolute checkout paths and
credentials never enter keys or generated files.

## Generated modules

The query module mirrors required SQL-root aliases and subdirectories. The
migration module embeds validated manifests and SQL for enabled runtime backends.
Generation is deterministic, uses atomic cache writes, and never edits source
directories. Backend-specific imports appear only when that backend is selected.

## Acceptance tests

Fixtures verify all four backend combinations without network access after normal
dependency provisioning, host tools during cross compilation, watch invalidation
for nested files, multiple project routing, codec binding failures, deterministic
output, and compile failure after a checker error.
