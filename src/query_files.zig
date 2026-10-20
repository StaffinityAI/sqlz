const std = @import("std");
const inputs = @import("sqlz_inputs");
const source_manager = @import("sqlz_source");

pub const Backends = struct {
    sqlite: bool = false,
    postgres: bool = false,
};

pub const Cardinality = enum { exec, one, optional, many };

/// A `sqlz.param.<name>` or `sqlz.column.<name>` directive: the codec ID the
/// author pinned to one parameter or result column.
pub const CodecOverride = struct {
    name: []const u8,
    codec: []const u8,
};

/// One field of an embedded declaration's `.params` or `.row` struct, exactly
/// as the author spelled it. The checker compares these against what it infers
/// from the SQL, so a declaration cannot quietly disagree with its query.
pub const DeclaredField = struct {
    name: []const u8,
    /// The field type with any leading `?` removed and whitespace normalized.
    type_text: []const u8,
    optional: bool,
};

pub const Declared = struct {
    /// Set for embedded Zig declarations: the author wrote structs the checker
    /// must agree with. A `.sql` file declares no Zig types at all.
    embedded: bool = false,
    /// `null` when the declaration names a type the checker cannot read — an
    /// import or a qualified path — so that side goes unverified rather than
    /// being reported as wrong.
    params: ?[]const DeclaredField = null,
    params_present: bool = false,
    row: ?[]const DeclaredField = null,
    row_present: bool = false,
};

pub const Source = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    name: []const u8,
    backends: Backends,
    cardinality: Cardinality,
    sql: []const u8,
    /// Byte offset of `sql` in `source_text`.
    sql_offset: usize = 0,
    /// Where the `sqlz.name` directive's value sits, for diagnostics that
    /// point at the query's name rather than its SQL.
    name_offset: usize = 0,
    /// For embedded SQL, the offset in `source_text` of each byte of `sql`
    /// plus one past its end; a Zig string literal's escapes make the two
    /// differ. Null for a `.sql` file, whose SQL is the slice of `source_text`
    /// at `sql_offset`.
    sql_source_offsets: ?[]const usize = null,
    /// The whole original file, BOM included, for spans and excerpts.
    source_text: ?[]const u8 = null,
    param_codecs: []const CodecOverride = &.{},
    column_codecs: []const CodecOverride = &.{},
    declared: Declared = .{},

    pub fn deinit(self: *Source) void {
        self.allocator.free(self.path);
        self.allocator.free(self.name);
        self.allocator.free(self.sql);
        if (self.sql_source_offsets) |offsets| self.allocator.free(offsets);
        if (self.source_text) |text| self.allocator.free(text);
        freeOverrides(self.allocator, self.param_codecs);
        freeOverrides(self.allocator, self.column_codecs);
        if (self.declared.params) |fields| freeDeclaredFields(self.allocator, fields);
        if (self.declared.row) |fields| freeDeclaredFields(self.allocator, fields);
        self.* = undefined;
    }
};

pub fn freeDeclaredFields(allocator: std.mem.Allocator, fields: []const DeclaredField) void {
    for (fields) |field| {
        allocator.free(field.name);
        allocator.free(field.type_text);
    }
    allocator.free(fields);
}

fn freeOverrides(allocator: std.mem.Allocator, overrides: []const CodecOverride) void {
    for (overrides) |override| {
        allocator.free(override.name);
        allocator.free(override.codec);
    }
    allocator.free(overrides);
}

/// Frees a list still being built: its items and its whole capacity.
fn freeOverrideList(allocator: std.mem.Allocator, list: *std.ArrayList(CodecOverride)) void {
    for (list.items) |override| {
        allocator.free(override.name);
        allocator.free(override.codec);
    }
    list.deinit(allocator);
}

fn appendOverride(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(CodecOverride),
    name: []const u8,
    codec: []const u8,
) Error!void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_codec = try allocator.dupe(u8, codec);
    errdefer allocator.free(owned_codec);
    try list.append(allocator, .{ .name = owned_name, .codec = owned_codec });
}

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
    InvalidCodecId,
    DuplicateQueryVariant,
} || std.mem.Allocator.Error;

