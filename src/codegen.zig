const std = @import("std");
const config = @import("sqlz_config");
const migrations = @import("sqlz_migrations");
const query_files = @import("sqlz_query_files");
const zig_queries = @import("sqlz_zig_queries");
const checker = @import("sqlz_checker");
const analysis = @import("sqlz_analysis");
const catalog = @import("sqlz_catalog");
const generator = @import("sqlz_generator");
const diagnostics = @import("sqlz_diagnostics");
const sqlz_inputs = @import("sqlz_inputs");

// Configuration bounds `limits.nesting_depth` by what both lexers can track.
comptime {
    std.debug.assert(config.max_nesting_depth == checker.parser.lexer.max_nesting_depth);
    std.debug.assert(config.max_nesting_depth == zig_queries.max_nesting_depth);
}

pub const Error = error{
    UnboundCodec,
    UnregisteredCodec,
    IncompatibleBackendContract,
    RuntimeBackendWithoutProfile,
    ProjectCheckFailed,
};

/// The runtime adapters a build registration enables for one project. Each one
/// needs a checking profile in `sqlz.ziggy`; a backend may be checked without
/// being enabled, never the reverse.
pub const RuntimeBackends = struct {
    sqlite: bool = false,
    postgres: bool = false,
};

pub const GenerateOptions = struct {
    codecs: []const CodecBinding = &.{},
    runtime: RuntimeBackends = .{},
};

/// A codec binding as the build supplies it: the configured ID, plus the Zig
/// module and declaration the generated module should name.
pub const CodecBinding = struct {
    id: []const u8,
    import_name: []const u8,
    declaration: []const u8,
};

const RootState = struct {
    discovery: query_files.Discovery,
    checked: []checker.CheckedQuery,
    checked_count: usize,
    inputs: []generator.CheckedInput,

    fn deinit(self: *RootState, allocator: std.mem.Allocator) void {
        for (self.checked[0..self.checked_count]) |*item| item.deinit();
        allocator.free(self.checked);
        allocator.free(self.inputs);
        self.discovery.deinit();
        self.* = undefined;
    }
};

pub fn generateProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: std.Io.Dir,
    config_name: []const u8,
) ![]u8 {
    return generateProjectWithCodecs(allocator, io, project_dir, config_name, &.{});
}

pub fn generateProjectWithCodecs(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: std.Io.Dir,
    config_name: []const u8,
    bindings: []const CodecBinding,
) ![]u8 {
    return generateProjectWithCodecsAndDiagnostics(
        allocator,
        io,
        project_dir,
        config_name,
        bindings,
        null,
    );
}

pub fn generateProjectWithCodecsAndDiagnostics(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: std.Io.Dir,
    config_name: []const u8,
    bindings: []const CodecBinding,
    diagnostic_list: ?*diagnostics.List,
) ![]u8 {
    return generateProjectWithOptions(
        allocator,
        io,
        project_dir,
        config_name,
        .{ .codecs = bindings },
        diagnostic_list,
    );
}

pub fn generateProjectWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: std.Io.Dir,
    config_name: []const u8,
    options: GenerateOptions,
    diagnostic_list: ?*diagnostics.List,
) ![]u8 {
    var loaded = try config.load(allocator, io, project_dir, config_name);
    defer loaded.deinit();
    const project = loaded.config();
    var project_inputs = try sqlz_inputs.Inputs.init(allocator, io, project_dir, .fromConfig(project.limits));
    defer project_inputs.deinit();
    return generateLoaded(
        allocator,
        &loaded,
        &project_inputs,
        config_name,
        options,
        diagnostic_list,
    ) catch |err| {
        if (diagnostic_list) |list| {
            if (try project_inputs.appendDiagnostic(list, err)) return error.ProjectCheckFailed;
        }
        return err;
    };
}

