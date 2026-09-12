const std = @import("std");
const pg = @import("libpg_query");

pub const StatementKind = enum { select, insert, update, delete };
pub const Relation = struct { name: []const u8, alias: ?[]const u8, nullable: bool };
pub const ColumnReference = struct { qualifier: ?[]const u8, name: []const u8 };
pub const TypeHint = enum { integer, real, text, blob, boolean };
pub const ExpressionHint = struct { scalar_type: TypeHint, nullable: bool };
pub const SetOperand = struct {
    column: ?ColumnReference,
    hint: ?ExpressionHint,
    bindings: []const Relation,
};
pub const Projection = struct {
    name: []const u8,
    column: ?ColumnReference,
    hint: ?ExpressionHint,
    set_operands: []const SetOperand = &.{},
};
pub const ParameterUse = struct {
    name: []const u8,
    columns: []const ColumnReference = &.{},
    integer_hint: bool = false,
};
pub const Cte = struct { name: []const u8, columns: []const Projection };

pub const Query = struct {
    arena: std.heap.ArenaAllocator,
    kind: StatementKind,
    mutation_target: ?[]const u8,
    relations: []const []const u8,
    relation_bindings: []const Relation,
    top_level_bindings: []const Relation,
    ctes: []const Cte,
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
} || std.mem.Allocator.Error;

const Context = struct {
    allocator: std.mem.Allocator,
    uses: []ParameterUse,
    constraints: []std.ArrayList(ColumnReference),
    relations: std.ArrayList([]const u8) = .empty,
    bindings: std.ArrayList(Relation) = .empty,
    top_bindings: std.ArrayList(Relation) = .empty,
    ctes: std.ArrayList(Cte) = .empty,
    result_names: std.ArrayList([]const u8) = .empty,
    projections: std.ArrayList(Projection) = .empty,

    fn addRange(self: *Context, range_ptr: [*c]pg.PgQuery__RangeVar, nullable: bool, top: bool) Error!void {
        if (range_ptr == null) return error.InvalidAst;
        const name = cString(range_ptr.*.relname) orelse return error.InvalidAst;
        if (!contains(self.relations.items, name))
            try self.relations.append(self.allocator, try self.allocator.dupe(u8, name));
        const alias = if (range_ptr.*.alias != null)
            try self.allocator.dupe(u8, cString(range_ptr.*.alias.*.aliasname) orelse return error.InvalidAst)
        else
            null;
        try self.bindings.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .alias = alias,
            .nullable = nullable,
        });
        if (top) try self.top_bindings.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .alias = if (alias) |value| try self.allocator.dupe(u8, value) else null,
            .nullable = nullable,
        });
    }
};

