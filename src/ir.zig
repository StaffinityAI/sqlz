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

pub const TypeHint = enum { integer, real, text, blob, boolean };

pub const ExpressionHint = struct {
    scalar_type: TypeHint,
    nullable: bool,
};

pub const Projection = struct {
    name: []const u8,
    column: ?ColumnReference,
    hint: ?ExpressionHint,
};

pub const ParameterUse = struct {
    name: []const u8,
    column: ?ColumnReference = null,
    integer_hint: bool = false,
};

pub const Query = struct {
    arena: std.heap.ArenaAllocator,
    kind: StatementKind,
    mutation_target: ?[]const u8,
    relations: []const []const u8,
    relation_bindings: []const Relation,
    parameters: []const []const u8,
    parameter_uses: []const ParameterUse,
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
    const parameter_uses = try storage.alloc(ParameterUse, parameter_names.len);
    for (parameter_names, parameter_uses) |name, *use| {
        const owned_name = try storage.dupe(u8, name);
        try parameters.append(storage, owned_name);
        use.* = .{ .name = owned_name };
    }
    try collectParameterUses(storage, statement, parameter_uses);
    try collectStatementParameterUses(storage, kind, statement, mutation_targetName(kind, statement), parameter_uses);

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
                .hint = try expressionHint(result),
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
        .parameter_uses = parameter_uses,
        .result_columns = try result_columns.toOwnedSlice(storage),
        .projections = try projections.toOwnedSlice(storage),
    };
}

fn expressionHint(result: std.json.Value) Error!?ExpressionHint {
    const expression = field(result, "val") orelse return error.InvalidAst;
    return inferExpression(expression);
}

fn inferExpression(expression: std.json.Value) Error!?ExpressionHint {
    if (field(expression, "ColumnRef") != null) return null;
    if (field(expression, "A_Const")) |constant| {
        if (field(constant, "ival") != null) return .{ .scalar_type = .integer, .nullable = false };
        if (field(constant, "fval") != null) return .{ .scalar_type = .real, .nullable = false };
        if (field(constant, "sval") != null) return .{ .scalar_type = .text, .nullable = false };
        if (field(constant, "boolval") != null) return .{ .scalar_type = .boolean, .nullable = false };
        return null;
    }
    if (field(expression, "FuncCall")) |call| {
        const names = field(call, "funcname") orelse return error.InvalidAst;
        if (names != .array or names.array.items.len == 0) return error.InvalidAst;
        const name = try stringField(names.array.items[names.array.items.len - 1]);
        if (std.ascii.eqlIgnoreCase(name, "count"))
            return .{ .scalar_type = .integer, .nullable = false };
        if (std.ascii.eqlIgnoreCase(name, "lower") or
            std.ascii.eqlIgnoreCase(name, "upper") or
            std.ascii.eqlIgnoreCase(name, "trim"))
            return .{ .scalar_type = .text, .nullable = true };
        return null;
    }
    if (field(expression, "A_Expr")) |binary| {
        const left_value = field(binary, "lexpr") orelse return null;
        const right_value = field(binary, "rexpr") orelse return null;
        const left = try inferExpression(left_value);
        const right = try inferExpression(right_value);
        const operator = expressionOperator(binary) orelse return null;
        if (std.mem.eql(u8, operator, "=") or std.mem.eql(u8, operator, "<>") or
            std.mem.eql(u8, operator, "<") or std.mem.eql(u8, operator, ">") or
            std.mem.eql(u8, operator, "<=") or std.mem.eql(u8, operator, ">=") or
            std.ascii.eqlIgnoreCase(operator, "~~"))
            return .{ .scalar_type = .boolean, .nullable = true };
        if (std.mem.eql(u8, operator, "+") or std.mem.eql(u8, operator, "-") or
            std.mem.eql(u8, operator, "*") or std.mem.eql(u8, operator, "/"))
        {
            if (left) |left_hint| {
                if (right) |right_hint| {
                    const scalar_type: TypeHint = if (left_hint.scalar_type == .real or
                        right_hint.scalar_type == .real) .real else .integer;
                    return .{
                        .scalar_type = scalar_type,
                        .nullable = left_hint.nullable or right_hint.nullable,
                    };
                }
            }
        }
        return null;
    }
    if (field(expression, "SubLink")) |link| {
        const select_value = field(link, "subselect") orelse return null;
        const select = field(select_value, "SelectStmt") orelse select_value;
        const targets = field(select, "targetList") orelse return null;
        if (targets != .array or targets.array.items.len != 1) return null;
        const target = field(targets.array.items[0], "ResTarget") orelse return null;
        const value = field(target, "val") orelse return null;
        return inferExpression(value);
    }
    if (field(expression, "TypeCast")) |cast| {
        const type_name = field(cast, "typeName") orelse return null;
        const names = field(type_name, "names") orelse return null;
        if (names != .array or names.array.items.len == 0) return null;
        const name = try stringField(names.array.items[names.array.items.len - 1]);
        if (std.ascii.eqlIgnoreCase(name, "int2") or
            std.ascii.eqlIgnoreCase(name, "int4") or
            std.ascii.eqlIgnoreCase(name, "int8") or
            std.ascii.eqlIgnoreCase(name, "integer"))
            return .{ .scalar_type = .integer, .nullable = true };
        if (std.ascii.eqlIgnoreCase(name, "text") or
            std.ascii.eqlIgnoreCase(name, "varchar"))
            return .{ .scalar_type = .text, .nullable = true };
    }
    return null;
}

