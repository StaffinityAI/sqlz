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
    const root_build = b.pkg_hash.len == 0;
    const sqlite_enabled = b.option(bool, "sqlite", "Enable the SQLite runtime adapter") orelse root_build;
    const postgres_enabled = b.option(bool, "postgres", "Enable the PostgreSQL runtime adapter") orelse root_build;
    const postgres_tls = b.option(bool, "postgres_tls", "Enable TLS in the PostgreSQL driver") orelse false;
    sqlz_build.validateRuntimeOptions(.{
        .sqlite = sqlite_enabled,
        .postgres = postgres_enabled,
        .postgres_tls = postgres_tls,
    }) catch {
        std.log.err("-Dpostgres_tls=true requires -Dpostgres=true", .{});
        b.invalid_user_input = true;
    };

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
    const diagnostics_mod = b.addModule("sqlz_diagnostics", .{
        .root_source_file = b.path("src/diagnostics.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const sqlite_mod = b.createModule(.{
        .root_source_file = b.path("src/sqlz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sqlz_core", .module = core_mod }},
    });
    const runtime_options = b.addOptions();
    runtime_options.addOption(bool, "sqlite", sqlite_enabled);
    runtime_options.addOption(bool, "postgres", postgres_enabled);
    const sqlz_mod = b.addModule("sqlz", .{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sqlz_core", .module = core_mod }},
    });
    sqlz_mod.addOptions("sqlz_runtime_options", runtime_options);
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
            .{ .name = "sqlz_diagnostics", .module = diagnostics_mod },
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
            .{ .name = "sqlz_diagnostics", .module = diagnostics_mod },
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
    const bootstrap_mod = b.addModule("sqlz_bootstrap", .{
        .root_source_file = b.path("src/bootstrap.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlz_analysis", .module = analysis_mod },
            .{ .name = "sqlz_catalog", .module = catalog_mod },
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
            .{ .name = "sqlz_catalog", .module = catalog_mod },
            .{ .name = "sqlz_diagnostics", .module = diagnostics_mod },
        },
    });
    const codegen_exe = b.addExecutable(.{
        .name = "sqlz-codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/codegen_main.zig"),
            .target = host_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sqlz_codegen", .module = codegen_mod },
                .{ .name = "sqlz_diagnostics", .module = diagnostics_mod },
            },
        }),
    });
    b.installArtifact(codegen_exe);

    const cli_options = b.addOptions();
    cli_options.addOption(bool, "bootstrap_enabled", sqlite_enabled and postgres_enabled);
    const cli_imports: []const std.Build.Module.Import = if (sqlite_enabled and postgres_enabled) imports: {
        const host_zqlite = b.lazyDependency("zqlite", .{
            .target = host_target,
            .optimize = optimize,
        }) orelse break :imports &.{};
        const host_pg = b.lazyDependency("pg", .{
            .target = host_target,
            .optimize = optimize,
            .openssl = postgres_tls,
        }) orelse break :imports &.{};
        const bootstrap_cli_mod = b.createModule(.{
            .root_source_file = b.path("src/bootstrap_cli.zig"),
            .target = host_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ziggy", .module = ziggy_dep.module("ziggy") },
                .{ .name = "sqlz_analysis", .module = analysis_mod },
                .{ .name = "sqlz_bootstrap", .module = bootstrap_mod },
                .{ .name = "sqlz_catalog", .module = catalog_mod },
                .{ .name = "sqlz_checker", .module = checker_mod },
                .{ .name = "sqlz_config", .module = config_mod },
                .{ .name = "sqlz_migrations", .module = migrations_mod },
                .{ .name = "pg", .module = host_pg.module("pg") },
                .{ .name = "zqlite", .module = host_zqlite.module("zqlite") },
            },
        });
        break :imports &.{std.Build.Module.Import{ .name = "sqlz_bootstrap_cli", .module = bootstrap_cli_mod }};
    } else &.{};
    const cli_root = b.createModule(.{
        .root_source_file = b.path("src/cli_main.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = cli_imports,
    });
    cli_root.addOptions("sqlz_cli_options", cli_options);
    const cli_exe = b.addExecutable(.{ .name = "sqlz-cli", .root_module = cli_root });
    b.installArtifact(cli_exe);

    const zqlite_dep = if (sqlite_enabled) b.lazyDependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    const pg_dep = if (postgres_enabled) b.lazyDependency("pg", .{
        .target = target,
        .optimize = optimize,
        .openssl = postgres_tls,
    }) else null;
    // zio is an alternative `std.Io` implementation. sqlz never depends on it;
    // it is pulled in only to prove the runtime initialization works with a
    // non-std implementation of the interface.
    const zio_dep = b.lazyDependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run the complete sqlz test suite");
    const offline_step = b.step("test-offline", "Run quick tests that need no database or network service");
    const integration_step = b.step("test-integration", "Run SQLite and live PostgreSQL integration tests");
    const postgres_test_host = b.option([]const u8, "postgres_test_host", "Live PostgreSQL test host") orelse "127.0.0.1";
    const postgres_test_port = b.option(u16, "postgres_test_port", "Live PostgreSQL test port") orelse 55432;
    const postgres_test_database = b.option([]const u8, "postgres_test_database", "Live PostgreSQL test database") orelse "sqlz_test";
    const postgres_test_username = b.option([]const u8, "postgres_test_username", "Live PostgreSQL test username") orelse "sqlz_test";
    const postgres_test_password = b.option([]const u8, "postgres_test_password", "Live PostgreSQL test password") orelse "sqlz_test";
    const postgres_test_major = b.option(u16, "postgres_test_major", "Expected live PostgreSQL major") orelse 18;

    const postgres_config_mod = b.createModule(.{
        .root_source_file = b.path("test/support/postgres_config.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const postgres_config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/postgres_config.zig"),
            .target = host_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "postgres_config", .module = postgres_config_mod }},
        }),
    });
    const run_postgres_config = b.addRunArtifact(postgres_config_tests);
    test_step.dependOn(&run_postgres_config.step);
    offline_step.dependOn(&run_postgres_config.step);

    const diagnostics_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/diagnostics.zig"),
            .target = host_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sqlz_diagnostics", .module = diagnostics_mod }},
        }),
    });
    const run_diagnostics = b.addRunArtifact(diagnostics_tests);
    test_step.dependOn(&run_diagnostics.step);
    offline_step.dependOn(&run_diagnostics.step);

    const diagnostics_json = b.addRunArtifact(codegen_exe);
    diagnostics_json.addFileArg(b.path("test/fixtures/diagnostics/invalid.ziggy"));
    _ = diagnostics_json.addOutputFileArg("invalid_queries.zig");
    diagnostics_json.addArgs(&.{ "--format", "json" });
    diagnostics_json.expectExitCode(1);
    diagnostics_json.expectStdOutMatch("\"format_version\":1");
    diagnostics_json.expectStdOutMatch("\"kind\":\"diagnostic\"");
    diagnostics_json.expectStdErrEqual("");
    test_step.dependOn(&diagnostics_json.step);
    offline_step.dependOn(&diagnostics_json.step);

    const diagnostics_accumulated = b.addRunArtifact(codegen_exe);
    diagnostics_accumulated.addFileArg(b.path("test/fixtures/diagnostics/project/sqlz.ziggy"));
    _ = diagnostics_accumulated.addOutputFileArg("accumulated_queries.zig");
    diagnostics_accumulated.addArgs(&.{ "--format", "json" });
    diagnostics_accumulated.expectExitCode(1);
    diagnostics_accumulated.expectStdOutMatch("\"code\":\"C001\"");
    diagnostics_accumulated.expectStdOutMatch("\"path\":\"a.sql\"");
    diagnostics_accumulated.expectStdOutMatch("\"code\":\"S099\"");
    diagnostics_accumulated.expectStdErrEqual("");
    test_step.dependOn(&diagnostics_accumulated.step);
    offline_step.dependOn(&diagnostics_accumulated.step);

    const diagnostics_human = b.addRunArtifact(codegen_exe);
    diagnostics_human.expectExitCode(2);
    diagnostics_human.expectStdOutEqual("");
    diagnostics_human.expectStdErrMatch("error[S001]");
    diagnostics_human.expectStdErrMatch("usage: sqlz-codegen");
    test_step.dependOn(&diagnostics_human.step);
    offline_step.dependOn(&diagnostics_human.step);
    const core_step = b.step("test-core", "Run backend-neutral tests");
    const examples_step = b.step("examples", "Build all examples");

    const bootstrap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bootstrap.zig"),
            .target = host_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sqlz_bootstrap", .module = bootstrap_mod },
                .{ .name = "sqlz_catalog", .module = catalog_mod },
                .{ .name = "sqlz_parser", .module = parser_mod },
            },
        }),
    });
    const run_bootstrap_tests = b.addRunArtifact(bootstrap_tests);
    test_step.dependOn(&run_bootstrap_tests.step);
    offline_step.dependOn(&run_bootstrap_tests.step);
    const bootstrap_step = b.step("test-bootstrap", "Run bootstrap planning tests");
    bootstrap_step.dependOn(&run_bootstrap_tests.step);

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
    offline_step.dependOn(&run_core.step);

    const build_options_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/build_options.zig"),
            .target = host_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sqlz_build", .module = b.modules.get("sqlz_build").? }},
        }),
    });
    const run_build_options = b.addRunArtifact(build_options_tests);
    test_step.dependOn(&run_build_options.step);
    offline_step.dependOn(&run_build_options.step);

    const parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/parser.zig"),
            .target = host_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "sqlz_parser", .module = parser_mod }},
        }),
    });
    parser_tests.root_module.addImport("sqlz_diagnostics", diagnostics_mod);
    const run_parser = b.addRunArtifact(parser_tests);
    test_step.dependOn(&run_parser.step);
    offline_step.dependOn(&run_parser.step);

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
    offline_step.dependOn(&run_config.step);
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
    const run_zig_queries = b.addRunArtifact(zig_query_tests);
    test_step.dependOn(&run_zig_queries.step);
    offline_step.dependOn(&run_zig_queries.step);

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
    offline_step.dependOn(&run_catalog.step);
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
    offline_step.dependOn(&run_migrations.step);
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
                .{ .name = "sqlz_analysis", .module = analysis_mod },
                .{ .name = "sqlz_catalog", .module = catalog_mod },
                .{ .name = "sqlz_migrations", .module = migrations_mod },
                .{ .name = "sqlz_query_files", .module = query_files_mod },
                .{ .name = "sqlz_zig_queries", .module = zig_queries_mod },
            },
        }),
    });
    const run_checker = b.addRunArtifact(checker_tests);
    test_step.dependOn(&run_checker.step);
    offline_step.dependOn(&run_checker.step);
    const checker_step = b.step("test-checker", "Run offline checker pipeline tests");
    checker_step.dependOn(&run_checker.step);

    const codegen_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/codegen.zig"),
            .target = host_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sqlz_codegen", .module = codegen_mod },
                .{ .name = "sqlz_diagnostics", .module = diagnostics_mod },
            },
        }),
    });
    const run_codegen_tests = b.addRunArtifact(codegen_tests);
    test_step.dependOn(&run_codegen_tests.step);
    offline_step.dependOn(&run_codegen_tests.step);
    const codegen_step = b.step("test-codegen", "Run complete host codegen tests");
    codegen_step.dependOn(&run_codegen_tests.step);

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
    offline_step.dependOn(&run_ir.step);
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
    offline_step.dependOn(&run_analysis.step);
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
    offline_step.dependOn(&run_query_files.step);
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
    offline_step.dependOn(&run_generator.step);
    const generator_step = b.step("test-generator", "Run checked binding generator tests");
    generator_step.dependOn(&run_generator.step);

    const run_codegen = b.addRunArtifact(codegen_exe);
    run_codegen.addFileArg(b.path("test/fixtures/codegen/sqlz.ziggy"));
    const generated_queries = run_codegen.addOutputFileArg("fixture_queries.zig");
    _ = try run_codegen.step.addDirectoryWatchInput(b.path("test/fixtures/codegen"));
    sqlz_build.addProjectInputs(b, run_codegen, b.path("test/fixtures/codegen/sqlz.ziggy"));
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
    offline_step.dependOn(&run_generated_module.step);

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
    const build_api_step = b.step("test-build-api", "Run the external build integration fixture");
    const matrix = [_][]const []const u8{
        &.{},
        &.{ "-Dsqlite=true", "-Dpostgres=false" },
        &.{ "-Dsqlite=false", "-Dpostgres=true" },
        &.{ "-Dsqlite=true", "-Dpostgres=true" },
    };
    for (matrix) |flags| {
        const command = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--summary", "failures" });
        command.addArgs(flags);
        command.setCwd(b.path("test/fixtures/build_api"));
        test_step.dependOn(&command.step);
        build_api_step.dependOn(&command.step);
    }
    if (root_build) {
        const tls_matrix = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build",
            "--summary",
            "failures",
            "-Dsqlite=false",
            "-Dpostgres=true",
            "-Dpostgres_tls=true",
            "test-postgres",
        });
        tls_matrix.setCwd(b.path("."));
        build_api_step.dependOn(&tls_matrix.step);
    }

    if (zqlite_dep) |dep| {
        sqlite_mod.addImport("zqlite", dep.module("zqlite"));
        sqlz_mod.addImport("sqlz_sqlite", sqlite_mod);
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
        integration_step.dependOn(&run_sqlite.step);
        const sqlite_step = b.step("test-sqlite", "Run the SQLite runtime tests");
        sqlite_step.dependOn(&run_sqlite.step);

        // Imports `sqlz` and nothing else, so an application feature that still
        // needed the driver handle would fail to compile here.
        const consumer_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/consumer.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "sqlz", .module = sqlz_mod }},
            }),
        });
        const run_consumer = b.addRunArtifact(consumer_tests);
        test_step.dependOn(&run_consumer.step);
        const consumer_step = b.step("test-consumer", "Run the sqlz-only consumer tests");
        consumer_step.dependOn(&run_consumer.step);

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
        sqlz_build.addProjectInputs(b, run_example_codegen, b.path("examples/sqlz.ziggy"));
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
            "embedded_declarations",
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
        example_tests.root_module.addImport("queries", example_queries_mod);
        const run_examples = b.addRunArtifact(example_tests);
        test_step.dependOn(&run_examples.step);
    } else {
        test_step.dependOn(&b.addFail("zqlite is required for the complete test suite").step);
        integration_step.dependOn(&b.addFail("zqlite is required for integration tests").step);
    }

    if (pg_dep) |dep| {
        const postgres_mod = b.addModule("sqlz_postgres", .{
            .root_source_file = b.path("src/postgres.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sqlz_core", .module = core_mod },
                .{ .name = "pg", .module = dep.module("pg") },
            },
        });
        sqlz_mod.addImport("sqlz_postgres", postgres_mod);
        const postgres_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/postgres.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "sqlz", .module = sqlz_mod },
                    .{ .name = "pg", .module = dep.module("pg") },
                },
            }),
        });
        const run_postgres = b.addRunArtifact(postgres_tests);
        test_step.dependOn(&run_postgres.step);
        const postgres_step = b.step("test-postgres", "Run PostgreSQL adapter compile tests");
        postgres_step.dependOn(&run_postgres.step);

        const postgres_integration_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/postgres_integration.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "sqlz", .module = sqlz_mod },
                    .{ .name = "postgres_config", .module = postgres_config_mod },
                },
            }),
        });
        const postgres_integration_options = b.addOptions();
        postgres_integration_options.addOption([]const u8, "host", postgres_test_host);
        postgres_integration_options.addOption(u16, "port", postgres_test_port);
        postgres_integration_options.addOption([]const u8, "database", postgres_test_database);
        postgres_integration_options.addOption([]const u8, "username", postgres_test_username);
        postgres_integration_options.addOption([]const u8, "password", postgres_test_password);
        postgres_integration_options.addOption(u16, "expected_major", postgres_test_major);
        postgres_integration_tests.root_module.addOptions("postgres_test_options", postgres_integration_options);
        const run_postgres_integration = b.addRunArtifact(postgres_integration_tests);
        integration_step.dependOn(&run_postgres_integration.step);
        const postgres_integration_step = b.step("test-postgres-integration", "Run tests against PostgreSQL on localhost:55432");
        postgres_integration_step.dependOn(&run_postgres_integration.step);

        if (zqlite_dep) |sqlite_dep| {
            const bootstrap_integration_options = b.addOptions();
            bootstrap_integration_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
            bootstrap_integration_options.addOption(
                []const u8,
                "fixture_path",
                b.pathFromRoot("test/fixtures/bootstrap"),
            );
            bootstrap_integration_options.addOption(
                []const u8,
                "source_sql_path",
                b.pathFromRoot("test/fixtures/bootstrap/source.sql"),
            );
            const bootstrap_integration_tests = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/bootstrap_integration.zig"),
                    .target = host_target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "pg", .module = dep.module("pg") },
                        .{ .name = "zqlite", .module = sqlite_dep.module("zqlite") },
                    },
                }),
            });
            bootstrap_integration_tests.root_module.addOptions(
                "bootstrap_test_options",
                bootstrap_integration_options,
            );
            const run_bootstrap_integration = b.addRunArtifact(bootstrap_integration_tests);
            run_bootstrap_integration.setCwd(b.path("."));
            integration_step.dependOn(&run_bootstrap_integration.step);
            const bootstrap_integration_step = b.step(
                "test-bootstrap-integration",
                "Run the SQLite-to-PostgreSQL bootstrap integration test",
            );
            bootstrap_integration_step.dependOn(&run_bootstrap_integration.step);
        }
    } else {
        test_step.dependOn(&b.addFail("pg.zig is required for the complete test suite").step);
        integration_step.dependOn(&b.addFail("pg.zig is required for integration tests").step);
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