pub fn adapt(
    allocator: std.mem.Allocator,
    tree: *const pg.PgQuery__ParseResult,
    parameter_names: []const []const u8,
) Error!Query {
    if (tree.n_stmts != 1) return error.MultipleStatements;
    const raw = tree.stmts[0];
    if (raw == null or raw.*.stmt == null) return error.InvalidAst;
    const statement = raw.*.stmt;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const storage = arena.allocator();
    const uses = try storage.alloc(ParameterUse, parameter_names.len);
    const constraints = try storage.alloc(std.ArrayList(ColumnReference), parameter_names.len);
    @memset(constraints, .empty);
    var parameters: std.ArrayList([]const u8) = .empty;
    for (parameter_names, uses) |name, *use| {
        const owned = try storage.dupe(u8, name);
        try parameters.append(storage, owned);
        use.* = .{ .name = owned };
    }
    var context: Context = .{ .allocator = storage, .uses = uses, .constraints = constraints };

    const kind, const mutation_target = switch (statement.*.node_case) {
        pg.PG_QUERY__NODE__NODE_SELECT_STMT => result: {
            try collectSelect(&context, statement.*.unnamed_0.select_stmt, true, true);
            break :result .{ StatementKind.select, @as(?[]const u8, null) };
        },
        pg.PG_QUERY__NODE__NODE_INSERT_STMT => result: {
            const stmt = statement.*.unnamed_0.insert_stmt;
            try collectInsert(&context, stmt);
            break :result .{ StatementKind.insert, try mutationName(storage, stmt.*.relation) };
        },
        pg.PG_QUERY__NODE__NODE_UPDATE_STMT => result: {
            const stmt = statement.*.unnamed_0.update_stmt;
            try collectUpdate(&context, stmt);
            break :result .{ StatementKind.update, try mutationName(storage, stmt.*.relation) };
        },
        pg.PG_QUERY__NODE__NODE_DELETE_STMT => result: {
            const stmt = statement.*.unnamed_0.delete_stmt;
            try collectDelete(&context, stmt);
            break :result .{ StatementKind.delete, try mutationName(storage, stmt.*.relation) };
        },
        else => return error.UnsupportedStatement,
    };
    for (uses, constraints) |*use, *constraint_list|
        use.columns = try constraint_list.toOwnedSlice(storage);
    return .{
        .arena = arena,
        .kind = kind,
        .mutation_target = mutation_target,
        .relations = try context.relations.toOwnedSlice(storage),
        .relation_bindings = try context.bindings.toOwnedSlice(storage),
        .top_level_bindings = try context.top_bindings.toOwnedSlice(storage),
        .ctes = try context.ctes.toOwnedSlice(storage),
        .parameters = try parameters.toOwnedSlice(storage),
        .parameter_uses = uses,
        .result_columns = try context.result_names.toOwnedSlice(storage),
        .projections = try context.projections.toOwnedSlice(storage),
    };
}

fn collectSelect(ctx: *Context, pointer: [*c]pg.PgQuery__SelectStmt, top: bool, results: bool) Error!void {
    if (pointer == null) return error.InvalidAst;
    const stmt = pointer.*;
    if (stmt.with_clause != null) try collectCtes(ctx, stmt.with_clause);
    if (stmt.op != pg.PG_QUERY__SET_OPERATION__SETOP_NONE) {
        if (results) {
            try collectSetProjections(ctx, pointer);
        } else {
            if (stmt.larg == null or stmt.rarg == null) return error.InvalidAst;
            try collectSelect(ctx, stmt.larg, false, false);
            try collectSelect(ctx, stmt.rarg, false, false);
        }
        try markIntegerParameter(ctx, stmt.limit_count);
        try markIntegerParameter(ctx, stmt.limit_offset);
        return;
    }
    for (nodeSlice(stmt.from_clause, stmt.n_from_clause)) |node| try collectFrom(ctx, node, false, top);
    if (results) try collectProjections(ctx, nodeSlice(stmt.target_list, stmt.n_target_list));
    for (nodeSlice(stmt.target_list, stmt.n_target_list)) |node|
        try walkExpression(ctx, (resTarget(node) orelse return error.InvalidAst).val);
    try walkExpression(ctx, stmt.where_clause);
    try walkExpression(ctx, stmt.having_clause);
    try markIntegerParameter(ctx, stmt.limit_count);
    try markIntegerParameter(ctx, stmt.limit_offset);
    if (stmt.larg != null) try collectSelect(ctx, stmt.larg, false, false);
    if (stmt.rarg != null) try collectSelect(ctx, stmt.rarg, false, false);
}

const SetBranch = struct {
    targets: []const [*c]pg.PgQuery__Node,
    bindings: []const Relation,
};

