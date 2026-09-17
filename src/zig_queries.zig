const std = @import("std");
const query_files = @import("sqlz_query_files");

pub const Discovery = query_files.Discovery;

pub const Error = error{
    InvalidZig,
    InvalidQueryDeclaration,
    InvalidSqlExpression,
    MissingBackends,
    MissingCardinality,
    InvalidBackend,
    InvalidCardinality,
    InvalidDeclaredType,
    InvalidCodecMap,
    DuplicateQueryVariant,
} || std.mem.Allocator.Error || std.zig.string_literal.ParseError;

pub fn parse(
    allocator: std.mem.Allocator,
    path: []const u8,
    contents: [:0]const u8,
) Error!Discovery {
    var tree = try std.zig.Ast.parse(allocator, contents, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidZig;

    var sources: std.ArrayList(query_files.Source) = .empty;
    errdefer {
        for (sources.items) |*source| source.deinit();
        sources.deinit(allocator);
    }
    try collectContainer(allocator, &tree, .root, path, &sources);
    return .{ .allocator = allocator, .sources = try sources.toOwnedSlice(allocator) };
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
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or
            hiddenPath(entry.path)) continue;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var sources: std.ArrayList(query_files.Source) = .empty;
    errdefer {
        for (sources.items) |*source| source.deinit();
        sources.deinit(allocator);
    }
    for (paths.items) |path| {
        const contents = try root.readFileAlloc(io, path, allocator, .limited(max_source_bytes));
        defer allocator.free(contents);
        const terminated = try allocator.dupeZ(u8, contents);
        defer allocator.free(terminated);
        var parsed = try parse(allocator, path, terminated);
        var moved: usize = 0;
        defer {
            for (parsed.sources[moved..]) |*source| source.deinit();
            allocator.free(parsed.sources);
        }
        for (parsed.sources) |*source| {
            for (sources.items) |existing| {
                if (std.mem.eql(u8, existing.name, source.name) and
                    ((existing.backends.sqlite and source.backends.sqlite) or
                        (existing.backends.postgres and source.backends.postgres)))
                    return error.DuplicateQueryVariant;
            }
            try sources.append(allocator, source.*);
            moved += 1;
        }
    }
    return .{ .allocator = allocator, .sources = try sources.toOwnedSlice(allocator) };
}

fn collectContainer(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    path: []const u8,
    sources: *std.ArrayList(query_files.Source),
) Error!void {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, node) orelse return;
    for (container.ast.members) |member| {
        if (tree.fullVarDecl(member)) |declaration| {
            if (declaration.ast.init_node.unwrap()) |init| {
                if (try parseQuery(allocator, tree, declaration, init, path)) |source|
                    try sources.append(allocator, source);
                try collectContainer(allocator, tree, init, path, sources);
            }
        } else {
            try collectContainer(allocator, tree, member, path, sources);
        }
    }
}

