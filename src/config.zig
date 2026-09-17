const std = @import("std");
const ziggy = @import("ziggy");

pub const Sqlite = struct {
    profile: []const u8,
    database: []const u8 = "main",
    capabilities: []const u8 = "bundled",
};

pub const Postgres = struct {
    profile: []const u8,
    search_path: []const []const u8 = &.{"public"},
};

pub const Backends = struct {
    sqlite: ?Sqlite = null,
    postgres: ?Postgres = null,
};

pub const Codec = struct {
    sqlite_types: []const []const u8 = &.{},
    postgres_types: []const []const u8 = &.{},
};

pub const Limits = struct {
    source_bytes: u64 = 16 * 1024 * 1024,
    tokens_per_source: u64 = 1_000_000,
    nesting_depth: u32 = 256,
    diagnostics: u32 = 100,
    revisions: u32 = 10_000,
    queries: u32 = 100_000,
    registered_source_bytes: u64 = 512 * 1024 * 1024,
};

pub const Config = struct {
    format_version: u32,
    project_id: []const u8,
    migrations: []const u8,
    sql_roots: ziggy.Dictionary([]const u8),
    zig_roots: []const []const u8,
    backends: Backends,
    catalog_supplements: []const []const u8 = &.{},
    codecs: ziggy.Dictionary(Codec) = .{},
    limits: Limits = .{},
    migration_lock_timeout_ms: u32 = 30_000,
    warnings_as_errors: bool = false,
    allow_untested_version: bool = false,
};

pub const ValidationError = error{
    UnsupportedFormatVersion,
    InvalidProjectId,
    MissingBackend,
    InvalidSqlRootAlias,
    InvalidPath,
    UnsupportedSqliteProfile,
    UnsupportedSqliteCapabilities,
    UnsupportedPostgresProfile,
    InvalidLimit,
    InvalidCodecId,
    MissingCodecPatterns,
};

pub const Error = ziggy.Deserializer.Error || ValidationError;

pub const Loaded = struct {
    value: Config,
    arena: std.heap.ArenaAllocator,

    pub fn config(self: *const Loaded) *const Config {
        return &self.value;
    }

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parse(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    meta: *ziggy.Deserializer.Meta,
) Error!Loaded {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const value = try ziggy.deserializeLeaky(Config, arena.allocator(), source, meta, .{
        .copy_strings = .always,
    });
    try validate(&value);
    return .{ .value = value, .arena = arena };
}

pub fn validate(config: *const Config) ValidationError!void {
    if (config.format_version != 1) return error.UnsupportedFormatVersion;
    if (!isCanonicalUuidV4(config.project_id)) return error.InvalidProjectId;
    if (config.backends.sqlite == null and config.backends.postgres == null)
        return error.MissingBackend;
    if (config.migration_lock_timeout_ms == 0) return error.InvalidLimit;

    try validatePath(config.migrations);
    for (config.zig_roots) |path| try validatePath(path);
    for (config.catalog_supplements) |path| try validatePath(path);

    var roots = config.sql_roots.fields.iterator();
    while (roots.next()) |entry| {
        if (!isIdentifier(entry.key_ptr.*)) return error.InvalidSqlRootAlias;
        try validatePath(entry.value_ptr.*);
    }

    if (config.backends.sqlite) |sqlite| {
        if (!std.mem.eql(u8, sqlite.database, "main")) return error.InvalidPath;
        if (!std.mem.eql(u8, sqlite.capabilities, "bundled"))
            return error.UnsupportedSqliteCapabilities;
        const supported = [_][]const u8{
            "3.45", "3.46", "3.47", "3.48", "3.49",
            "3.50", "3.51", "3.52", "3.53",
        };
        if (!contains(supported[0..], sqlite.profile))
            return error.UnsupportedSqliteProfile;
    }
    if (config.backends.postgres) |postgres| {
        const supported = [_][]const u8{ "15", "16", "17", "18" };
        if (!contains(supported[0..], postgres.profile))
            return error.UnsupportedPostgresProfile;
        for (postgres.search_path) |name| {
            if (!isIdentifier(name)) return error.InvalidSqlRootAlias;
        }
    }

    var codecs = config.codecs.fields.iterator();
    while (codecs.next()) |entry| {
        // The ID is spelled into generated Zig as an import name, so it has to
        // survive as an identifier, and a codec with no database pattern could
        // never be matched against a column.
        if (!isIdentifier(entry.key_ptr.*)) return error.InvalidCodecId;
        const codec = entry.value_ptr.*;
        if (codec.sqlite_types.len == 0 and codec.postgres_types.len == 0)
            return error.MissingCodecPatterns;
    }

    const limits = config.limits;
    if (limits.source_bytes == 0 or
        limits.tokens_per_source == 0 or
        limits.nesting_depth == 0 or
        limits.diagnostics == 0 or
        limits.revisions == 0 or
        limits.queries == 0 or
        limits.registered_source_bytes == 0)
        return error.InvalidLimit;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn validatePath(path: []const u8) ValidationError!void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.InvalidPath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
            return error.InvalidPath;
    }
}

fn isIdentifier(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_'))
        return false;
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn isCanonicalUuidV4(value: []const u8) bool {
    if (value.len != 36 or
        value[8] != '-' or value[13] != '-' or
        value[18] != '-' or value[23] != '-' or
        value[14] != '4' or
        std.mem.indexOfScalar(u8, "89ab", value[19]) == null)
        return false;
    for (value, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}