fn collectSetProjections(ctx: *Context, pointer: [*c]pg.PgQuery__SelectStmt) Error!void {
    var branches: std.ArrayList(SetBranch) = .empty;
    try collectSetBranches(ctx, pointer, &branches);
    if (branches.items.len == 0) return error.InvalidAst;
    const column_count = branches.items[0].targets.len;
    for (branches.items[1..]) |branch|
        if (branch.targets.len != column_count) return error.InvalidAst;

    for (0..column_count) |column_index| {
        const first = resTarget(branches.items[0].targets[column_index]) orelse return error.InvalidAst;
        const owned_name = try ctx.allocator.dupe(u8, try resultName(first));
        const operands = try ctx.allocator.alloc(SetOperand, branches.items.len);
        for (branches.items, operands) |branch, *operand| {
            const target = resTarget(branch.targets[column_index]) orelse return error.InvalidAst;
            operand.* = .{
                .column = try columnReference(ctx.allocator, target.val),
                .hint = try inferExpression(target.val),
                .bindings = branch.bindings,
            };
        }
        try ctx.result_names.append(ctx.allocator, owned_name);
        try ctx.projections.append(ctx.allocator, .{
            .name = owned_name,
            .column = operands[0].column,
            .hint = operands[0].hint,
            .set_operands = operands,
        });
    }
}

fn collectSetBranches(
    ctx: *Context,
    pointer: [*c]pg.PgQuery__SelectStmt,
    branches: *std.ArrayList(SetBranch),
) Error!void {
    if (pointer == null) return error.InvalidAst;
    const stmt = pointer.*;
    if (stmt.op != pg.PG_QUERY__SET_OPERATION__SETOP_NONE) {
        if (stmt.larg == null or stmt.rarg == null) return error.InvalidAst;
        try collectSetBranches(ctx, stmt.larg, branches);
        try collectSetBranches(ctx, stmt.rarg, branches);
        return;
    }
    const binding_start = ctx.top_bindings.items.len;
    try collectSelect(ctx, pointer, true, false);
    try branches.append(ctx.allocator, .{
        .targets = nodeSlice(stmt.target_list, stmt.n_target_list),
        .bindings = try ctx.allocator.dupe(Relation, ctx.top_bindings.items[binding_start..]),
    });
}

fn collectInsert(ctx: *Context, pointer: [*c]pg.PgQuery__InsertStmt) Error!void {
    if (pointer == null or pointer.*.relation == null) return error.InvalidAst;
    try ctx.addRange(pointer.*.relation, false, true);
    if (pointer.*.select_stmt != null and pointer.*.select_stmt.*.node_case == pg.PG_QUERY__NODE__NODE_SELECT_STMT) {
        const select = pointer.*.select_stmt.*.unnamed_0.select_stmt;
        try bindInsertParameters(ctx, pointer, select);
        try collectSelect(ctx, select, false, false);
    }
    try collectReturning(ctx, pointer.*.returning_clause);
}

fn collectUpdate(ctx: *Context, pointer: [*c]pg.PgQuery__UpdateStmt) Error!void {
    if (pointer == null or pointer.*.relation == null) return error.InvalidAst;
    try ctx.addRange(pointer.*.relation, false, true);
    for (nodeSlice(pointer.*.from_clause, pointer.*.n_from_clause)) |node| try collectFrom(ctx, node, false, true);
    const table = cString(pointer.*.relation.*.relname) orelse return error.InvalidAst;
    for (nodeSlice(pointer.*.target_list, pointer.*.n_target_list)) |node| {
        const target = resTarget(node) orelse return error.InvalidAst;
        try bindParameter(ctx, target.val, .{
            .qualifier = table,
            .name = cString(target.name) orelse return error.InvalidAst,
        });
        try walkExpression(ctx, target.val);
    }
    try walkExpression(ctx, pointer.*.where_clause);
    try collectReturning(ctx, pointer.*.returning_clause);
}

fn collectDelete(ctx: *Context, pointer: [*c]pg.PgQuery__DeleteStmt) Error!void {
    if (pointer == null or pointer.*.relation == null) return error.InvalidAst;
    try ctx.addRange(pointer.*.relation, false, true);
    for (nodeSlice(pointer.*.using_clause, pointer.*.n_using_clause)) |node| try collectFrom(ctx, node, false, true);
    try walkExpression(ctx, pointer.*.where_clause);
    try collectReturning(ctx, pointer.*.returning_clause);
}