fn parseQuery(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    declaration: std.zig.Ast.full.VarDecl,
    init: std.zig.Ast.Node.Index,
    path: []const u8,
) Error!?query_files.Source {
    var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, init) orelse return null;
    if (!isSqlzQueryCall(tree, call.ast.fn_expr)) return null;
    if (call.ast.params.len != 1) return error.InvalidQueryDeclaration;
    var struct_buffer: [2]std.zig.Ast.Node.Index = undefined;
    const options = tree.fullStructInit(&struct_buffer, call.ast.params[0]) orelse
        return error.InvalidQueryDeclaration;

    const sql_node = fieldValue(tree, options.ast.fields, "sql") orelse
        return error.InvalidSqlExpression;
    const backend_node = fieldValue(tree, options.ast.fields, "backends") orelse
        return error.MissingBackends;
    const cardinality_node = fieldValue(tree, options.ast.fields, "cardinality") orelse
        return error.MissingCardinality;

    const sql = try stringValue(allocator, tree, sql_node);
    errdefer allocator.free(sql);
    const backends = try backendValue(tree, backend_node);
    const cardinality = std.meta.stringToEnum(
        query_files.Cardinality,
        enumLiteral(tree, cardinality_node) orelse return error.InvalidCardinality,
    ) orelse return error.InvalidCardinality;
    const params_node = fieldValue(tree, options.ast.fields, "params");
    const row_node = fieldValue(tree, options.ast.fields, "row");
    // An omitted `.params` is an empty parameter struct, which is a claim the
    // checker can still disprove; an unreadable type expression is not.
    const declared_params = if (params_node) |node|
        try declaredFields(allocator, tree, node)
    else
        try allocator.alloc(query_files.DeclaredField, 0);
    errdefer if (declared_params) |fields| query_files.freeDeclaredFields(allocator, fields);
    const declared_row = if (row_node) |node|
        try declaredFields(allocator, tree, node)
    else
        null;
    errdefer if (declared_row) |fields| query_files.freeDeclaredFields(allocator, fields);

    var param_codecs = try codecMap(allocator, tree, fieldValue(tree, options.ast.fields, "param_codecs"));
    errdefer freeCodecs(allocator, &param_codecs);
    var column_codecs = try codecMap(allocator, tree, fieldValue(tree, options.ast.fields, "column_codecs"));
    errdefer freeCodecs(allocator, &column_codecs);

    const name = tree.tokenSlice(declaration.ast.mut_token + 1);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    return .{
        .allocator = allocator,
        .path = owned_path,
        .name = owned_name,
        .backends = backends,
        .cardinality = cardinality,
        .sql = sql,
        .param_codecs = try param_codecs.toOwnedSlice(allocator),
        .column_codecs = try column_codecs.toOwnedSlice(allocator),
        .declared = .{
            .embedded = true,
            .params = declared_params,
            .params_present = params_node != null,
            .row = declared_row,
            .row_present = row_node != null,
        },
    };
}

/// Reads a `.params`/`.row` struct type expression into its fields. Returns
/// `null` when the expression is a type the checker cannot read here, such as
/// an import or a qualified path.
fn declaredFields(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) Error!?[]query_files.DeclaredField {
    const container_node = resolveContainer(tree, node) orelse return null;
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, container_node) orelse return null;

    var fields: std.ArrayList(query_files.DeclaredField) = .empty;
    errdefer {
        query_files.freeDeclaredFields(allocator, fields.items);
        fields.deinit(allocator);
    }
    for (container.ast.members) |member| {
        const field = tree.fullContainerField(member) orelse continue;
        // A tuple field has no name to match a column against.
        if (field.ast.tuple_like) return error.InvalidDeclaredType;
        const type_expr = field.ast.type_expr.unwrap() orelse return error.InvalidDeclaredType;
        const raw = std.mem.trim(u8, tree.getNodeSource(type_expr), &std.ascii.whitespace);
        const optional = raw.len != 0 and raw[0] == '?';
        const type_text = try normalizeType(allocator, if (optional) raw[1..] else raw);
        errdefer allocator.free(type_text);
        const name = try allocator.dupe(u8, tree.tokenSlice(field.ast.main_token));
        errdefer allocator.free(name);
        try fields.append(allocator, .{ .name = name, .type_text = type_text, .optional = optional });
    }
    const owned = try fields.toOwnedSlice(allocator);
    return owned;
}

/// Follows a bare identifier to a container declared in the same file, so a
/// named row struct is verified like an inline one.
fn resolveContainer(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ?std.zig.Ast.Node.Index {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&buffer, node) != null) return node;
    if (tree.nodeTag(node) != .identifier) return null;
    const wanted = tree.tokenSlice(tree.nodeMainToken(node));
    var index: u32 = 0;
    while (index < tree.nodes.len) : (index += 1) {
        const candidate: std.zig.Ast.Node.Index = @enumFromInt(index);
        const declaration = tree.fullVarDecl(candidate) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(declaration.ast.mut_token + 1), wanted)) continue;
        const init = declaration.ast.init_node.unwrap() orelse continue;
        var init_buffer: [2]std.zig.Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&init_buffer, init) != null) return init;
    }
    return null;
}