fn generateLoaded(
    allocator: std.mem.Allocator,
    loaded: *const config.Loaded,
    project_inputs: *sqlz_inputs.Inputs,
    config_name: []const u8,
    options: GenerateOptions,
    diagnostic_list: ?*diagnostics.List,
) ![]u8 {
    const project = loaded.config();
    const bindings = options.codecs;
    if (diagnostic_list) |list|
        list.setLimit(std.math.cast(usize, project.limits.diagnostics) orelse return error.InvalidLimit);
    try project_inputs.register(config_name, loaded.source_len);
    if (options.runtime.sqlite and project.backends.sqlite == null)
        return error.RuntimeBackendWithoutProfile;
    if (options.runtime.postgres and project.backends.postgres == null)
        return error.RuntimeBackendWithoutProfile;
    const limits: checker.parser.Limits = .{
        .tokens = project.limits.tokens_per_source,
        .nesting = project.limits.nesting_depth,
    };
    const sqlite_dialect: checker.SqliteDialect = if (project.backends.sqlite) |sqlite| .{
        .profile = checker.SqliteProfile.fromString(sqlite.profile) orelse unreachable,
        .limits = limits,
    } else .{ .limits = limits };
    const postgres_dialect: checker.PostgresDialect = if (project.backends.postgres) |postgres| .{
        .profile = checker.PostgresProfile.fromString(postgres.profile) orelse unreachable,
        .limits = limits,
    } else .{ .limits = limits };

    // Codec IDs and build bindings are one to one: the Ziggy file owns the
    // database patterns, `build.zig` owns the Zig declaration, and neither side
    // may name a codec the other has not.
    const codec_count = project.codecs.fields.count();
    if (codec_count != bindings.len) {
        if (bindings.len < codec_count) return error.UnboundCodec;
        return error.UnregisteredCodec;
    }
    const codec_infos = try allocator.alloc(checker.CodecInfo, codec_count);
    defer allocator.free(codec_infos);
    const generator_codecs = try allocator.alloc(generator.CodecBinding, codec_count);
    defer allocator.free(generator_codecs);
    var codec_index: usize = 0;
    var codec_entries = project.codecs.fields.iterator();
    while (codec_entries.next()) |entry| : (codec_index += 1) {
        const id = entry.key_ptr.*;
        const binding = findBinding(bindings, id) orelse return error.UnboundCodec;
        var sqlite_type: analysis.ScalarType = .unknown;
        for (entry.value_ptr.sqlite_types) |pattern| {
            const resolved = analysis.scalarType(pattern);
            if (resolved == .unknown) continue;
            if (sqlite_type != .unknown and sqlite_type != resolved) {
                sqlite_type = .unknown;
                break;
            }
            sqlite_type = resolved;
        }
        var postgres_type: analysis.ScalarType = .unknown;
        for (entry.value_ptr.postgres_types) |pattern| {
            const resolved = analysis.scalarType(pattern);
            if (resolved == .unknown) continue;
            if (postgres_type != .unknown and postgres_type != resolved) {
                postgres_type = .unknown;
                break;
            }
            postgres_type = resolved;
        }
        codec_infos[codec_index] = .{
            .id = id,
            .sqlite_type = sqlite_type,
            .postgres_type = postgres_type,
            .postgres_patterns = entry.value_ptr.postgres_types,
        };
        generator_codecs[codec_index] = .{
            .id = id,
            .import_name = binding.import_name,
            .declaration = binding.declaration,
        };
    }

    const io = project_inputs.io;
    var migration_dir = try project_inputs.openRoot(project.migrations);
    defer migration_dir.close(io);
    var migration_discovery = if (diagnostic_list) |list|
        try migrations.discoverWithDiagnostics(allocator, project_inputs, migration_dir, list)
    else
        try migrations.discover(allocator, project_inputs, migration_dir);
    defer migration_discovery.deinit();
    if (diagnostic_list) |list| if (list.slice().len != 0) return error.ProjectCheckFailed;
    try checkMigrationLimits(&migration_discovery, limits, diagnostic_list);
    if (diagnostic_list) |list| if (list.slice().len != 0) return error.ProjectCheckFailed;
    var sqlite_schema: ?catalog.Catalog = if (project.backends.sqlite != null)
        checker.replayDiscoveredSqliteWithDialect(allocator, &migration_discovery, sqlite_dialect) catch |err| {
            if (diagnostic_list) |list| {
                if (try checker.appendCatalogDiagnostic(allocator, err, &migration_discovery, .sqlite, list))
                    return error.ProjectCheckFailed;
            }
            return err;
        }
    else
        null;
    defer if (sqlite_schema) |*schema| schema.deinit();
    var postgres_schema: ?catalog.Catalog = if (project.backends.postgres != null)
        checker.replayDiscoveredPostgresWithOptions(allocator, &migration_discovery, .{
            .dialect = postgres_dialect,
            .search_path = project.backends.postgres.?.search_path,
        }) catch |err| {
            if (diagnostic_list) |list| {
                if (try checker.appendCatalogDiagnostic(allocator, err, &migration_discovery, .postgres, list))
                    return error.ProjectCheckFailed;
            }
            return err;
        }
    else
        null;
    defer if (postgres_schema) |*schema| schema.deinit();

    for (project.zig_roots) |zig_root| {
        var zig_dir = try project_inputs.openRoot(zig_root);
        defer zig_dir.close(io);
        var embedded = try zig_queries.discover(allocator, project_inputs, zig_dir);
        defer embedded.deinit();
        for (embedded.sources) |*source| {
            // Embedded declarations produce no generated output; checking them
            // is the point — their `.params`/`.row` structs must agree with the
            // SQL they sit next to.
            if (diagnostic_list) |list| {
                if (try appendLimitDiagnostic(source, limits, list)) continue;
                if (try appendPostgresSyntaxDiagnostic(allocator, source, limits, list)) continue;
            }
            checkSource(
                allocator,
                sqlite_schema,
                postgres_schema,
                source,
                sqlite_dialect,
                postgres_dialect,
                codec_infos,
                null,
                null,
                null,
            ) catch |err| {
                if (diagnostic_list) |list| {
                    const handled = try appendSourceDiagnostic(
                        allocator,
                        err,
                        if (sqlite_schema) |*schema| schema else null,
                        if (postgres_schema) |*schema| schema else null,
                        source,
                        sqlite_dialect,
                        postgres_dialect,
                        list,
                    );
                    if (!handled) try list.appendError(err, source.path);
                    continue;
                }
                return err;
            };
        }
    }

    const root_count = project.sql_roots.fields.count();
    const states = try allocator.alloc(RootState, root_count);
    var initialized: usize = 0;
    defer {
        for (states[0..initialized]) |*state| state.deinit(allocator);
        allocator.free(states);
    }
    const roots = try allocator.alloc(generator.RootInput, root_count);
    defer allocator.free(roots);

    var iterator = project.sql_roots.fields.iterator();
    while (iterator.next()) |entry| {
        var sql_dir = try project_inputs.openRoot(entry.value_ptr.*);
        defer sql_dir.close(io);
        var discovery = try query_files.discoverAll(allocator, project_inputs, sql_dir);
        errdefer discovery.deinit();
        const checked = try allocator.alloc(checker.CheckedQuery, discovery.sources.len);
        var checked_count: usize = 0;
        errdefer {
            for (checked[0..checked_count]) |*item| item.deinit();
            allocator.free(checked);
        }
        const inputs = try allocator.alloc(generator.CheckedInput, discovery.sources.len);
        errdefer allocator.free(inputs);
        var variants = try query_files.Variants.init(allocator, discovery.sources);
        defer variants.deinit(allocator);
        // The checked input that first represents each logical query; later
        // backend variants must match its contract.
        const first_checked = try allocator.alloc(?usize, discovery.sources.len);
        defer allocator.free(first_checked);
        @memset(first_checked, null);
        for (discovery.sources, 0..) |*source, source_index| {
            if (variants.duplicate[source_index]) |first_index| {
                const list = diagnostic_list orelse return error.DuplicateQueryVariant;
                try appendDuplicateVariantDiagnostic(allocator, &discovery.sources[first_index], source, list);
                continue;
            }
            if (diagnostic_list) |list| {
                if (try appendLimitDiagnostic(source, limits, list)) continue;
                if (try appendPostgresSyntaxDiagnostic(allocator, source, limits, list)) continue;
            }
            var sqlite_sql: ?[]const u8 = null;
            var postgres_sql: ?[]const u8 = null;
            checkSource(
                allocator,
                sqlite_schema,
                postgres_schema,
                source,
                sqlite_dialect,
                postgres_dialect,
                codec_infos,
                &checked[checked_count],
                &sqlite_sql,
                &postgres_sql,
            ) catch |err| {
                if (diagnostic_list) |list| {
                    const handled = try appendSourceDiagnostic(
                        allocator,
                        err,
                        if (sqlite_schema) |*schema| schema else null,
                        if (postgres_schema) |*schema| schema else null,
                        source,
                        sqlite_dialect,
                        postgres_dialect,
                        list,
                    );
                    if (!handled) try list.appendError(err, source.path);
                    continue;
                }
                return err;
            };
            inputs[checked_count] = .{
                .source = source,
                .checked = &checked[checked_count],
                .sqlite_sql = sqlite_sql,
                .postgres_sql = postgres_sql,
            };
            checked_count += 1;
            const group = variants.group[source_index];
            if (first_checked[group]) |prior_index| {
                const prior = inputs[prior_index];
                if (prior.source.cardinality != source.cardinality or
                    !contractsEqual(prior.checked, &checked[checked_count - 1]))
                    return error.IncompatibleBackendContract;
            } else first_checked[group] = checked_count - 1;
        }
        states[initialized] = .{
            .discovery = discovery,
            .checked = checked,
            .checked_count = checked_count,
            .inputs = inputs,
        };
        roots[initialized] = .{ .alias = entry.key_ptr.*, .inputs = inputs[0..checked_count] };
        initialized += 1;
    }
    if (diagnostic_list) |list| if (list.slice().len != 0) return error.ProjectCheckFailed;
    return generator.generateProjectModuleWithOptions(allocator, roots, .{
        .codecs = generator_codecs,
        .project = .{
            .id = project.project_id,
            .sqlite_profile = if (project.backends.sqlite) |sqlite| sqlite.profile else null,
            .postgres_profile = if (project.backends.postgres) |postgres|
                std.fmt.parseInt(u16, postgres.profile, 10) catch unreachable
            else
                null,
            .allow_untested_version = project.allow_untested_version,
            .migration_lock_timeout_ms = project.migration_lock_timeout_ms,
        },
    });
}