fn collectReturning(ctx: *Context, clause: [*c]pg.PgQuery__ReturningClause) Error!void {
    if (clause == null) return;
    const expressions = nodeSlice(clause.*.exprs, clause.*.n_exprs);
    try collectProjections(ctx, expressions);
    for (expressions) |node| try walkExpression(ctx, (resTarget(node) orelse return error.InvalidAst).val);
}

fn collectProjections(ctx: *Context, values: []const [*c]pg.PgQuery__Node) Error!void {
    for (values) |node| {
        const target = resTarget(node) orelse return error.InvalidAst;
        const owned_name = try ctx.allocator.dupe(u8, try resultName(target));
        try ctx.result_names.append(ctx.allocator, owned_name);
        try ctx.projections.append(ctx.allocator, .{
            .name = owned_name,
            .column = try columnReference(ctx.allocator, target.val),
            .hint = try inferExpression(target.val),
        });
    }
}

fn collectCtes(ctx: *Context, clause: [*c]pg.PgQuery__WithClause) Error!void {
    for (nodeSlice(clause.*.ctes, clause.*.n_ctes)) |node| {
        if (node.*.node_case != pg.PG_QUERY__NODE__NODE_COMMON_TABLE_EXPR) return error.InvalidAst;
        const cte = node.*.unnamed_0.common_table_expr;
        if (cte == null or cte.*.ctequery == null or cte.*.ctequery.*.node_case != pg.PG_QUERY__NODE__NODE_SELECT_STMT)
            return error.InvalidAst;
        const query = cte.*.ctequery.*.unnamed_0.select_stmt;
        const base = if (query.*.larg != null) query.*.larg else query;
        const targets = nodeSlice(base.*.target_list, base.*.n_target_list);
        const aliases = nodeSlice(cte.*.aliascolnames, cte.*.n_aliascolnames);
        if (targets.len != aliases.len) return error.InvalidAst;
        const columns = try ctx.allocator.alloc(Projection, targets.len);
        for (targets, aliases, columns) |target_node, alias_node, *column| {
            const target = resTarget(target_node) orelse return error.InvalidAst;
            column.* = .{
                .name = try ctx.allocator.dupe(u8, nodeString(alias_node) orelse return error.InvalidAst),
                .column = try columnReference(ctx.allocator, target.val),
                .hint = try inferExpression(target.val),
            };
        }
        try ctx.ctes.append(ctx.allocator, .{
            .name = try ctx.allocator.dupe(u8, cString(cte.*.ctename) orelse return error.InvalidAst),
            .columns = columns,
        });
        try collectSelect(ctx, query, false, false);
    }
}

fn collectFrom(ctx: *Context, node: [*c]pg.PgQuery__Node, nullable: bool, top: bool) Error!void {
    if (node == null) return error.InvalidAst;
    switch (node.*.node_case) {
        pg.PG_QUERY__NODE__NODE_RANGE_VAR => try ctx.addRange(node.*.unnamed_0.range_var, nullable, top),
        pg.PG_QUERY__NODE__NODE_JOIN_EXPR => {
            const join = node.*.unnamed_0.join_expr;
            if (join == null) return error.InvalidAst;
            try collectFrom(ctx, join.*.larg, nullable or join.*.jointype == pg.PG_QUERY__JOIN_TYPE__JOIN_RIGHT or join.*.jointype == pg.PG_QUERY__JOIN_TYPE__JOIN_FULL, top);
            try collectFrom(ctx, join.*.rarg, nullable or join.*.jointype == pg.PG_QUERY__JOIN_TYPE__JOIN_LEFT or join.*.jointype == pg.PG_QUERY__JOIN_TYPE__JOIN_FULL, top);
            try walkExpression(ctx, join.*.quals);
        },
        else => return error.UnsupportedStatement,
    }
}

