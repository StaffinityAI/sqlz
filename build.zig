const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlz_mod = b.addModule("sqlz", .{
        .root_source_file = b.path("src/sqlz.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zqlite_dep = b.lazyDependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run the complete sqlz test suite");
    const core_step = b.step("test-core", "Run backend-neutral tests");
    _ = b.step("examples", "Build all examples");

    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sqlz", .module = sqlz_mod }},
        }),
    });
    const run_core = b.addRunArtifact(core_tests);
    core_step.dependOn(&run_core.step);
    test_step.dependOn(&run_core.step);

    if (zqlite_dep) |dep| {
        sqlz_mod.addImport("zqlite", dep.module("zqlite"));
        const sqlite_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/sqlite.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "sqlz", .module = sqlz_mod },
                    .{ .name = "zqlite", .module = dep.module("zqlite") },
                },
            }),
        });
        const run_sqlite = b.addRunArtifact(sqlite_tests);
        test_step.dependOn(&run_sqlite.step);
    } else {
        test_step.dependOn(&b.addFail("zqlite is required for the complete test suite").step);
    }
}