fn appendSourceDiagnostic(
    allocator: std.mem.Allocator,
    err: anyerror,
    sqlite_schema: ?*const catalog.Catalog,
    postgres_schema: ?*const catalog.Catalog,
    source: *const query_files.Source,
    sqlite_dialect: checker.SqliteDialect,
    postgres_dialect: checker.PostgresDialect,
    list: *diagnostics.List,
) !bool {
    if (source.backends.sqlite) if (sqlite_schema) |schema| {
        if (try checker.appendSemanticDiagnostic(
            allocator,
            err,
            schema,
            source,
            .sqlite,
            sqlite_dialect,
            postgres_dialect,
            list,
        )) return true;
    };
    if (source.backends.postgres) if (postgres_schema) |schema| {
        if (try checker.appendSemanticDiagnostic(
            allocator,
            err,
            schema,
            source,
            .postgres,
            sqlite_dialect,
            postgres_dialect,
            list,
        )) return true;
    };
    return false;
}

fn appendDuplicateVariantDiagnostic(
    allocator: std.mem.Allocator,
    first: *const query_files.Source,
    duplicate: *const query_files.Source,
    list: *diagnostics.List,
) !void {
    const sqlite = first.backends.sqlite and duplicate.backends.sqlite;
    const postgres = first.backends.postgres and duplicate.backends.postgres;
    const backend = if (sqlite and postgres) "sqlite and postgres" else if (sqlite) "sqlite" else "postgres";
    const message = try std.fmt.allocPrint(
        allocator,
        "query `{s}` is already defined for {s} in this directory",
        .{ duplicate.name, backend },
    );
    defer allocator.free(message);
    try list.appendDiagnostic(.{
        .severity = .err,
        .code = diagnostics.codeForError(error.DuplicateQueryVariant),
        .message = message,
        .primary = nameSpan(duplicate),
        .labels = &.{.{ .span = nameSpan(first), .message = "first defined here" }},
        .help = "rename one of the queries, or give each file disjoint backends to make them variants of one query",
    });
}