fn expressionOperator(expression: std.json.Value) ?[]const u8 {
    const names = field(expression, "name") orelse return null;
    if (names != .array or names.array.items.len == 0) return null;
    return stringField(names.array.items[names.array.items.len - 1]) catch null;
}

fn collectStatementParameterUses(
    allocator: std.mem.Allocator,
    kind: StatementKind,
    statement: std.json.Value,
    target_name: ?[]const u8,
    uses: []ParameterUse,
) Error!void {
    if (kind == .update) {
        if (field(statement, "targetList")) |targets| {
            if (targets != .array) return error.InvalidAst;
            for (targets.array.items) |target| {
                const result = field(target, "ResTarget") orelse return error.InvalidAst;
                const name = field(result, "name") orelse return error.InvalidAst;
                const value = field(result, "val") orelse return error.InvalidAst;
                if (name != .string) return error.InvalidAst;
                try bindExpressionParameter(allocator, uses, value, .{
                    .qualifier = target_name,
                    .name = name.string,
                });
            }
        }
    } else if (kind == .insert) {
        try collectInsertParameterUses(allocator, statement, target_name, uses);
    }
    for ([_][]const u8{ "limitCount", "limitOffset" }) |field_name| {
        if (field(statement, field_name)) |value| {
            if (parameterOrdinal(value)) |ordinal| {
                if (ordinal > 0 and ordinal <= uses.len) uses[ordinal - 1].integer_hint = true;
            }
        }
    }
}

fn collectInsertParameterUses(
    allocator: std.mem.Allocator,
    statement: std.json.Value,
    target_name: ?[]const u8,
    uses: []ParameterUse,
) Error!void {
    const columns = field(statement, "cols") orelse return;
    const select_value = field(statement, "selectStmt") orelse return;
    if (columns != .array) return error.InvalidAst;
    const select = field(select_value, "SelectStmt") orelse select_value;
    var expressions: ?[]const std.json.Value = null;
    if (field(select, "valuesLists")) |lists| {
        if (lists != .array or lists.array.items.len == 0) return error.InvalidAst;
        const list = field(lists.array.items[0], "List") orelse return error.InvalidAst;
        const items = field(list, "items") orelse return error.InvalidAst;
        if (items != .array) return error.InvalidAst;
        expressions = items.array.items;
    } else if (field(select, "targetList")) |targets| {
        if (targets != .array) return error.InvalidAst;
        var values: std.ArrayList(std.json.Value) = .empty;
        for (targets.array.items) |target| {
            const result = field(target, "ResTarget") orelse return error.InvalidAst;
            try values.append(allocator, field(result, "val") orelse return error.InvalidAst);
        }
        expressions = try values.toOwnedSlice(allocator);
    }
    const values = expressions orelse return;
    for (columns.array.items, values) |column_value, expression| {
        const target = field(column_value, "ResTarget") orelse return error.InvalidAst;
        const name = field(target, "name") orelse return error.InvalidAst;
        if (name != .string) return error.InvalidAst;
        try bindExpressionParameter(allocator, uses, expression, .{
            .qualifier = target_name,
            .name = name.string,
        });
    }
}

fn collectParameterUses(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    uses: []ParameterUse,
) Error!void {
    switch (value) {
        .object => |object| {
            if (object.get("A_Expr")) |expression| {
                const left = field(expression, "lexpr");
                const right = field(expression, "rexpr");
                if (left != null and right != null) {
                    if (try expressionColumn(allocator, left.?)) |column|
                        try bindExpressionParameter(allocator, uses, right.?, column);
                    if (try expressionColumn(allocator, right.?)) |column|
                        try bindExpressionParameter(allocator, uses, left.?, column);
                }
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry|
                try collectParameterUses(allocator, entry.value_ptr.*, uses);
        },
        .array => |array| for (array.items) |item|
            try collectParameterUses(allocator, item, uses),
        else => {},
    }
}

fn bindExpressionParameter(
    allocator: std.mem.Allocator,
    uses: []ParameterUse,
    expression: std.json.Value,
    column: ColumnReference,
) Error!void {
    const ordinal = parameterOrdinal(expression) orelse return;
    if (ordinal == 0 or ordinal > uses.len) return error.InvalidAst;
    if (uses[ordinal - 1].column != null) return;
    uses[ordinal - 1].column = .{
        .qualifier = if (column.qualifier) |value| try allocator.dupe(u8, value) else null,
        .name = try allocator.dupe(u8, column.name),
    };
}

fn parameterOrdinal(expression: std.json.Value) ?usize {
    const parameter = field(expression, "ParamRef") orelse return null;
    const number = field(parameter, "number") orelse return null;
    if (number != .integer or number.integer <= 0) return null;
    return @intCast(number.integer);
}

fn expressionColumn(allocator: std.mem.Allocator, expression: std.json.Value) Error!?ColumnReference {
    const column = field(expression, "ColumnRef") orelse return null;
    const fields = field(column, "fields") orelse return error.InvalidAst;
    if (fields != .array or fields.array.items.len == 0) return error.InvalidAst;
    return .{
        .qualifier = if (fields.array.items.len >= 2)
            try allocator.dupe(u8, try stringField(fields.array.items[fields.array.items.len - 2]))
        else
            null,
        .name = try allocator.dupe(u8, try stringField(fields.array.items[fields.array.items.len - 1])),
    };
}

fn mutation_targetName(kind: StatementKind, statement: std.json.Value) ?[]const u8 {
    if (kind == .select) return null;
    const relation = field(statement, "relation") orelse return null;
    const name = field(relation, "relname") orelse return null;
    if (name != .string) return null;
    return name.string;
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
