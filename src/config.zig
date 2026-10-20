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
    UnsupportedCatalogSupplements,
};

pub const Error = ziggy.Deserializer.Error || ValidationError;

/// The fixed bound for reading `sqlz.ziggy` itself. The configured
/// `limits.source_bytes` is unknown until the file is parsed, so the file is
/// first read under this bound and then charged against the parsed limits.
pub const max_config_bytes: usize = 1024 * 1024;

/// How each format-1 field reaches its consumer. Every field of `Config` and
/// its nested structs has exactly one entry; `test/config.zig` checks that.
pub const Usage = enum {
    /// Enforced while loading or checking the project.
    checker,
    /// Emitted into the generated module for runtime code to consume.
    runtime,
    /// Accepted and validated, but its consumer is not implemented yet.
    deferred,
};

pub const FieldUsage = struct {
    field: []const u8,
    usage: Usage,
    consumer: []const u8,
};

pub const field_usage = [_]FieldUsage{
    .{ .field = "format_version", .usage = .checker, .consumer = "config.validate" },
    .{ .field = "project_id", .usage = .runtime, .consumer = "generated `sqlz_project.id`" },
    .{ .field = "migrations", .usage = .checker, .consumer = "migration discovery" },
    .{ .field = "sql_roots", .usage = .checker, .consumer = "named query discovery and namespaces" },
    .{ .field = "zig_roots", .usage = .checker, .consumer = "embedded query discovery" },
    .{ .field = "backends", .usage = .checker, .consumer = "catalog replay and query checking" },
    .{ .field = "backends.sqlite.profile", .usage = .runtime, .consumer = "checker dialect; generated `sqlz_project.sqlite_profile`" },
    .{ .field = "backends.sqlite.database", .usage = .checker, .consumer = "config.validate: only `main` in 0.1" },
    .{ .field = "backends.sqlite.capabilities", .usage = .checker, .consumer = "config.validate: only `bundled` in 0.1" },
    .{ .field = "backends.postgres.profile", .usage = .runtime, .consumer = "checker dialect; generated `sqlz_project.postgres_profile`" },
    .{ .field = "backends.postgres.search_path", .usage = .checker, .consumer = "PostgreSQL catalog name resolution" },
    .{ .field = "catalog_supplements", .usage = .checker, .consumer = "config.validate: must be empty until supplements load (0.2, slice 5)" },
    .{ .field = "codecs", .usage = .checker, .consumer = "codec bindings and type checking" },
    .{ .field = "codecs.sqlite_types", .usage = .checker, .consumer = "codec scalar resolution" },
    .{ .field = "codecs.postgres_types", .usage = .checker, .consumer = "codec scalar resolution" },
    .{ .field = "limits", .usage = .checker, .consumer = "inputs.Inputs" },
    .{ .field = "limits.source_bytes", .usage = .checker, .consumer = "inputs.Inputs: every read, including `sqlz.ziggy`" },
    .{ .field = "limits.tokens_per_source", .usage = .deferred, .consumer = "slice 3: rewriting, parsing, and Zig discovery" },
    .{ .field = "limits.nesting_depth", .usage = .deferred, .consumer = "slice 3: parsing, Zig discovery, and AST adaptation" },
    .{ .field = "limits.diagnostics", .usage = .checker, .consumer = "diagnostics.List cap" },
    .{ .field = "limits.revisions", .usage = .checker, .consumer = "migration discovery, before manifests are read" },
    .{ .field = "limits.queries", .usage = .checker, .consumer = "named and embedded query discovery" },
    .{ .field = "limits.registered_source_bytes", .usage = .checker, .consumer = "inputs.Inputs: total bytes read" },
    .{ .field = "migration_lock_timeout_ms", .usage = .runtime, .consumer = "generated `sqlz_project.migration_lock_timeout_ms`; migration runners (slices 18-19)" },
    .{ .field = "warnings_as_errors", .usage = .deferred, .consumer = "slice 6: the checker emits no warnings yet" },
    .{ .field = "allow_untested_version", .usage = .runtime, .consumer = "generated `sqlz_project.allow_untested_version`; runtime version policy" },
};

pub const Loaded = struct {
    value: Config,
    arena: std.heap.ArenaAllocator,
    /// Length of the configuration source, for the caller's input budget.
    source_len: usize,

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
    // Dictionary keys borrow the source even with `copy_strings`, so the
    // loaded value keeps its own copy instead of the caller's buffer.
    const owned_source = try arena.allocator().dupeZ(u8, source);
    const value = try ziggy.deserializeLeaky(Config, arena.allocator(), owned_source, meta, .{
        .copy_strings = .always,
    });
    try validate(&value);
    return .{ .value = value, .arena = arena, .source_len = source.len };
}

/// Reads and parses the configuration file `name` in `dir` under
/// `max_config_bytes`. The caller charges `source_len` against the parsed
/// limits.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
) !Loaded {
    const raw = dir.readFileAlloc(io, name, allocator, .limited(max_config_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.ConfigurationTooLarge,
        else => return err,
    };
    defer allocator.free(raw);
    const source = try allocator.dupeZ(u8, raw);
    defer allocator.free(source);
    var meta: ziggy.Deserializer.Meta = .init;
    return parse(allocator, source, &meta);
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
    // Supplements are not loaded in 0.1. Accepting them would let a project
    // believe its declared functions and types were checked.
    if (config.catalog_supplements.len != 0) return error.UnsupportedCatalogSupplements;

    var roots = config.sql_roots.fields.iterator();
    while (roots.next()) |entry| {
        // Aliases become top-level declarations of the generated module,
        // which reserves the `sqlz` prefix for its own declarations.
        if (!isIdentifier(entry.key_ptr.*) or reserved(entry.key_ptr.*))
            return error.InvalidSqlRootAlias;
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
    // The project root is a legitimate root — a project whose Zig sources sit
    // beside `sqlz.ziggy` has no other way to spell it — but `.` as a component
    // of a longer path is still an unnormalized spelling.
    if (std.mem.eql(u8, path, ".")) return;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
            return error.InvalidPath;
    }
}

fn reserved(name: []const u8) bool {
    return std.mem.eql(u8, name, "sqlz") or std.mem.startsWith(u8, name, "sqlz_");
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