fn nameSpan(source: *const query_files.Source) diagnostics.Span {
    const text = source.source_text orelse "";
    return diagnostics.spanAt(source.path, text, source.name_offset, source.name_offset + source.name.len);
}

/// Reports a query whose SQL crosses the token or nesting limit, in every
/// dialect it is checked in, before any parser sees it.
fn appendLimitDiagnostic(
    source: *const query_files.Source,
    limits: checker.parser.Limits,
    list: *diagnostics.List,
) !bool {
    const dialects = [_]struct { bool, checker.parser.lexer.Dialect }{
        .{ source.backends.sqlite, .sqlite },
        .{ source.backends.postgres, .postgres },
    };
    for (dialects) |entry| {
        const selected, const dialect = entry;
        if (!selected) continue;
        const violation = checker.parser.lexer.checkLimits(source.sql, dialect, limits) orelse continue;
        try list.appendDiagnostic(limitDiagnostic(
            violation,
            checker.querySpan(source, violation.start, violation.end - violation.start),
        ));
        return true;
    }
    return false;
}

/// Checks every migration SQL file against the token and nesting limits, in
/// the dialect it is parsed in: common files with the shared PostgreSQL
/// grammar, backend files with their own.
fn checkMigrationLimits(
    discovery: *const migrations.Discovery,
    limits: checker.parser.Limits,
    diagnostic_list: ?*diagnostics.List,
) !void {
    const Dialect = checker.parser.lexer.Dialect;
    for (discovery.revisions) |*revision| {
        const files = [_]struct { []const u8, []const u8, Dialect }{
            .{ "common.up.sql", revision.common_up, .postgres },
            .{ "common.down.sql", revision.common_down, .postgres },
            .{ "sqlite.up.sql", revision.sqlite_up, .sqlite },
            .{ "sqlite.down.sql", revision.sqlite_down, .sqlite },
            .{ "postgres.up.sql", revision.postgres_up, .postgres },
            .{ "postgres.down.sql", revision.postgres_down, .postgres },
        };
        for (files) |file| {
            const name, const text, const dialect = file;
            const violation = checker.parser.lexer.checkLimits(text, dialect, limits) orelse continue;
            const list = diagnostic_list orelse return violation.err();
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ revision.directory, name }) catch
                revision.directory;
            try list.appendDiagnostic(limitDiagnostic(
                violation,
                diagnostics.spanAt(path, text, violation.start, violation.end),
            ));
        }
    }
}

