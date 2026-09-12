const std = @import("std");

pub const StatementKind = enum { select, insert, update, delete };

pub const Relation = struct {
    name: []const u8,
    alias: ?[]const u8,
    nullable: bool,
};

pub const ColumnReference = struct {
    qualifier: ?[]const u8,
    name: []const u8,
};

pub const Projection = struct {
    name: []const u8,
    column: ?ColumnReference,
};

pub const Query = struct {
    arena: std.heap.ArenaAllocator,
    kind: StatementKind,
    mutation_target: ?[]const u8,
    relations: []const []const u8,
    relation_bindings: []const Relation,
    parameters: []const []const u8,
    result_columns: []const []const u8,
    projections: []const Projection,

    pub fn deinit(self: *Query) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Error = error{
    InvalidAst,
    MultipleStatements,
    UnsupportedStatement,
    MissingResultName,
} || std.mem.Allocator.Error || std.json.ParseError(std.json.Scanner);

pub fn adapt(
    allocator: std.mem.Allocator,
    ast_json: []const u8,
    parameter_names: []const []const u8,
) Error!Query {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const storage = arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, storage, ast_json, .{});
    defer parsed.deinit();

    const statements = field(parsed.value, "stmts") orelse return error.InvalidAst;
    if (statements != .array or statements.array.items.len != 1)
        return error.MultipleStatements;
    const wrapper = field(statements.array.items[0], "stmt") orelse
        return error.InvalidAst;
    const statement, const kind: StatementKind = if (field(wrapper, "SelectStmt")) |node|
        .{ node, .select }
    else if (field(wrapper, "InsertStmt")) |node|
        .{ node, .insert }
    else if (field(wrapper, "UpdateStmt")) |node|
        .{ node, .update }
    else if (field(wrapper, "DeleteStmt")) |node|
        .{ node, .delete }
    else
        return error.UnsupportedStatement;

    var relations: std.ArrayList([]const u8) = .empty;
    var relation_bindings: std.ArrayList(Relation) = .empty;
    try collectRelations(storage, statement, &relations, &relation_bindings, false);

    var parameters: std.ArrayList([]const u8) = .empty;
    for (parameter_names) |name|
        try parameters.append(storage, try storage.dupe(u8, name));

    const target_list_name = if (kind == .select) "targetList" else "returningList";
    var result_columns: std.ArrayList([]const u8) = .empty;
    var projections: std.ArrayList(Projection) = .empty;
    if (field(statement, target_list_name)) |target_list| {
        if (target_list != .array) return error.InvalidAst;
        for (target_list.array.items) |target| {
            const result = field(target, "ResTarget") orelse return error.InvalidAst;
            const name = try resultName(result);
            const owned_name = try storage.dupe(u8, name);
            try result_columns.append(storage, owned_name);
            try projections.append(storage, .{
                .name = owned_name,
                .column = try columnReference(storage, result),
            });
        }
    }

    const mutation_target = if (kind == .select)
        null
    else blk: {
        const relation = field(statement, "relation") orelse return error.InvalidAst;
        const name = field(relation, "relname") orelse return error.InvalidAst;
        if (name != .string) return error.InvalidAst;
        break :blk try storage.dupe(u8, name.string);
    };
    if (mutation_target) |target| {
        if (!contains(relations.items, target)) {
            try relations.append(storage, try storage.dupe(u8, target));
            try relation_bindings.append(storage, .{
                .name = try storage.dupe(u8, target),
                .alias = null,
                .nullable = false,
            });
        }
    }

    return .{
        .arena = arena,
        .kind = kind,
        .mutation_target = mutation_target,
        .relations = try relations.toOwnedSlice(storage),
        .relation_bindings = try relation_bindings.toOwnedSlice(storage),
        .parameters = try parameters.toOwnedSlice(storage),
        .result_columns = try result_columns.toOwnedSlice(storage),
        .projections = try projections.toOwnedSlice(storage),
    };
}

