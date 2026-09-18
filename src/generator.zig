const std = @import("std");
const analysis = @import("sqlz_analysis");
const checker = @import("sqlz_checker");
const query_files = @import("sqlz_query_files");

pub const Error = error{
    UnsupportedType,
    InvalidNamespace,
    NamespaceCollision,
    UnknownCodec,
} || std.mem.Allocator.Error;

/// A codec ID resolved to the Zig declaration the build bound it to. The
/// generated module imports each bound module under `import_name` and names
/// `<import_name>.<declaration>` wherever the codec applies.
pub const CodecBinding = struct {
    id: []const u8,
    import_name: []const u8,
    declaration: []const u8,
};

pub const CheckedInput = struct {
    source: *const query_files.Source,
    checked: *const checker.CheckedQuery,
    sqlite_sql: ?[]const u8 = null,
    postgres_sql: ?[]const u8 = null,
};

pub const RootInput = struct {
    alias: []const u8,
    inputs: []const CheckedInput,
};

pub fn generateQuery(
    allocator: std.mem.Allocator,
    source: *const query_files.Source,
    checked: *const checker.CheckedQuery,
) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator,
        \\const sqlz = @import("sqlz");
        \\
    );
    try writeQuery(&output, allocator, source, checked, 0, &.{}, null, null);
    return output.toOwnedSlice(allocator);
}

pub fn generateModule(
    allocator: std.mem.Allocator,
    root_alias: []const u8,
    inputs: []const CheckedInput,
) Error![]u8 {
    return generateProjectModule(allocator, &.{.{ .alias = root_alias, .inputs = inputs }});
}

pub fn generateProjectModule(allocator: std.mem.Allocator, roots: []const RootInput) Error![]u8 {
    return generateProjectModuleWithCodecs(allocator, roots, &.{});
}

pub fn generateProjectModuleWithCodecs(
    allocator: std.mem.Allocator,
    roots: []const RootInput,
    codecs: []const CodecBinding,
) Error![]u8 {
    const sorted_roots = try allocator.dupe(RootInput, roots);
    defer allocator.free(sorted_roots);
    std.mem.sort(RootInput, sorted_roots, {}, struct {
        fn lessThan(_: void, lhs: RootInput, rhs: RootInput) bool {
            return std.mem.lessThan(u8, lhs.alias, rhs.alias);
        }
    }.lessThan);
    for (sorted_roots, 0..) |root, index| {
        if (!isIdentifier(root.alias)) return error.InvalidNamespace;
        if (index > 0 and std.mem.eql(u8, sorted_roots[index - 1].alias, root.alias))
            return error.NamespaceCollision;
    }

    const sorted_codecs = try allocator.dupe(CodecBinding, codecs);
    defer allocator.free(sorted_codecs);
    std.mem.sort(CodecBinding, sorted_codecs, {}, struct {
        fn lessThan(_: void, lhs: CodecBinding, rhs: CodecBinding) bool {
            return std.mem.lessThan(u8, lhs.id, rhs.id);
        }
    }.lessThan);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator,
        \\const sqlz = @import("sqlz");
        \\
    );
    for (sorted_codecs) |codec|
        try output.print(allocator, "const {s} = @import(\"{s}\");\n", .{ codec.import_name, codec.import_name });
    if (sorted_codecs.len != 0) {
        // The build binds an ID to one declaration; this is where a binding
        // that is not a usable codec fails, at the consumer's compilation.
        try output.appendSlice(allocator, "\ncomptime {\n");
        for (sorted_codecs) |codec|
            try output.print(allocator, "    sqlz.assertCodec({s}.{s});\n", .{ codec.import_name, codec.declaration });
        try output.appendSlice(allocator, "}\n");
    }
    try output.appendSlice(allocator,
        \\
        \\// Generated checked queries; do not edit.
        \\
    );
    for (sorted_roots) |root| try writeRoot(&output, allocator, root.alias, root.inputs, sorted_codecs);
    return output.toOwnedSlice(allocator);
}

fn writeRoot(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    root_alias: []const u8,
    inputs: []const CheckedInput,
    codecs: []const CodecBinding,
) Error!void {
    const entries = try allocator.alloc(Entry, inputs.len);
    defer {
        for (entries) |entry| allocator.free(entry.directories);
        allocator.free(entries);
    }
    for (inputs, entries) |input, *entry|
        entry.* = .{ .input = input, .directories = try directories(allocator, input.source.path) };
    std.mem.sort(Entry, entries, {}, Entry.lessThan);
    try validateNamespaces(entries);

    try output.print(allocator, "pub const {s} = struct {{\n", .{root_alias});
    var previous: []const []const u8 = &.{};
    var entry_index: usize = 0;
    while (entry_index < entries.len) {
        const entry = entries[entry_index];
        var group_end = entry_index + 1;
        while (group_end < entries.len and sameQuery(entry, entries[group_end])) : (group_end += 1) {}
        const common = commonPrefix(previous, entry.directories);
        var close_index = previous.len;
        while (close_index > common) {
            close_index -= 1;
            try writeIndent(output, allocator, close_index + 1);
            try output.appendSlice(allocator, "};\n");
        }
        for (entry.directories[common..], common..) |directory, depth| {
            try writeIndent(output, allocator, depth + 1);
            try output.print(allocator, "pub const {s} = struct {{\n", .{directory});
        }
        try writeQueryGroup(output, allocator, entries[entry_index..group_end], entry.directories.len + 1, codecs);
        previous = entry.directories;
        entry_index = group_end;
    }
    var close_index = previous.len;
    while (close_index > 0) {
        close_index -= 1;
        try writeIndent(output, allocator, close_index + 1);
        try output.appendSlice(allocator, "};\n");
    }
    try output.appendSlice(allocator, "};\n");
}