pub fn parse(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) Error!Source {
    var name: ?[]const u8 = null;
    var name_offset: usize = 0;
    var backends: ?Backends = null;
    var cardinality: ?Cardinality = null;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var param_codecs: std.ArrayList(CodecOverride) = .empty;
    errdefer freeOverrideList(allocator, &param_codecs);
    var column_codecs: std.ArrayList(CodecOverride) = .empty;
    errdefer freeOverrideList(allocator, &column_codecs);

    var sql_start: ?usize = null;
    // A byte order mark is not part of the first line.
    var position: usize = source_manager.bomLength(contents);
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
            name_offset = @intFromPtr(value.ptr) - @intFromPtr(contents.ptr);
        } else if (std.mem.eql(u8, key, "backends")) {
            backends = try parseBackends(value);
        } else if (std.mem.eql(u8, key, "cardinality")) {
            cardinality = std.meta.stringToEnum(Cardinality, value) orelse
                return error.InvalidCardinality;
        } else if (std.mem.startsWith(u8, key, "param.")) {
            if (!isIdentifier(key[6..])) return error.InvalidDirective;
            if (!isIdentifier(value)) return error.InvalidCodecId;
            try appendOverride(allocator, &param_codecs, key[6..], value);
        } else if (std.mem.startsWith(u8, key, "column.")) {
            if (!isIdentifier(key[7..])) return error.InvalidDirective;
            if (!isIdentifier(value)) return error.InvalidCodecId;
            try appendOverride(allocator, &column_codecs, key[7..], value);
        } else {
            return error.UnknownDirective;
        }
    }

    const raw_sql_start = sql_start orelse contents.len;
    const raw_sql = contents[raw_sql_start..];
    const sql = std.mem.trim(u8, raw_sql, &std.ascii.whitespace);
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
    const owned_text = try allocator.dupe(u8, contents);
    errdefer allocator.free(owned_text);
    const sql_offset = raw_sql_start + @as(usize, @intCast(sql.ptr - raw_sql.ptr));
    std.debug.assert(std.mem.eql(u8, contents[sql_offset..][0..sql.len], sql));
    return .{
        .allocator = allocator,
        .path = owned_path,
        .name = owned_name,
        .backends = parsed_backends,
        .cardinality = parsed_cardinality,
        .sql = owned_sql,
        .sql_offset = sql_offset,
        .name_offset = name_offset,
        .source_text = owned_text,
        .param_codecs = try param_codecs.toOwnedSlice(allocator),
        .column_codecs = try column_codecs.toOwnedSlice(allocator),
    };
}

/// Discovers every query file under `root` and rejects the first duplicate
/// variant. `discoverAll` leaves duplicates for the caller to report.
pub fn discover(
    allocator: std.mem.Allocator,
    project_inputs: *inputs.Inputs,
    root: std.Io.Dir,
) anyerror!Discovery {
    var discovery = try discoverAll(allocator, project_inputs, root);
    errdefer discovery.deinit();
    var variants = try Variants.init(allocator, discovery.sources);
    defer variants.deinit(allocator);
    for (variants.duplicate) |duplicate| {
        if (duplicate != null) return error.DuplicateQueryVariant;
    }
    return discovery;
}

/// How sources group into logical queries. Directories are namespaces, so a
/// name repeats freely across them. Within one directory, files sharing a name
/// are that query's backend variants and must not both cover a backend.
/// Computed in one pass, since a project may hold many thousands of queries.
pub const Variants = struct {
    /// For each source, the index of the first source with the same directory
    /// and name: the identity of its logical query.
    group: []usize,
    /// For each source, the earliest source it collides with on a backend.
    duplicate: []?usize,

    pub fn init(allocator: std.mem.Allocator, sources: []const Source) !Variants {
        const Backends_ = struct { first: usize, sqlite: ?usize = null, postgres: ?usize = null };
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        var groups: std.StringHashMapUnmanaged(Backends_) = .empty;
        const group = try allocator.alloc(usize, sources.len);
        errdefer allocator.free(group);
        const duplicate = try allocator.alloc(?usize, sources.len);
        errdefer allocator.free(duplicate);
        for (sources, 0..) |source, index| {
            const key = try std.fmt.allocPrint(arena.allocator(), "{s}\x00{s}", .{
                std.fs.path.dirname(source.path) orelse "",
                source.name,
            });
            const entry = try groups.getOrPut(arena.allocator(), key);
            if (!entry.found_existing) entry.value_ptr.* = .{ .first = index };
            const state = entry.value_ptr;
            group[index] = state.first;
            var collision: ?usize = null;
            if (source.backends.sqlite) {
                if (state.sqlite) |first| collision = first else state.sqlite = index;
            }
            if (source.backends.postgres) {
                if (state.postgres) |first| {
                    collision = if (collision) |other| @min(other, first) else first;
                } else state.postgres = index;
            }
            duplicate[index] = collision;
        }
        return .{ .group = group, .duplicate = duplicate };
    }

    pub fn deinit(self: *Variants, allocator: std.mem.Allocator) void {
        allocator.free(self.group);
        allocator.free(self.duplicate);
        self.* = undefined;
    }
};

pub fn discoverAll(
    allocator: std.mem.Allocator,
    project_inputs: *inputs.Inputs,
    root: std.Io.Dir,
) anyerror!Discovery {
    const io = project_inputs.io;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (hiddenPath(entry.path)) continue;
        const candidate = std.mem.endsWith(u8, entry.basename, ".sql");
        const kind = try project_inputs.entryKind(entry.dir, entry.basename, entry.kind, candidate);
        if (kind != .file or !candidate) continue;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    // Each file is one query, so the limit applies before any is read, and
    // in path order so the reported file is deterministic.
    for (paths.items) |path| try project_inputs.countQueries(root, path, 1);

    var sources: std.ArrayList(Source) = .empty;
    errdefer {
        for (sources.items) |*source| source.deinit();
        sources.deinit(allocator);
    }
    for (paths.items) |path| {
        const contents = try project_inputs.readFile(allocator, root, path);
        defer allocator.free(contents);
        var source = try parse(allocator, path, contents);
        errdefer source.deinit();
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
            std.mem.eql(u8, component, "zig-out") or
            std.mem.eql(u8, component, "zig-pkg")) return true;
    }
    return false;
}

fn isIdentifier(value: []const u8) bool {
    if (value.len == 0 or !(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return false;
    for (value[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}