fn walkExpression(ctx: *Context, node: [*c]pg.PgQuery__Node) Error!void {
    if (node == null) return;
    switch (node.*.node_case) {
        pg.PG_QUERY__NODE__NODE_A_EXPR => {
            const expression = node.*.unnamed_0.a_expr;
            if (try columnReference(ctx.allocator, expression.*.lexpr)) |column| try bindParameter(ctx, expression.*.rexpr, column);
            if (try columnReference(ctx.allocator, expression.*.rexpr)) |column| try bindParameter(ctx, expression.*.lexpr, column);
            try walkExpression(ctx, expression.*.lexpr);
            try walkExpression(ctx, expression.*.rexpr);
        },
        pg.PG_QUERY__NODE__NODE_BOOL_EXPR => {
            const expression = node.*.unnamed_0.bool_expr;
            for (nodeSlice(expression.*.args, expression.*.n_args)) |arg| try walkExpression(ctx, arg);
        },
        pg.PG_QUERY__NODE__NODE_NULL_TEST => try walkExpression(ctx, node.*.unnamed_0.null_test.*.arg),
        pg.PG_QUERY__NODE__NODE_FUNC_CALL => {
            const call = node.*.unnamed_0.func_call;
            for (nodeSlice(call.*.args, call.*.n_args)) |arg| try walkExpression(ctx, arg);
            try walkExpression(ctx, call.*.agg_filter);
        },
        pg.PG_QUERY__NODE__NODE_TYPE_CAST => try walkExpression(ctx, node.*.unnamed_0.type_cast.*.arg),
        pg.PG_QUERY__NODE__NODE_SUB_LINK => {
            const link = node.*.unnamed_0.sub_link;
            try walkExpression(ctx, link.*.testexpr);
            if (link.*.subselect != null and link.*.subselect.*.node_case == pg.PG_QUERY__NODE__NODE_SELECT_STMT)
                try collectSelect(ctx, link.*.subselect.*.unnamed_0.select_stmt, false, false);
        },
        else => {},
    }
}

fn bindInsertParameters(ctx: *Context, insert: [*c]pg.PgQuery__InsertStmt, select: [*c]pg.PgQuery__SelectStmt) Error!void {
    const columns = nodeSlice(insert.*.cols, insert.*.n_cols);
    var expressions: []const [*c]pg.PgQuery__Node = &.{};
    if (select.*.n_values_lists > 0) {
        const list_node = select.*.values_lists[0];
        if (list_node.*.node_case != pg.PG_QUERY__NODE__NODE_LIST) return error.InvalidAst;
        expressions = nodeSlice(list_node.*.unnamed_0.list.*.items, list_node.*.unnamed_0.list.*.n_items);
    } else {
        expressions = nodeSlice(select.*.target_list, select.*.n_target_list);
    }
    const table = cString(insert.*.relation.*.relname) orelse return error.InvalidAst;
    const count = @min(columns.len, expressions.len);
    for (columns[0..count], expressions[0..count]) |column_node, expression_node| {
        const column = resTarget(column_node) orelse return error.InvalidAst;
        const expression = if (resTarget(expression_node)) |target| target.val else expression_node;
        try bindParameter(ctx, expression, .{
            .qualifier = table,
            .name = cString(column.name) orelse return error.InvalidAst,
        });
    }
}

fn bindParameter(ctx: *Context, node: [*c]pg.PgQuery__Node, column: ColumnReference) Error!void {
    const ordinal = parameterOrdinal(node) orelse return;
    if (ordinal == 0 or ordinal > ctx.uses.len) return error.InvalidAst;
    const owned: ColumnReference = .{
        .qualifier = if (column.qualifier) |value| try ctx.allocator.dupe(u8, value) else null,
        .name = try ctx.allocator.dupe(u8, column.name),
    };
    for (ctx.constraints[ordinal - 1].items) |existing| {
        if (std.meta.eql(existing, owned)) return;
    }
    try ctx.constraints[ordinal - 1].append(ctx.allocator, owned);
}