fn limitDiagnostic(violation: checker.parser.lexer.Violation, span: diagnostics.Span) diagnostics.Diagnostic {
    return .{
        .severity = .err,
        .code = diagnostics.codeForError(violation.err()),
        .message = diagnostics.messageForError(violation.err()),
        .primary = span,
        .help = switch (violation.limit) {
            .tokens => "split the source or raise `.limits.tokens_per_source`",
            .nesting => "flatten the expression or raise `.limits.nesting_depth`",
        },
    };
}

fn appendPostgresSyntaxDiagnostic(
    allocator: std.mem.Allocator,
    source: *const query_files.Source,
    limits: checker.parser.Limits,
    list: *diagnostics.List,
) !bool {
    if (!source.backends.postgres) return false;
    const result = try checker.parser.parseDetailedWithLimits(allocator, source.path, source.sql, limits);
    switch (result) {
        .ok => |value| {
            var parsed = value;
            parsed.deinit();
            return false;
        },
        .syntax_error => |value| {
            var diagnostic = value;
            defer diagnostic.deinit();
            // The parser positions errors within the SQL; the file may hold
            // directives before it or Zig string syntax around it.
            var structured = diagnostic.structured();
            const width = diagnostic.original_end - diagnostic.original_offset;
            structured.primary = checker.querySpan(source, diagnostic.original_offset, width);
            try list.appendDiagnostic(structured);
            return true;
        },
    }
}