fn normalizeType(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var pending_space = false;
    for (text) |character| {
        if (std.ascii.isWhitespace(character)) {
            pending_space = output.items.len != 0;
            continue;
        }
        if (pending_space) {
            try output.append(allocator, ' ');
            pending_space = false;
        }
        try output.append(allocator, character);
    }
    return output.toOwnedSlice(allocator);
}

/// Reads `.param_codecs`/`.column_codecs` — a struct literal mapping field
/// names to registered codec IDs.
fn codecMap(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node: ?std.zig.Ast.Node.Index,
) Error!std.ArrayList(query_files.CodecOverride) {
    var overrides: std.ArrayList(query_files.CodecOverride) = .empty;
    errdefer freeCodecs(allocator, &overrides);
    const map = node orelse return overrides;
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const literal = tree.fullStructInit(&buffer, map) orelse return error.InvalidCodecMap;
    for (literal.ast.fields) |value| {
        const first = tree.firstToken(value);
        if (first < 2) return error.InvalidCodecMap;
        const field_name = tree.tokenSlice(first - 2);
        const codec = stringValue(allocator, tree, value) catch return error.InvalidCodecMap;
        errdefer allocator.free(codec);
        const owned_name = try allocator.dupe(u8, field_name);
        errdefer allocator.free(owned_name);
        try overrides.append(allocator, .{ .name = owned_name, .codec = codec });
    }
    return overrides;
}

fn freeCodecs(
    allocator: std.mem.Allocator,
    overrides: *std.ArrayList(query_files.CodecOverride),
) void {
    for (overrides.items) |override| {
        allocator.free(override.name);
        allocator.free(override.codec);
    }
    overrides.deinit(allocator);
}

fn isSqlzQueryCall(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .field_access) return false;
    const data = tree.nodeData(node).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(data[1]), "Query")) return false;
    return tree.nodeTag(data[0]) == .identifier and
        std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(data[0])), "sqlz");
}

fn fieldValue(
    tree: *const std.zig.Ast,
    fields: []const std.zig.Ast.Node.Index,
    wanted: []const u8,
) ?std.zig.Ast.Node.Index {
    for (fields) |value| {
        const first = tree.firstToken(value);
        if (first >= 2 and std.mem.eql(u8, tree.tokenSlice(first - 2), wanted)) return value;
    }
    return null;
}

fn stringValue(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) Error![]u8 {
    return switch (tree.nodeTag(node)) {
        .string_literal => std.zig.string_literal.parseAlloc(
            allocator,
            tree.tokenSlice(tree.nodeMainToken(node)),
        ),
        .multiline_string_literal => result: {
            const tokens = tree.nodeData(node).token_and_token;
            var output: std.ArrayList(u8) = .empty;
            errdefer output.deinit(allocator);
            var token = tokens[0];
            while (token <= tokens[1]) : (token += 1) {
                const line = tree.tokenSlice(token);
                if (line.len < 2) return error.InvalidSqlExpression;
                if (token != tokens[0]) try output.append(allocator, '\n');
                try output.appendSlice(allocator, line[2..]);
            }
            break :result try output.toOwnedSlice(allocator);
        },
        else => error.InvalidSqlExpression,
    };
}

fn backendValue(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) Error!query_files.Backends {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const options = tree.fullStructInit(&buffer, node) orelse return error.InvalidBackend;
    var result: query_files.Backends = .{};
    for (options.ast.fields) |value| {
        if (tree.nodeTag(value) != .identifier or
            !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "true"))
            return error.InvalidBackend;
        const first = tree.firstToken(value);
        const name = if (first >= 2) tree.tokenSlice(first - 2) else return error.InvalidBackend;
        if (std.mem.eql(u8, name, "sqlite")) result.sqlite = true else if (std.mem.eql(u8, name, "postgres")) result.postgres = true else return error.InvalidBackend;
    }
    if (!result.sqlite and !result.postgres) return error.InvalidBackend;
    return result;
}

fn enumLiteral(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ?[]const u8 {
    if (tree.nodeTag(node) != .enum_literal) return null;
    return tree.tokenSlice(tree.nodeMainToken(node));
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
