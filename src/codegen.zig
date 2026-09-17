const std = @import("std");
const ziggy = @import("ziggy");
const config = @import("sqlz_config");
const migrations = @import("sqlz_migrations");
const query_files = @import("sqlz_query_files");
const zig_queries = @import("sqlz_zig_queries");
const checker = @import("sqlz_checker");
const analysis = @import("sqlz_analysis");
const generator = @import("sqlz_generator");

pub const Error = error{
    SqliteBackendRequired,
    PostgresBackendDeferred,
    UnboundCodec,
    UnregisteredCodec,
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
    inputs: []generator.CheckedInput,

    fn deinit(self: *RootState, allocator: std.mem.Allocator) void {
        for (self.checked) |*item| item.deinit();
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
    const raw_config = try project_dir.readFileAlloc(io, config_name, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(raw_config);
    const config_source = try allocator.dupeZ(u8, raw_config);
    defer allocator.free(config_source);
    var meta: ziggy.Deserializer.Meta = .init;
    var loaded = try config.parse(allocator, config_source, &meta);
    defer loaded.deinit();
    const project = loaded.config();
    const sqlite = project.backends.sqlite orelse return error.SqliteBackendRequired;
    const dialect: checker.SqliteDialect = .{
        .profile = checker.SqliteProfile.fromString(sqlite.profile) orelse unreachable,
    };
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
        codec_infos[codec_index] = .{ .id = id, .sqlite_type = sqlite_type };
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
    var schema = try checker.replayDiscoveredSqliteWithDialect(
        allocator,
        &migration_discovery,
        dialect,
    );
    defer schema.deinit();

    for (project.zig_roots) |zig_root| {
        var zig_dir = try project_dir.openDir(io, zig_root, .{ .iterate = true });
        defer zig_dir.close(io);
        var embedded = try zig_queries.discover(allocator, io, zig_dir, source_limit);
        defer embedded.deinit();
        for (embedded.sources) |*source| {
            if (source.backends.postgres) return error.PostgresBackendDeferred;
            // Embedded declarations produce no generated output; checking them
            // is the point — their `.params`/`.row` structs must agree with the
            // SQL they sit next to.
            var checked = try checker.checkNamedSqliteWithCodecs(
                allocator,
                &schema,
                source,
                dialect,
                codec_infos,
            );
            checked.deinit();
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
        var sqlite_count: usize = 0;
        for (discovery.sources) |source| {
            if (source.backends.postgres) return error.PostgresBackendDeferred;
            if (source.backends.sqlite) sqlite_count += 1;
        }
        const checked = try allocator.alloc(checker.CheckedQuery, sqlite_count);
        var checked_count: usize = 0;
        errdefer {
            for (checked[0..checked_count]) |*item| item.deinit();
            allocator.free(checked);
        }
        const inputs = try allocator.alloc(generator.CheckedInput, sqlite_count);
        errdefer allocator.free(inputs);
        for (discovery.sources) |*source| {
            if (!source.backends.sqlite) continue;
            checked[checked_count] = try checker.checkNamedSqliteWithCodecs(
                allocator,
                &schema,
                source,
                dialect,
                codec_infos,
            );
            inputs[checked_count] = .{ .source = source, .checked = &checked[checked_count] };
            checked_count += 1;
        }
        states[initialized] = .{
            .discovery = discovery,
            .checked = checked,
            .inputs = inputs,
        };
        roots[initialized] = .{ .alias = entry.key_ptr.*, .inputs = inputs };
        initialized += 1;
    }
    return generator.generateProjectModuleWithCodecs(allocator, roots, generator_codecs);
}

fn findBinding(bindings: []const CodecBinding, id: []const u8) ?CodecBinding {
    for (bindings) |binding| if (std.mem.eql(u8, binding.id, id)) return binding;
    return null;
}
