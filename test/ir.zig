const std = @import("std");
const parser = @import("sqlz_parser");
const ir = @import("sqlz_ir");

test "adapts a joined SELECT into stable checker IR" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "SELECT u.name, p.label AS profile_label " ++
            "FROM users u LEFT JOIN profiles p ON p.user_id=u.id " ++
            "WHERE u.id=:id",
    );
    defer parsed.deinit();
    var query = try ir.adapt(
        std.testing.allocator,
        parsed.tree,
        parsed.rewritten.names,
    );
    defer query.deinit();

    try std.testing.expectEqual(ir.StatementKind.select, query.kind);
    try std.testing.expect(query.mutation_target == null);
    try expectStrings(&.{ "users", "profiles" }, query.relations);
    try expectStrings(&.{"id"}, query.parameters);
    try expectStrings(&.{ "name", "profile_label" }, query.result_columns);
    try std.testing.expectEqualStrings("u", query.relation_bindings[0].alias.?);
    try std.testing.expectEqualStrings("p", query.relation_bindings[1].alias.?);
    try std.testing.expect(!query.relation_bindings[0].nullable);
    try std.testing.expect(query.relation_bindings[1].nullable);
    try std.testing.expectEqualStrings("u", query.projections[0].column.?.qualifier.?);
    try std.testing.expectEqualStrings("name", query.projections[0].column.?.name);
}

fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_value, actual_value|
        try std.testing.expectEqualStrings(expected_value, actual_value);
}

test "adapts INSERT UPDATE and DELETE targets" {
    const cases = [_]struct {
        sql: []const u8,
        kind: ir.StatementKind,
        target: []const u8,
    }{
        .{
            .sql = "INSERT INTO users(name) VALUES (:name) RETURNING id, name",
            .kind = .insert,
            .target = "users",
        },
        .{
            .sql = "UPDATE users SET name=:name WHERE id=:id",
            .kind = .update,
            .target = "users",
        },
        .{
            .sql = "DELETE FROM users WHERE id=:id",
            .kind = .delete,
            .target = "users",
        },
    };
    for (cases) |case| {
        var parsed = try parser.parse(std.testing.allocator, case.sql);
        defer parsed.deinit();
        var query = try ir.adapt(
            std.testing.allocator,
            parsed.tree,
            parsed.rewritten.names,
        );
        defer query.deinit();
        try std.testing.expectEqual(case.kind, query.kind);
        try std.testing.expectEqualStrings(case.target, query.mutation_target.?);
        try std.testing.expectEqualStrings(case.target, query.relations[0]);
    }
}

test "rejects multi-statement checked queries" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "SELECT id FROM users; SELECT id FROM profiles",
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.MultipleStatements,
        ir.adapt(std.testing.allocator, parsed.tree, parsed.rewritten.names),
    );
}

test "preserves set operand and parameter occurrence sources" {
    const sql = "SELECT id AS value FROM values_a UNION ALL SELECT label FROM values_a " ++
        "WHERE id=:value OR label=:value";
    var parsed = try parser.parse(std.testing.allocator, sql);
    defer parsed.deinit();
    var query = try ir.adaptWithSource(
        std.testing.allocator,
        parsed.tree,
        parsed.rewritten.names,
        sql,
        parsed.rewritten.original_offsets,
    );
    defer query.deinit();

    try std.testing.expectEqual(@as(usize, 2), query.projections[0].set_operands.len);
    const first = query.projections[0].set_operands[0].type_source.?;
    const second = query.projections[0].set_operands[1].type_source.?;
    try std.testing.expectEqualStrings("id", sql[first.offset .. first.offset + first.length]);
    try std.testing.expectEqualStrings("label", sql[second.offset .. second.offset + second.length]);
    try std.testing.expectEqual(@as(usize, 2), query.parameter_uses[0].constraints.len);
    for (query.parameter_uses[0].constraints) |constraint| switch (constraint) {
        .column => |value| {
            const source = value.parameter_source.?;
            try std.testing.expectEqualStrings(":value", sql[source.offset .. source.offset + source.length]);
        },
        .integer => return error.TestUnexpectedResult,
    };
}
