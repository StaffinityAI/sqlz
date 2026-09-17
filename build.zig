const std = @import("std");
const sqlz_build = @import("build/sqlz_build.zig");

pub const addTool = sqlz_build.addTool;
pub const Tool = sqlz_build.Tool;
pub const ToolOptions = sqlz_build.ToolOptions;
pub const Project = sqlz_build.Project;
pub const ProjectOptions = sqlz_build.ProjectOptions;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const host_target = b.graph.host;
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("sqlz_build", .{ .root_source_file = b.path("build/sqlz_build.zig") });

    const core_mod = b.addModule("sqlz_core", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ziggy_dep = b.dependency("ziggy", .{
        .target = host_target,
        .optimize = optimize,
    });
    const config_mod = b.addModule("sqlz_config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = host_target,
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
        .target = host_target,
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
        .root_source_file = b.path("src/libpg_query_wrapper.h"),
        .target = host_target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_pg_query.addIncludePath(libpg_query_root);
    translate_pg_query.addIncludePath(libpg_query_root.path(b, "vendor"));
    const pg_query_bindings = translate_pg_query.createModule();
    const parser_mod = b.addModule("sqlz_parser", .{
        .root_source_file = b.path("src/parser.zig"),
        .target = host_target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "libpg_query", .module = pg_query_bindings },
        },
    });
    parser_mod.linkLibrary(libpg_query);
    const catalog_mod = b.addModule("sqlz_catalog", .{
        .root_source_file = b.path("src/catalog.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sqlz_parser", .module = parser_mod }},
    });
    const migrations_mod = b.addModule("sqlz_migrations", .{
        .root_source_file = b.path("src/migrations.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggy", .module = ziggy_dep.module("ziggy") }},
    });
    const ir_mod = b.addModule("sqlz_ir", .{
        .root_source_file = b.path("src/ir.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "libpg_query", .module = pg_query_bindings }},
    });
    const analysis_mod = b.addModule("sqlz_analysis", .{
        .root_source_file = b.path("src/analysis.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlz_ir", .module = ir_mod },
            .{ .name = "sqlz_catalog", .module = catalog_mod },
        },
    });
    const query_files_mod = b.addModule("sqlz_query_files", .{
        .root_source_file = b.path("src/query_files.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const zig_queries_mod = b.addModule("sqlz_zig_queries", .{
        .root_source_file = b.path("src/zig_queries.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sqlz_query_files", .module = query_files_mod }},
    });
    const checker_mod = b.addModule("sqlz_checker", .{
        .root_source_file = b.path("src/checker.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlz_parser", .module = parser_mod },
            .{ .name = "sqlz_catalog", .module = catalog_mod },
            .{ .name = "sqlz_migrations", .module = migrations_mod },
            .{ .name = "sqlz_ir", .module = ir_mod },
            .{ .name = "sqlz_analysis", .module = analysis_mod },
            .{ .name = "sqlz_query_files", .module = query_files_mod },
        },
    });
    const generator_mod = b.addModule("sqlz_generator", .{
        .root_source_file = b.path("src/generator.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlz_checker", .module = checker_mod },
            .{ .name = "sqlz_analysis", .module = analysis_mod },
            .{ .name = "sqlz_query_files", .module = query_files_mod },
        },
    });
    const codegen_mod = b.addModule("sqlz_codegen", .{
        .root_source_file = b.path("src/codegen.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggy", .module = ziggy_dep.module("ziggy") },
            .{ .name = "sqlz_config", .module = config_mod },
            .{ .name = "sqlz_migrations", .module = migrations_mod },
            .{ .name = "sqlz_query_files", .module = query_files_mod },
            .{ .name = "sqlz_zig_queries", .module = zig_queries_mod },
            .{ .name = "sqlz_checker", .module = checker_mod },
            .{ .name = "sqlz_analysis", .module = analysis_mod },
            .{ .name = "sqlz_generator", .module = generator_mod },
        },
    });
    const codegen_exe = b.addExecutable(.{
        .name = "sqlz-codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/codegen_main.zig"),
            .target = host_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sqlz_codegen", .module = codegen_mod }},
        }),
    });
    b.installArtifact(codegen_exe);

    const zqlite_dep = b.lazyDependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });
    // zio is an alternative `std.Io` implementation. sqlz never depends on it;
    // it is pulled in only to prove the runtime initialization works with a
    // non-std implementation of the interface.
    const zio_dep = b.lazyDependency("zio", .{
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
            .target = host_target,
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
            .target = host_target,
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

    const zig_query_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/zig_queries.zig"),
            .target = host_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sqlz_zig_queries", .module = zig_queries_mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(zig_query_tests).step);

    const catalog_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/catalog.zig"),
            .target = host_target,
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
            .target = host_target,
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
            .target = host_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sqlz_checker", .module = checker_mod },
                .{ .name = "sqlz_catalog", .module = catalog_mod },
                .{ .name = "sqlz_migrations", .module = migrations_mod },
                .{ .name = "sqlz_query_files", .module = query_files_mod },
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
            .target = host_target,
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

    const analysis_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/analysis.zig"),
            .target = host_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sqlz_analysis", .module = analysis_mod },
                .{ .name = "sqlz_ir", .module = ir_mod },
                .{ .name = "sqlz_parser", .module = parser_mod },
                .{ .name = "sqlz_catalog", .module = catalog_mod },
            },
        }),
    });
    const run_analysis = b.addRunArtifact(analysis_tests);
    test_step.dependOn(&run_analysis.step);
    const analysis_step = b.step("test-analysis", "Run query semantic analysis tests");
    analysis_step.dependOn(&run_analysis.step);

    const query_file_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/query_files.zig"),
            .target = host_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sqlz_query_files", .module = query_files_mod }},
        }),
    });
    const run_query_files = b.addRunArtifact(query_file_tests);
    test_step.dependOn(&run_query_files.step);
    const query_files_step = b.step("test-query-files", "Run named SQL discovery tests");
    query_files_step.dependOn(&run_query_files.step);

    const generator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generator.zig"),
            .target = host_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sqlz_generator", .module = generator_mod },
                .{ .name = "sqlz_checker", .module = checker_mod },
                .{ .name = "sqlz_catalog", .module = catalog_mod },
                .{ .name = "sqlz_query_files", .module = query_files_mod },
            },
        }),
    });
    const run_generator = b.addRunArtifact(generator_tests);
    test_step.dependOn(&run_generator.step);
    const generator_step = b.step("test-generator", "Run checked binding generator tests");
    generator_step.dependOn(&run_generator.step);

    const run_codegen = b.addRunArtifact(codegen_exe);
    run_codegen.addFileArg(b.path("test/fixtures/codegen/sqlz.ziggy"));
    const generated_queries = run_codegen.addOutputFileArg("fixture_queries.zig");
    _ = try run_codegen.step.addDirectoryWatchInput(b.path("test/fixtures/codegen"));
    const generated_module = b.createModule(.{
        .root_source_file = generated_queries,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sqlz", .module = sqlz_mod }},
    });
    const generated_module_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/generated_module.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "queries", .module = generated_module }},
        }),
    });
    const run_generated_module = b.addRunArtifact(generated_module_tests);
    test_step.dependOn(&run_generated_module.step);

    if (zio_dep) |zio| {
        // The host pipeline reads every input through the caller's `std.Io`;
        // prove that half is runtime-agnostic too, not just the connections.
        const zio_host_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/zio_host.zig"),
                .target = host_target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "sqlz_codegen", .module = codegen_mod },
                    .{ .name = "zio", .module = zio.module("zio") },
                },
            }),
        });
        const run_zio_host = b.addRunArtifact(zio_host_tests);
        run_zio_host.setCwd(b.path("."));
        _ = try run_zio_host.step.addDirectoryWatchInput(b.path("test/fixtures/codegen"));
        test_step.dependOn(&run_zio_host.step);
        const zio_host_step = b.step("test-zio-host", "Run the zio host-pipeline tests");
        zio_host_step.dependOn(&run_zio_host.step);
    }

    // `--summary failures` keeps the nested build quiet on success; a failing
    // fixture still prints its own step tree.
    const build_api_test = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--summary", "failures" });
    build_api_test.setCwd(b.path("test/fixtures/build_api"));
    test_step.dependOn(&build_api_test.step);
    const build_api_step = b.step("test-build-api", "Run the external build integration fixture");
    build_api_step.dependOn(&build_api_test.step);

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
        const sqlite_step = b.step("test-sqlite", "Run the SQLite runtime tests");
        sqlite_step.dependOn(&run_sqlite.step);

        if (zio_dep) |zio| {
            const zio_tests = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/zio.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "sqlz", .module = sqlz_mod },
                        .{ .name = "zio", .module = zio.module("zio") },
                    },
                }),
            });
            const run_zio = b.addRunArtifact(zio_tests);
            test_step.dependOn(&run_zio.step);
            const zio_step = b.step("test-zio", "Run the zio std.Io compatibility tests");
            zio_step.dependOn(&run_zio.step);
        } else {
            test_step.dependOn(&b.addFail("zio is required for the complete test suite").step);
        }

        const support_mod = b.createModule(.{
            .root_source_file = b.path("examples/support.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sqlz", .module = sqlz_mod }},
        });

        // The examples are one checked sqlz project: their SQL lives in
        // `examples/queries`, their schema in `examples/migrations`, and the
        // bindings below are generated from both at build time.
        const example_types_mod = b.createModule(.{
            .root_source_file = b.path("examples/types.zig"),
            .target = target,
            .optimize = optimize,
        });
        const run_example_codegen = b.addRunArtifact(codegen_exe);
        run_example_codegen.setName("check sqlz example project");
        run_example_codegen.addFileArg(b.path("examples/sqlz.ziggy"));
        const example_queries_path = run_example_codegen.addOutputFileArg("example_queries.zig");
        run_example_codegen.addArgs(&.{ "--codec", "tier", "sqlz_codec_tier", "Tier" });
        _ = try run_example_codegen.step.addDirectoryWatchInput(b.path("examples"));
        const example_queries_mod = b.createModule(.{
            .root_source_file = example_queries_path,
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sqlz", .module = sqlz_mod },
                .{ .name = "sqlz_codec_tier", .module = example_types_mod },
            },
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
            "enum_roles",
            "arena_rows",
            "pooled_reads",
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
                    .{ .name = "queries", .module = example_queries_mod },
                    .{ .name = "types", .module = example_types_mod },
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