const Entry = struct {
    input: CheckedInput,
    directories: []const []const u8,

    fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
        const directory_order = compareDirectories(lhs.directories, rhs.directories);
        if (directory_order != .eq) return directory_order == .lt;
        const name_order = std.mem.order(u8, lhs.input.source.name, rhs.input.source.name);
        if (name_order != .eq) return name_order == .lt;
        return std.mem.lessThan(u8, lhs.input.source.path, rhs.input.source.path);
    }
};

fn compareDirectories(lhs: []const []const u8, rhs: []const []const u8) std.math.Order {
    const count = @min(lhs.len, rhs.len);
    for (0..count) |index| {
        const order = std.mem.order(u8, lhs[index], rhs[index]);
        if (order != .eq) return order;
    }
    return std.math.order(lhs.len, rhs.len);
}

fn sameQuery(lhs: Entry, rhs: Entry) bool {
    return compareDirectories(lhs.directories, rhs.directories) == .eq and
        std.mem.eql(u8, lhs.input.source.name, rhs.input.source.name);
}

fn writeQueryGroup(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    entries: []const Entry,
    indent: usize,
    codecs: []const CodecBinding,
) Error!void {
    const representative = entries[0].input;
    var sqlite_sql: ?[]const u8 = null;
    var postgres_sql: ?[]const u8 = null;
    for (entries) |entry| {
        const input = entry.input;
        if (entrySql(.sqlite, input.source, input.checked, input.sqlite_sql, input.postgres_sql)) |sql| {
            if (sqlite_sql != null) return error.NamespaceCollision;
            sqlite_sql = sql;
        }
        if (entrySql(.postgres, input.source, input.checked, input.sqlite_sql, input.postgres_sql)) |sql| {
            if (postgres_sql != null) return error.NamespaceCollision;
            postgres_sql = sql;
        }
    }
    try writeQuery(
        output,
        allocator,
        representative.source,
        representative.checked,
        indent,
        codecs,
        sqlite_sql,
        postgres_sql,
    );
}

fn writeQuery(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    source: *const query_files.Source,
    checked: *const checker.CheckedQuery,
    indent: usize,
    codecs: []const CodecBinding,
    sqlite_override: ?[]const u8,
    postgres_override: ?[]const u8,
) Error!void {
    try writeIndent(output, allocator, indent);
    try output.print(allocator, "// Generated from {s}; do not edit.\n", .{source.path});
    try writeIndent(output, allocator, indent);
    try output.print(allocator, "pub const {s} = sqlz.Query(.{{\n", .{source.name});
    try writeIndent(output, allocator, indent + 1);
    const sqlite_sql = entrySql(.sqlite, source, checked, sqlite_override, postgres_override);
    const postgres_sql = entrySql(.postgres, source, checked, sqlite_override, postgres_override);
    try writeSql(output, allocator, indent + 1, sqlite_sql, postgres_sql);
    try writeIndent(output, allocator, indent + 1);
    try output.appendSlice(allocator, ".backends = .{");
    if (sqlite_sql != null) try output.appendSlice(allocator, " .sqlite = true,");
    if (postgres_sql != null) try output.appendSlice(allocator, " .postgres = true,");
    try output.appendSlice(allocator, " },\n");
    try writeIndent(output, allocator, indent + 1);
    try output.print(allocator, ".cardinality = .{s},\n", .{@tagName(source.cardinality)});
    try writeIndent(output, allocator, indent + 1);
    try output.appendSlice(allocator, ".parameter_names = .{");
    for (checked.analysis.parameters) |parameter|
        try output.print(allocator, " \"{f}\",", .{std.zig.fmtString(parameter.name)});
    try output.appendSlice(allocator, " },\n");
    try writeIndent(output, allocator, indent + 1);
    try output.appendSlice(allocator, ".params = struct {\n");
    for (checked.analysis.parameters) |parameter| {
        try writeIndent(output, allocator, indent + 2);
        try output.print(allocator, "{s}: ", .{parameter.name});
        try writeType(output, allocator, parameter, codecs);
        try output.appendSlice(allocator, ",\n");
    }
    try writeIndent(output, allocator, indent + 1);
    try output.appendSlice(allocator, "},\n");
    if (source.cardinality != .exec) {
        try writeIndent(output, allocator, indent + 1);
        try output.appendSlice(allocator, ".row = struct {\n");
        for (checked.analysis.columns) |column| {
            try writeIndent(output, allocator, indent + 2);
            try output.print(allocator, "{s}: ", .{column.name});
            try writeType(output, allocator, column, codecs);
            try output.appendSlice(allocator, ",\n");
        }
        try writeIndent(output, allocator, indent + 1);
        try output.appendSlice(allocator, "},\n");
    }
    try writeIndent(output, allocator, indent);
    try output.appendSlice(allocator, "});\n");
}

