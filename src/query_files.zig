const std = @import("std");

pub const Backends = struct {
    sqlite: bool = false,
    postgres: bool = false,
};

pub const Cardinality = enum { exec, one, optional, many };

pub const Source = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    name: []const u8,
    backends: Backends,
    cardinality: Cardinality,
    sql: []const u8,

    pub fn deinit(self: *Source) void {
        self.allocator.free(self.path);
        self.allocator.free(self.name);
        self.allocator.free(self.sql);
        self.* = undefined;
    }
};

pub const Discovery = struct {
    allocator: std.mem.Allocator,
    sources: []Source,

    pub fn deinit(self: *Discovery) void {
        for (self.sources) |*source| source.deinit();
        self.allocator.free(self.sources);
        self.* = undefined;
    }
};

pub const Error = error{
    MissingName,
    MissingBackends,
    MissingCardinality,
    EmptySql,
    InvalidDirective,
    UnknownDirective,
    DuplicateDirective,
    InvalidName,
    InvalidBackend,
    DuplicateBackend,
    InvalidCardinality,
    DuplicateQueryVariant,
} || std.mem.Allocator.Error;

pub fn parse(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) Error!Source {
    var name: ?[]const u8 = null;
    var backends: ?Backends = null;
    var cardinality: ?Cardinality = null;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    var sql_start: ?usize = null;
    var position: usize = 0;
    while (position < contents.len) {
        const newline = std.mem.indexOfScalarPos(u8, contents, position, '\n') orelse contents.len;
        const line_start = position;
        const line = std.mem.trim(u8, contents[position..newline], &std.ascii.whitespace);
        position = if (newline < contents.len) newline + 1 else contents.len;
        if (line.len == 0 or (std.mem.startsWith(u8, line, "--") and
            !std.mem.startsWith(u8, line, "-- sqlz."))) continue;
        if (!std.mem.startsWith(u8, line, "-- sqlz.")) {
            sql_start = line_start;
            break;
        }
        const directive = line[8..];
        const colon = std.mem.indexOfScalar(u8, directive, ':') orelse
            return error.InvalidDirective;
        const key = std.mem.trim(u8, directive[0..colon], &std.ascii.whitespace);
        const value = std.mem.trim(u8, directive[colon + 1 ..], &std.ascii.whitespace);
        if (key.len == 0 or value.len == 0) return error.InvalidDirective;
        const entry = try seen.getOrPut(allocator, key);
        if (entry.found_existing) return error.DuplicateDirective;

        if (std.mem.eql(u8, key, "name")) {
            if (!isIdentifier(value)) return error.InvalidName;
            name = value;
        } else if (std.mem.eql(u8, key, "backends")) {
            backends = try parseBackends(value);
        } else if (std.mem.eql(u8, key, "cardinality")) {
            cardinality = std.meta.stringToEnum(Cardinality, value) orelse
                return error.InvalidCardinality;
        } else if (std.mem.startsWith(u8, key, "param.")) {
            if (!isIdentifier(key[6..])) return error.InvalidDirective;
        } else if (std.mem.startsWith(u8, key, "column.")) {
            if (!isIdentifier(key[7..])) return error.InvalidDirective;
        } else {
            return error.UnknownDirective;
        }
    }

    const sql = std.mem.trim(u8, contents[sql_start orelse contents.len ..], &std.ascii.whitespace);
    if (sql.len == 0) return error.EmptySql;
    const parsed_name = name orelse return error.MissingName;
    const parsed_backends = backends orelse return error.MissingBackends;
    const parsed_cardinality = cardinality orelse return error.MissingCardinality;
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const owned_name = try allocator.dupe(u8, parsed_name);
    errdefer allocator.free(owned_name);
    const owned_sql = try allocator.dupe(u8, sql);
    errdefer allocator.free(owned_sql);
    return .{
        .allocator = allocator,
        .path = owned_path,
        .name = owned_name,
        .backends = parsed_backends,
        .cardinality = parsed_cardinality,
        .sql = owned_sql,
    };
}

pub fn discover(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    max_source_bytes: usize,
) anyerror!Discovery {
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".sql") or
            hiddenPath(entry.path)) continue;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var sources: std.ArrayList(Source) = .empty;
    errdefer {
        for (sources.items) |*source| source.deinit();
        sources.deinit(allocator);
    }
    for (paths.items) |path| {
        const contents = try root.readFileAlloc(io, path, allocator, .limited(max_source_bytes));
        defer allocator.free(contents);
        var source = try parse(allocator, path, contents);
        errdefer source.deinit();
        for (sources.items) |existing| {
            if (std.mem.eql(u8, existing.name, source.name) and
                ((existing.backends.sqlite and source.backends.sqlite) or
                    (existing.backends.postgres and source.backends.postgres)))
                return error.DuplicateQueryVariant;
        }
        try sources.append(allocator, source);
    }
    return .{ .allocator = allocator, .sources = try sources.toOwnedSlice(allocator) };
}

fn parseBackends(value: []const u8) Error!Backends {
    var result: Backends = .{};
    var values = std.mem.splitScalar(u8, value, ',');
    while (values.next()) |raw| {
        const backend = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (std.mem.eql(u8, backend, "sqlite")) {
            if (result.sqlite) return error.DuplicateBackend;
            result.sqlite = true;
        } else if (std.mem.eql(u8, backend, "postgres")) {
            if (result.postgres) return error.DuplicateBackend;
            result.postgres = true;
        } else {
            return error.InvalidBackend;
        }
    }
    if (!result.sqlite and !result.postgres) return error.InvalidBackend;
    return result;
}

fn hiddenPath(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (components.next()) |component| {
        if (component.len > 0 and component[0] == '.') return true;
        if (std.mem.eql(u8, component, "zig-cache") or
            std.mem.eql(u8, component, "zig-out")) return true;
    }
    return false;
}

fn isIdentifier(value: []const u8) bool {
    if (value.len == 0 or !(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return false;
    for (value[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}