fn markIntegerParameter(ctx: *Context, node: [*c]pg.PgQuery__Node) Error!void {
    if (parameterOrdinal(node)) |ordinal| {
        if (ordinal == 0 or ordinal > ctx.uses.len) return error.InvalidAst;
        ctx.uses[ordinal - 1].integer_hint = true;
    }
    try walkExpression(ctx, node);
}

fn parameterOrdinal(node: [*c]pg.PgQuery__Node) ?usize {
    if (node == null or node.*.node_case != pg.PG_QUERY__NODE__NODE_PARAM_REF) return null;
    const number = node.*.unnamed_0.param_ref.*.number;
    return if (number > 0) @intCast(number) else null;
}

fn columnReference(allocator: std.mem.Allocator, node: [*c]pg.PgQuery__Node) Error!?ColumnReference {
    if (node == null or node.*.node_case != pg.PG_QUERY__NODE__NODE_COLUMN_REF) return null;
    const column = node.*.unnamed_0.column_ref;
    if (column == null or column.*.n_fields == 0) return error.InvalidAst;
    const fields = nodeSlice(column.*.fields, column.*.n_fields);
    return .{
        .qualifier = if (fields.len >= 2)
            try allocator.dupe(u8, nodeString(fields[fields.len - 2]) orelse return error.InvalidAst)
        else
            null,
        .name = try allocator.dupe(u8, nodeString(fields[fields.len - 1]) orelse return error.InvalidAst),
    };
}

fn inferExpression(node: [*c]pg.PgQuery__Node) Error!?ExpressionHint {
    if (node == null) return null;
    switch (node.*.node_case) {
        pg.PG_QUERY__NODE__NODE_A_CONST => return switch (node.*.unnamed_0.a_const.*.val_case) {
            pg.PG_QUERY__A__CONST__VAL_IVAL => .{ .scalar_type = .integer, .nullable = false },
            pg.PG_QUERY__A__CONST__VAL_FVAL => .{ .scalar_type = .real, .nullable = false },
            pg.PG_QUERY__A__CONST__VAL_BOOLVAL => .{ .scalar_type = .boolean, .nullable = false },
            pg.PG_QUERY__A__CONST__VAL_SVAL => .{ .scalar_type = .text, .nullable = false },
            else => null,
        },
        pg.PG_QUERY__NODE__NODE_FUNC_CALL => {
            const call = node.*.unnamed_0.func_call;
            if (call.*.n_funcname == 0) return null;
            const name = nodeString(call.*.funcname[call.*.n_funcname - 1]) orelse return null;
            if (std.ascii.eqlIgnoreCase(name, "count")) return .{ .scalar_type = .integer, .nullable = false };
            if (std.ascii.eqlIgnoreCase(name, "lower") or std.ascii.eqlIgnoreCase(name, "upper") or std.ascii.eqlIgnoreCase(name, "trim"))
                return .{ .scalar_type = .text, .nullable = true };
            return null;
        },
        pg.PG_QUERY__NODE__NODE_A_EXPR => {
            const expression = node.*.unnamed_0.a_expr;
            if (expression.*.n_name == 0) return null;
            const operator = nodeString(expression.*.name[expression.*.n_name - 1]) orelse return null;
            const left = try inferExpression(expression.*.lexpr);
            const right = try inferExpression(expression.*.rexpr);
            if (std.mem.eql(u8, operator, "=") or std.mem.eql(u8, operator, "<>") or
                std.mem.eql(u8, operator, "<") or std.mem.eql(u8, operator, ">") or
                std.mem.eql(u8, operator, "<=") or std.mem.eql(u8, operator, ">=") or
                std.ascii.eqlIgnoreCase(operator, "~~"))
                return .{
                    .scalar_type = .boolean,
                    .nullable = (left == null or left.?.nullable) or (right == null or right.?.nullable),
                };
            if (operator.len == 1 and std.mem.indexOfScalar(u8, "+-*/", operator[0]) != null and left != null and right != null)
                return .{
                    .scalar_type = if (left.?.scalar_type == .real or right.?.scalar_type == .real) .real else .integer,
                    .nullable = left.?.nullable or right.?.nullable,
                };
            return null;
        },
        pg.PG_QUERY__NODE__NODE_TYPE_CAST => {
            const cast = node.*.unnamed_0.type_cast;
            if (cast == null or cast.*.type_name == null) return null;
            const type_name = cast.*.type_name;
            if (type_name.*.n_names == 0) return null;
            const name = nodeString(type_name.*.names[type_name.*.n_names - 1]) orelse return null;
            const scalar_type: TypeHint = if (isAnyType(name, &.{ "int2", "int4", "int8", "integer", "smallint", "bigint" }))
                .integer
            else if (isAnyType(name, &.{ "float4", "float8", "numeric", "real" }))
                .real
            else if (isAnyType(name, &.{ "text", "varchar", "bpchar", "char", "name" }))
                .text
            else if (isAnyType(name, &.{ "bytea", "blob" }))
                .blob
            else if (isAnyType(name, &.{ "bool", "boolean" }))
                .boolean
            else
                return null;
            const inner = try inferExpression(cast.*.arg);
            return .{ .scalar_type = scalar_type, .nullable = if (inner) |hint| hint.nullable else true };
        },
        pg.PG_QUERY__NODE__NODE_SUB_LINK => {
            const subselect = node.*.unnamed_0.sub_link.*.subselect;
            if (subselect == null or subselect.*.node_case != pg.PG_QUERY__NODE__NODE_SELECT_STMT) return null;
            const select = subselect.*.unnamed_0.select_stmt;
            if (select.*.n_target_list != 1) return null;
            return inferExpression((resTarget(select.*.target_list[0]) orelse return null).val);
        },
        else => return null,
    }
}

