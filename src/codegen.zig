const std = @import("std");
const ziggy = @import("ziggy");
const config = @import("sqlz_config");
const migrations = @import("sqlz_migrations");
const query_files = @import("sqlz_query_files");
const zig_queries = @import("sqlz_zig_queries");
const checker = @import("sqlz_checker");
const analysis = @import("sqlz_analysis");
const catalog = @import("sqlz_catalog");
const generator = @import("sqlz_generator");
const diagnostics = @import("sqlz_diagnostics");

pub const Error = error{
    UnboundCodec,
    UnregisteredCodec,
    IncompatibleBackendContract,
    ProjectCheckFailed,
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
    const raw_config = try project_dir.readFileAlloc(io, config_name, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(raw_config);
    const config_source = try allocator.dupeZ(u8, raw_config);
    defer allocator.free(config_source);
    var meta: ziggy.Deserializer.Meta = .init;
    var loaded = try config.parse(allocator, config_source, &meta);
    defer loaded.deinit();
    const project = loaded.config();
    if (diagnostic_list) |list|
        list.setLimit(std.math.cast(usize, project.limits.diagnostics) orelse return error.InvalidLimit);
    const sqlite_dialect: checker.SqliteDialect = if (project.backends.sqlite) |sqlite| .{
        .profile = checker.SqliteProfile.fromString(sqlite.profile) orelse unreachable,
    } else .{};
    const postgres_dialect: checker.PostgresDialect = if (project.backends.postgres) |postgres| .{
        .profile = checker.PostgresProfile.fromString(postgres.profile) orelse unreachable,
    } else .{};
    const source_limit = std.math.cast(usize, project.limits.source_bytes) orelse return error.InvalidLimit;

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

    var migration_dir = try project_dir.openDir(io, project.migrations, .{ .iterate = true });
    defer migration_dir.close(io);
    var migration_discovery = try migrations.discover(allocator, io, migration_dir, source_limit);
    defer migration_discovery.deinit();
    var sqlite_schema: ?catalog.Catalog = if (project.backends.sqlite != null)
        try checker.replayDiscoveredSqliteWithDialect(allocator, &migration_discovery, sqlite_dialect)
    else
        null;
    defer if (sqlite_schema) |*schema| schema.deinit();
    var postgres_schema: ?catalog.Catalog = if (project.backends.postgres != null)
        try checker.replayDiscoveredPostgresWithOptions(allocator, &migration_discovery, .{
            .dialect = postgres_dialect,
            .search_path = project.backends.postgres.?.search_path,
        })
    else
        null;
    defer if (postgres_schema) |*schema| schema.deinit();

    for (project.zig_roots) |zig_root| {
        var zig_dir = try project_dir.openDir(io, zig_root, .{ .iterate = true });
        defer zig_dir.close(io);
        var embedded = try zig_queries.discover(allocator, io, zig_dir, source_limit);
        defer embedded.deinit();
        for (embedded.sources) |*source| {
            // Embedded declarations produce no generated output; checking them
            // is the point — their `.params`/`.row` structs must agree with the
            // SQL they sit next to.
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
                    try list.appendError(err, source.path);
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
        var sql_dir = try project_dir.openDir(io, entry.value_ptr.*, .{ .iterate = true });
        defer sql_dir.close(io);
        var discovery = try query_files.discover(allocator, io, sql_dir, source_limit);
        errdefer discovery.deinit();
        const checked = try allocator.alloc(checker.CheckedQuery, discovery.sources.len);
        var checked_count: usize = 0;
        errdefer {
            for (checked[0..checked_count]) |*item| item.deinit();
            allocator.free(checked);
        }
        const inputs = try allocator.alloc(generator.CheckedInput, discovery.sources.len);
        errdefer allocator.free(inputs);
        for (discovery.sources) |*source| {
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
                    try list.appendError(err, source.path);
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
            for (inputs[0 .. checked_count - 1]) |prior| {
                if (!sameLogicalQuery(prior.source, source)) continue;
                if (prior.source.cardinality != source.cardinality or
                    !contractsEqual(prior.checked, &checked[checked_count - 1]))
                    return error.IncompatibleBackendContract;
            }
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
    return generator.generateProjectModuleWithCodecs(allocator, roots, generator_codecs);
}

fn sameLogicalQuery(left: *const query_files.Source, right: *const query_files.Source) bool {
    if (!std.mem.eql(u8, left.name, right.name)) return false;
    const left_parent = std.fs.path.dirname(left.path) orelse "";
    const right_parent = std.fs.path.dirname(right.path) orelse "";
    return std.mem.eql(u8, left_parent, right_parent);
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