const Backend = enum { sqlite, postgres };

fn entrySql(
    backend: Backend,
    source: *const query_files.Source,
    checked: *const checker.CheckedQuery,
    sqlite_sql: ?[]const u8,
    postgres_sql: ?[]const u8,
) ?[]const u8 {
    return switch (backend) {
        .sqlite => sqlite_sql orelse if (source.backends.sqlite) checked.parsed.rewritten.sql else null,
        .postgres => postgres_sql orelse if (source.backends.postgres) checked.parsed.rewritten.sql else null,
    };
}

fn writeSql(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: usize,
    sqlite_sql: ?[]const u8,
    postgres_sql: ?[]const u8,
) !void {
    if (sqlite_sql != null and postgres_sql != null and
        std.mem.eql(u8, sqlite_sql.?, postgres_sql.?))
    {
        try writeIndent(output, allocator, indent);
        try output.print(allocator, ".sql = \"{f}\",\n", .{std.zig.fmtString(sqlite_sql.?)});
        return;
    }
    try writeIndent(output, allocator, indent);
    try output.appendSlice(allocator, ".sql = .{\n");
    if (sqlite_sql) |sql| {
        try writeIndent(output, allocator, indent + 1);
        try output.print(allocator, ".sqlite = \"{f}\",\n", .{std.zig.fmtString(sql)});
    }
    if (postgres_sql) |sql| {
        try writeIndent(output, allocator, indent + 1);
        try output.print(allocator, ".postgres = \"{f}\",\n", .{std.zig.fmtString(sql)});
    }
    try writeIndent(output, allocator, indent);
    try output.appendSlice(allocator, "},\n");
}

fn directories(allocator: std.mem.Allocator, path: []const u8) Error![]const []const u8 {
    const parent = std.fs.path.dirname(path) orelse return allocator.alloc([]const u8, 0);
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(allocator);
    var parts = std.mem.tokenizeAny(u8, parent, "/\\");
    while (parts.next()) |part| {
        if (!isIdentifier(part)) return error.InvalidNamespace;
        try result.append(allocator, part);
    }
    return result.toOwnedSlice(allocator);
}

fn validateNamespaces(entries: []const Entry) Error!void {
    for (entries, 0..) |entry, index| {
        if (!isIdentifier(entry.input.source.name)) return error.InvalidNamespace;
        for (entries[index + 1 ..]) |other| {
            const common = commonPrefix(entry.directories, other.directories);
            if (common == entry.directories.len and common == other.directories.len and
                std.mem.eql(u8, entry.input.source.name, other.input.source.name))
            {
                const left = entry.input.source.backends;
                const right = other.input.source.backends;
                if ((left.sqlite and right.sqlite) or (left.postgres and right.postgres))
                    return error.NamespaceCollision;
                continue;
            }
            if (common == entry.directories.len and other.directories.len > common and
                std.mem.eql(u8, entry.input.source.name, other.directories[common]))
                return error.NamespaceCollision;
            if (common == other.directories.len and entry.directories.len > common and
                std.mem.eql(u8, other.input.source.name, entry.directories[common]))
                return error.NamespaceCollision;
        }
    }
}

fn commonPrefix(lhs: []const []const u8, rhs: []const []const u8) usize {
    const count = @min(lhs.len, rhs.len);
    for (0..count) |index| if (!std.mem.eql(u8, lhs[index], rhs[index])) return index;
    return count;
}

fn findBinding(codecs: []const CodecBinding, id: []const u8) ?CodecBinding {
    for (codecs) |codec| if (std.mem.eql(u8, codec.id, id)) return codec;
    return null;
}

fn writeIndent(output: *std.ArrayList(u8), allocator: std.mem.Allocator, depth: usize) !void {
    for (0..depth) |_| try output.appendSlice(allocator, "    ");
}

fn isIdentifier(value: []const u8) bool {
    if (value.len == 0 or !(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return false;
    for (value[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn writeType(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: analysis.ResultColumn,
    codecs: []const CodecBinding,
) Error!void {
    if (value.codec) |id| {
        const binding = findBinding(codecs, id) orelse return error.UnknownCodec;
        if (value.nullable) try output.append(allocator, '?');
        try output.print(allocator, "{s}.{s}", .{ binding.import_name, binding.declaration });
        return;
    }
    const spelling = analysis.zigTypeName(value.scalar_type) orelse return error.UnsupportedType;
    if (value.nullable) try output.append(allocator, '?');
    try output.appendSlice(allocator, spelling);
}
