const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.addModule("sqlz_core", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ziggy_dep = b.dependency("ziggy", .{
        .target = target,
        .optimize = optimize,
    });
    const config_mod = b.addModule("sqlz_config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggy", .module = ziggy_dep.module("ziggy") }},
    });
    const sqlz_mod = b.addModule("sqlz", .{
        .root_source_file = b.path("src/sqlz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sqlz_core", .module = core_mod }},
    });
    // libpg_query does not ship a Zig manifest. Zig still fetches its pinned
    // source package into zig-pkg; compile those sources for the selected target
    // instead of relying on a platform-specific prebuilt archive.
    const libpg_query_root = b.path("zig-pkg/N-V-__8AABam8AGXKt6JaO4YJhtbE2eALOH3ykvUnCh-FnLG");
    const libpg_query_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    libpg_query_mod.addIncludePath(libpg_query_root);
    libpg_query_mod.addIncludePath(libpg_query_root.path(b, "vendor"));
    libpg_query_mod.addIncludePath(libpg_query_root.path(b, "src/include"));
    libpg_query_mod.addIncludePath(libpg_query_root.path(b, "src/postgres/include"));
    libpg_query_mod.addCSourceFiles(.{
        .root = libpg_query_root,
        .files = try libpgQuerySources(b),
        .flags = &.{
            "-std=gnu99",
            "-fno-strict-aliasing",
            "-fwrapv",
            "-Wno-unused-function",
            "-Wno-unused-value",
            "-Wno-unused-variable",
        },
    });
    const libpg_query = b.addLibrary(.{
        .name = "pg_query",
        .linkage = .static,
        .root_module = libpg_query_mod,
    });
    const translate_pg_query = b.addTranslateC(.{
        .root_source_file = libpg_query_root.path(b, "pg_query.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_pg_query.addIncludePath(libpg_query_root);
    const parser_mod = b.addModule("sqlz_parser", .{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "libpg_query", .module = translate_pg_query.createModule() },
        },
    });
    parser_mod.linkLibrary(libpg_query);
    const catalog_mod = b.addModule("sqlz_catalog", .{
        .root_source_file = b.path("src/catalog.zig"),
        .target = target,
        .optimize = optimize,
    });
    const migrations_mod = b.addModule("sqlz_migrations", .{
        .root_source_file = b.path("src/migrations.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggy", .module = ziggy_dep.module("ziggy") }},
    });
    const checker_mod = b.addModule("sqlz_checker", .{
        .root_source_file = b.path("src/checker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlz_parser", .module = parser_mod },
            .{ .name = "sqlz_catalog", .module = catalog_mod },
            .{ .name = "sqlz_migrations", .module = migrations_mod },
        },
    });
    const ir_mod = b.addModule("sqlz_ir", .{
        .root_source_file = b.path("src/ir.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zqlite_dep = b.lazyDependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run the complete sqlz test suite");
    const core_step = b.step("test-core", "Run backend-neutral tests");
    const examples_step = b.step("examples", "Build all examples");

    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sqlz", .module = core_mod }},
        }),
    });
    const run_core = b.addRunArtifact(core_tests);
    core_step.dependOn(&run_core.step);
    test_step.dependOn(&run_core.step);

    const parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/parser.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "sqlz_parser", .module = parser_mod }},
        }),
    });
    const run_parser = b.addRunArtifact(parser_tests);
    test_step.dependOn(&run_parser.step);

    const config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/config.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sqlz_config", .module = config_mod },
                .{ .name = "ziggy", .module = ziggy_dep.module("ziggy") },
            },
        }),
    });
    const run_config = b.addRunArtifact(config_tests);
    test_step.dependOn(&run_config.step);
    const config_step = b.step("test-config", "Run project configuration tests");
    config_step.dependOn(&run_config.step);

    const catalog_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/catalog.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sqlz_parser", .module = parser_mod },
                .{ .name = "sqlz_catalog", .module = catalog_mod },
            },
        }),
    });
    const run_catalog = b.addRunArtifact(catalog_tests);
    test_step.dependOn(&run_catalog.step);
    const catalog_step = b.step("test-catalog", "Run offline catalog replay tests");
    catalog_step.dependOn(&run_catalog.step);

    const migration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/migrations.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sqlz_migrations", .module = migrations_mod },
                .{ .name = "ziggy", .module = ziggy_dep.module("ziggy") },
            },
        }),
    });
    const run_migrations = b.addRunArtifact(migration_tests);
    test_step.dependOn(&run_migrations.step);
    const migrations_step = b.step("test-migrations", "Run migration graph tests");
    migrations_step.dependOn(&run_migrations.step);

    const checker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/checker.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sqlz_checker", .module = checker_mod },
                .{ .name = "sqlz_catalog", .module = catalog_mod },
                .{ .name = "sqlz_migrations", .module = migrations_mod },
            },
        }),
    });
    const run_checker = b.addRunArtifact(checker_tests);
    test_step.dependOn(&run_checker.step);
    const checker_step = b.step("test-checker", "Run offline checker pipeline tests");
    checker_step.dependOn(&run_checker.step);

    const ir_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/ir.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sqlz_ir", .module = ir_mod },
                .{ .name = "sqlz_parser", .module = parser_mod },
            },
        }),
    });
    const run_ir = b.addRunArtifact(ir_tests);
    test_step.dependOn(&run_ir.step);
    const ir_step = b.step("test-ir", "Run checker IR adapter tests");
    ir_step.dependOn(&run_ir.step);

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

        const support_mod = b.createModule(.{
            .root_source_file = b.path("examples/support.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sqlz", .module = sqlz_mod }},
        });

        const example_names = [_][]const u8{
            "account_crud",
            "preferences_upsert",
            "recursive_roles",
            "nullable_join",
            "transaction_transfer",
            "session_lookup",
            "aggregate_counts",
            "insert_select",
            "paginated_search",
            "delete_cleanup",
        };
        var example_imports: [example_names.len]std.Build.Module.Import = undefined;
        inline for (example_names, 0..) |name, i| {
            const example_mod = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ "/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "sqlz", .module = sqlz_mod },
                    .{ .name = "example_support", .module = support_mod },
                },
            });
            example_imports[i] = .{ .name = name, .module = example_mod };

            const exe = b.addExecutable(.{ .name = "sqlz-" ++ name, .root_module = example_mod });
            examples_step.dependOn(&exe.step);
            const run = b.addRunArtifact(exe);
            const run_step = b.step("run-" ++ name, "Run the " ++ name ++ " example");
            run_step.dependOn(&run.step);
        }

        const example_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/examples.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &example_imports,
            }),
        });
        const run_examples = b.addRunArtifact(example_tests);
        test_step.dependOn(&run_examples.step);
    } else {
        test_step.dependOn(&b.addFail("zqlite is required for the complete test suite").step);
    }
}

fn libpgQuerySources(b: *std.Build) ![]const []const u8 {
    const package = "zig-pkg/N-V-__8AABam8AGXKt6JaO4YJhtbE2eALOH3ykvUnCh-FnLG";
    var files: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "src", "src/postgres" }) |subdir| {
        const path = b.pathJoin(&.{ package, subdir });
        var dir = try std.Io.Dir.cwd().openDir(b.graph.io, path, .{ .iterate = true });
        defer dir.close(b.graph.io);
        var iterator = dir.iterate();
        while (try iterator.next(b.graph.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".c")) continue;
            try files.append(b.allocator, b.pathJoin(&.{ subdir, entry.name }));
        }
    }
    try files.appendSlice(b.allocator, &.{
        "vendor/protobuf-c/protobuf-c.c",
        "vendor/xxhash/xxhash.c",
        "protobuf/pg_query.pb-c.c",
    });
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return files.toOwnedSlice(b.allocator);
}