fn collectRelations(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    relations: *std.ArrayList([]const u8),
    bindings: *std.ArrayList(Relation),
    nullable: bool,
) std.mem.Allocator.Error!void {
    switch (value) {
        .object => |object| {
            if (object.get("JoinExpr")) |join| {
                const kind = field(join, "jointype");
                const left_nullable = nullable or isJoinKind(kind, "JOIN_RIGHT") or
                    isJoinKind(kind, "JOIN_FULL");
                const right_nullable = nullable or isJoinKind(kind, "JOIN_LEFT") or
                    isJoinKind(kind, "JOIN_FULL");
                if (field(join, "larg")) |left|
                    try collectRelations(allocator, left, relations, bindings, left_nullable);
                if (field(join, "rarg")) |right|
                    try collectRelations(allocator, right, relations, bindings, right_nullable);
                if (field(join, "quals")) |quals|
                    try collectRelations(allocator, quals, relations, bindings, nullable);
                return;
            }
            if (object.get("RangeVar")) |range| {
                if (field(range, "relname")) |name| {
                    if (name == .string) {
                        if (!contains(relations.items, name.string))
                            try relations.append(allocator, try allocator.dupe(u8, name.string));
                        try bindings.append(allocator, .{
                            .name = try allocator.dupe(u8, name.string),
                            .alias = try relationAlias(allocator, range),
                            .nullable = nullable,
                        });
                    }
                }
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry|
                try collectRelations(allocator, entry.value_ptr.*, relations, bindings, nullable);
        },
        .array => |array| for (array.items) |item|
            try collectRelations(allocator, item, relations, bindings, nullable),
        else => {},
    }
}

fn isJoinKind(kind: ?std.json.Value, expected: []const u8) bool {
    const value = kind orelse return false;
    return value == .string and std.mem.eql(u8, value.string, expected);
}

fn relationAlias(allocator: std.mem.Allocator, range: std.json.Value) std.mem.Allocator.Error!?[]const u8 {
    const alias_value = field(range, "alias") orelse return null;
    const alias = field(alias_value, "Alias") orelse alias_value;
    const name = field(alias, "aliasname") orelse return null;
    if (name != .string) return null;
    return try allocator.dupe(u8, name.string);
}

fn columnReference(
    allocator: std.mem.Allocator,
    result: std.json.Value,
) Error!?ColumnReference {
    const expression = field(result, "val") orelse return error.InvalidAst;
    const column = field(expression, "ColumnRef") orelse return null;
    const fields = field(column, "fields") orelse return error.InvalidAst;
    if (fields != .array or fields.array.items.len == 0) return error.InvalidAst;
    const name = try stringField(fields.array.items[fields.array.items.len - 1]);
    const qualifier = if (fields.array.items.len >= 2)
        try allocator.dupe(u8, try stringField(fields.array.items[fields.array.items.len - 2]))
    else
        null;
    return .{
        .qualifier = qualifier,
        .name = try allocator.dupe(u8, name),
    };
}

fn stringField(value: std.json.Value) Error![]const u8 {
    const string_node = field(value, "String") orelse return error.InvalidAst;
    const name = field(string_node, "sval") orelse return error.InvalidAst;
    if (name != .string) return error.InvalidAst;
    return name.string;
}

fn resultName(result: std.json.Value) Error![]const u8 {
    if (field(result, "name")) |name| {
        if (name == .string) return name.string;
        return error.InvalidAst;
    }
    const expression = field(result, "val") orelse return error.InvalidAst;
    if (field(expression, "ColumnRef")) |column| {
        const fields = field(column, "fields") orelse return error.InvalidAst;
        if (fields != .array or fields.array.items.len == 0) return error.InvalidAst;
        const last = fields.array.items[fields.array.items.len - 1];
        if (field(last, "String")) |string_node| {
            const name = field(string_node, "sval") orelse return error.InvalidAst;
            if (name == .string) return name.string;
        }
        if (field(last, "A_Star") != null) return "*";
    }
    if (field(expression, "FuncCall")) |call| {
        const names = field(call, "funcname") orelse return error.InvalidAst;
        if (names != .array or names.array.items.len == 0) return error.InvalidAst;
        const last = names.array.items[names.array.items.len - 1];
        const string_node = field(last, "String") orelse return error.InvalidAst;
        const name = field(string_node, "sval") orelse return error.InvalidAst;
        if (name == .string) return name.string;
    }
    return error.MissingResultName;
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}
