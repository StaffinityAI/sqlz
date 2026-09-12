const std = @import("std");
const ziggy = @import("ziggy");
const config = @import("sqlz_config");
const migrations = @import("sqlz_migrations");
const query_files = @import("sqlz_query_files");
const checker = @import("sqlz_checker");
const generator = @import("sqlz_generator");

pub const Error = error{
    SqliteBackendRequired,
    PostgresBackendDeferred,
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
            checked[checked_count] = try checker.checkNamedSqliteWithDialect(
                allocator,
                &schema,
                source,
                dialect,
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
    return generator.generateProjectModule(allocator, roots);
}
