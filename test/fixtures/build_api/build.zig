const std = @import("std");
const sqlz_build = @import("sqlz_build");

pub fn build(b: *std.Build) void {
    const sqlite = b.option(bool, "sqlite", "Enable SQLite") orelse false;
    const postgres = b.option(bool, "postgres", "Enable PostgreSQL") orelse false;
    const postgres_tls = b.option(bool, "postgres_tls", "Enable PostgreSQL TLS") orelse false;
    const sqlz = b.dependency("sqlz_build", .{
        .sqlite = sqlite,
        .postgres = postgres,
        .postgres_tls = postgres_tls,
    });
    const tool = sqlz_build.addTool(b, .{ .dependency = sqlz });
    const types = b.createModule(.{
        .root_source_file = b.path("types.zig"),
        .target = b.graph.host,
    });
    const project = tool.addProject(.{
        .name = "fixture",
        .config = b.path("sqlz.ziggy"),
        .codecs = &.{.{ .id = "tier", .module = types, .declaration = "Tier" }},
    });
    const embedded = b.createModule(.{
        .root_source_file = b.path("src/queries.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "sqlz", .module = sqlz.module("sqlz") },
            .{ .name = "types", .module = types },
        },
    });
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "sqlz", .module = project.runtime_module },
                .{ .name = "queries", .module = project.queries_module },
                .{ .name = "embedded", .module = embedded },
                .{ .name = "types", .module = types },
            },
        }),
    });
    const options = b.addOptions();
    options.addOption(bool, "fixture", true);
    options.addOption(bool, "sqlite", sqlite);
    options.addOption(bool, "postgres", postgres);
    tests.root_module.addOptions("fixture_options", options);
    const run = b.addRunArtifact(tests);
    run.step.dependOn(project.check_step);
    b.default_step.dependOn(&run.step);
}
