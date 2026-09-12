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
        parsed.ast_json,
        parsed.rewritten.names,
    );
    defer query.deinit();

    try std.testing.expectEqual(ir.StatementKind.select, query.kind);
    try std.testing.expect(query.mutation_target == null);
    try expectStrings(&.{ "users", "profiles" }, query.relations);
    try expectStrings(&.{"id"}, query.parameters);
    try expectStrings(&.{ "name", "profile_label" }, query.result_columns);
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
            parsed.ast_json,
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
        ir.adapt(std.testing.allocator, parsed.ast_json, parsed.rewritten.names),
    );
}
