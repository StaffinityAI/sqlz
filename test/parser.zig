const std = @import("std");
const parser = @import("sqlz_parser");

test "named parameters are rewritten once and retain first-use order" {
    var rewritten = try parser.rewriteSqlite(
        std.testing.allocator,
        "SELECT :identity = :identity, :other, ':ignored', \" :also_ignored\" -- :comment\n",
    );
    defer rewritten.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "SELECT ?1 = ?1, ?2, ':ignored', \" :also_ignored\" -- :comment\n",
        rewritten.sql,
    );
    try std.testing.expectEqual(@as(usize, 2), rewritten.names.len);
    try std.testing.expectEqualStrings("identity", rewritten.names[0]);
    try std.testing.expectEqualStrings("other", rewritten.names[1]);
    try std.testing.expectEqual(@as(usize, 7), rewritten.original_offsets[7]);
}

test "libpg_query parses shared SQL after portable parameter rewriting" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "WITH active AS (SELECT id FROM users WHERE tenant_id=:tenant) " ++
            "SELECT id FROM active WHERE id>:after OR :after IS NULL",
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "WITH active AS (SELECT id FROM users WHERE tenant_id=$1) " ++
            "SELECT id FROM active WHERE id>$2 OR $2 IS NULL",
        parsed.rewritten.sql,
    );
    try std.testing.expectEqual(@as(usize, 2), parsed.rewritten.names.len);
    try std.testing.expectEqualStrings("tenant", parsed.rewritten.names[0]);
    try std.testing.expectEqualStrings("after", parsed.rewritten.names[1]);
    try std.testing.expectEqual(@as(usize, 1), parsed.tree.n_stmts);
    const statement = parsed.tree.stmts[0].*.stmt;
    try std.testing.expectEqual(
        @as(c_uint, parser.ast.PG_QUERY__NODE__NODE_SELECT_STMT),
        statement.*.node_case,
    );
}

test "libpg_query covers returning and conflict queries used by SQLite examples" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "INSERT INTO preferences(user_id, theme) VALUES (:user_id, :theme) " ++
            "ON CONFLICT(user_id) DO UPDATE SET theme=excluded.theme " ++
            "RETURNING user_id, theme",
    );
    defer parsed.deinit();

    const statement = parsed.tree.stmts[0].*.stmt;
    try std.testing.expectEqual(
        @as(c_uint, parser.ast.PG_QUERY__NODE__NODE_INSERT_STMT),
        statement.*.node_case,
    );
    try std.testing.expect(statement.*.unnamed_0.insert_stmt.*.on_conflict_clause != null);
    try std.testing.expectEqual(@as(usize, 2), parsed.rewritten.names.len);
}

test "PostgreSQL casts are not mistaken for named parameters" {
    var rewritten = try parser.rewritePostgres(
        std.testing.allocator,
        "SELECT :value::text, ':ignored::cast'",
    );
    defer rewritten.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("SELECT $1::text, ':ignored::cast'", rewritten.sql);
    try std.testing.expectEqual(@as(usize, 1), rewritten.names.len);
    try std.testing.expectEqualStrings("value", rewritten.names[0]);
}

test "syntax diagnostics map libpg_query positions to the original SQL" {
    const source = "SELECT :identity FROM";
    const result = try parser.parseDetailed(std.testing.allocator, source);
    switch (result) {
        .ok => |value| {
            var parsed = value;
            parsed.deinit();
            return error.ExpectedSyntaxError;
        },
        .syntax_error => |value| {
            var diagnostic = value;
            defer diagnostic.deinit();
            try std.testing.expect(diagnostic.message.len > 0);
            try std.testing.expect(diagnostic.original_offset <= source.len);
            try std.testing.expect(diagnostic.rewritten_offset <= source.len);
        },
    }
}