fn checkSource(
    allocator: std.mem.Allocator,
    sqlite_schema: ?catalog.Catalog,
    postgres_schema: ?catalog.Catalog,
    source: *const query_files.Source,
    sqlite_dialect: checker.SqliteDialect,
    postgres_dialect: checker.PostgresDialect,
    codecs: []const checker.CodecInfo,
    output: ?*checker.CheckedQuery,
    output_sqlite_sql: ?*?[]const u8,
    output_postgres_sql: ?*?[]const u8,
) !void {
    var sqlite_checked: ?checker.CheckedQuery = null;
    defer if (sqlite_checked) |*checked| checked.deinit();
    if (source.backends.sqlite) {
        const schema = sqlite_schema orelse return error.BackendNotSelected;
        sqlite_checked = try checker.checkNamedSqliteWithCodecs(
            allocator,
            &schema,
            source,
            sqlite_dialect,
            codecs,
        );
    }

    var postgres_checked: ?checker.CheckedQuery = null;
    defer if (postgres_checked) |*checked| checked.deinit();
    if (source.backends.postgres) {
        const schema = postgres_schema orelse return error.BackendNotSelected;
        postgres_checked = try checker.checkNamedPostgresWithCodecs(
            allocator,
            &schema,
            source,
            postgres_dialect,
            codecs,
        );
    }

    if (sqlite_checked != null and postgres_checked != null and
        !contractsEqual(&sqlite_checked.?, &postgres_checked.?))
        return error.IncompatibleBackendContract;

    const destination = output orelse return;
    if (sqlite_checked) |checked| {
        destination.* = checked;
        sqlite_checked = null;
        if (output_sqlite_sql) |slot|
            slot.* = try destination.analysis.arena.allocator().dupe(u8, source.sql);
        if (postgres_checked) |*postgres| {
            if (output_postgres_sql) |slot|
                slot.* = try destination.analysis.arena.allocator().dupe(u8, postgres.parsed.rewritten.sql);
        }
    } else if (postgres_checked) |checked| {
        destination.* = checked;
        postgres_checked = null;
        if (output_postgres_sql) |slot| slot.* = destination.parsed.rewritten.sql;
    } else unreachable;
}

fn contractsEqual(left: *const checker.CheckedQuery, right: *const checker.CheckedQuery) bool {
    return valuesEqual(left.analysis.parameters, right.analysis.parameters) and
        valuesEqual(left.analysis.columns, right.analysis.columns);
}

fn valuesEqual(left: []const analysis.ResultColumn, right: []const analysis.ResultColumn) bool {
    if (left.len != right.len) return false;
    for (left, right) |lhs, rhs| {
        if (!std.mem.eql(u8, lhs.name, rhs.name) or lhs.nullable != rhs.nullable) return false;
        if (lhs.array_dimensions != rhs.array_dimensions or
            lhs.element_nullable != rhs.element_nullable) return false;
        if ((lhs.codec == null) != (rhs.codec == null)) return false;
        if (lhs.codec) |codec| {
            if (!std.mem.eql(u8, codec, rhs.codec.?)) return false;
        } else if (lhs.scalar_type != rhs.scalar_type) return false;
    }
    return true;
}

fn findBinding(bindings: []const CodecBinding, id: []const u8) ?CodecBinding {
    for (bindings) |binding| if (std.mem.eql(u8, binding.id, id)) return binding;
    return null;
}
