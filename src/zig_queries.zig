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
    };
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