fn resultName(target: *const pg.PgQuery__ResTarget) Error![]const u8 {
    if (cString(target.name)) |name| if (name.len != 0) return name;
    if (target.val != null and target.val.*.node_case == pg.PG_QUERY__NODE__NODE_COLUMN_REF) {
        const column = target.val.*.unnamed_0.column_ref;
        if (column.*.n_fields > 0)
            return nodeString(column.*.fields[column.*.n_fields - 1]) orelse error.MissingResultName;
    }
    if (target.val != null and target.val.*.node_case == pg.PG_QUERY__NODE__NODE_FUNC_CALL) {
        const call = target.val.*.unnamed_0.func_call;
        if (call.*.n_funcname > 0)
            return nodeString(call.*.funcname[call.*.n_funcname - 1]) orelse error.MissingResultName;
    }
    return error.MissingResultName;
}

fn mutationName(allocator: std.mem.Allocator, range: [*c]pg.PgQuery__RangeVar) Error![]const u8 {
    if (range == null) return error.InvalidAst;
    return allocator.dupe(u8, cString(range.*.relname) orelse return error.InvalidAst);
}
fn resTarget(node: [*c]pg.PgQuery__Node) ?*const pg.PgQuery__ResTarget {
    if (node == null or node.*.node_case != pg.PG_QUERY__NODE__NODE_RES_TARGET) return null;
    return node.*.unnamed_0.res_target;
}
fn nodeString(node: [*c]pg.PgQuery__Node) ?[]const u8 {
    if (node == null or node.*.node_case != pg.PG_QUERY__NODE__NODE_STRING) return null;
    return cString(node.*.unnamed_0.string.*.sval);
}
fn cString(value: [*c]u8) ?[]const u8 {
    return if (value == null) null else std.mem.span(value);
}
fn nodeSlice(pointer: [*c][*c]pg.PgQuery__Node, len: usize) []const [*c]pg.PgQuery__Node {
    return if (len == 0) &.{} else pointer[0..len];
}
fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

fn isAnyType(needle: []const u8, values: []const []const u8) bool {
    for (values) |value| if (std.ascii.eqlIgnoreCase(needle, value)) return true;
    return false;
}
