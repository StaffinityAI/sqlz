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

test "PostgreSQL profiles parse supported versions" {
    try std.testing.expectEqual(parser.PostgresProfile.v15, parser.PostgresProfile.fromString("15").?);
    try std.testing.expectEqual(parser.PostgresProfile.v18, parser.PostgresProfile.fromString("18").?);
    try std.testing.expect(parser.PostgresProfile.fromString("14") == null);

    var parsed = try parser.parsePostgresWithDialect(
        std.testing.allocator,
        "SELECT :value::text",
        .{ .profile = .v17 },
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("SELECT $1::text", parsed.rewritten.sql);
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

test "SQLite normalization accepts real-world conflict and table options" {
    var insert = try parser.parseSqlite(
        std.testing.allocator,
        "INSERT OR IGNORE INTO memberships(user_id) VALUES (:user_id)",
    );
    defer insert.deinit();
    try std.testing.expectEqual(
        @as(c_uint, parser.ast.PG_QUERY__NODE__NODE_INSERT_STMT),
        insert.tree.stmts[0].*.stmt.*.node_case,
    );
    try std.testing.expectEqualStrings("user_id", insert.rewritten.names[0]);

    var ddl = try parser.parseSqlite(
        std.testing.allocator,
        "CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT) STRICT;" ++
            "CREATE TABLE memberships (user_id INTEGER, role_id INTEGER, " ++
            "PRIMARY KEY (user_id, role_id)) WITHOUT ROWID",
    );
    defer ddl.deinit();
    try std.testing.expectEqual(@as(usize, 2), ddl.tree.n_stmts);

    var identifier = try parser.parseSqlite(std.testing.allocator, "SELECT strict FROM settings");
    defer identifier.deinit();
    try std.testing.expectEqual(@as(usize, 1), identifier.tree.n_stmts);
}

test "SQLite numeric separators are gated by the selected profile" {
    try std.testing.expectError(
        error.UnsupportedSqliteFeature,
        parser.parseSqliteWithDialect(
            std.testing.allocator,
            "SELECT 1_000 AS total",
            .{ .profile = .v3_45 },
        ),
    );

    var parsed = try parser.parseSqliteWithDialect(
        std.testing.allocator,
        "SELECT 1_000 AS total, '2_000' AS label -- 3_000\n",
        .{ .profile = .v3_46 },
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "SELECT 10000 AS total, '2_000' AS label -- 3_000\n",
        parsed.rewritten.sql,
    );
}

test "SQLite validation rejects PostgreSQL-only query clauses" {
    const unsupported = [_][]const u8{
        "SELECT id INTO archived_users FROM users",
        "SELECT id FROM users FOR UPDATE",
        "SELECT DISTINCT ON (name) name FROM users",
        "SELECT name::text FROM users",
        "SELECT name ILIKE 'a%' AS matches FROM users",
        "SELECT name SIMILAR TO 'a%' AS matches FROM users",
        "INSERT INTO users(id) OVERRIDING SYSTEM VALUE VALUES (1)",
        "DELETE FROM users USING archived_users WHERE users.id = archived_users.id",
    };
    for (unsupported) |source| {
        try std.testing.expectError(
            error.UnsupportedSqliteFeature,
            parser.parseSqlite(std.testing.allocator, source),
        );
    }

    var distinct = try parser.parseSqlite(
        std.testing.allocator,
        "SELECT DISTINCT name FROM users",
    );
    defer distinct.deinit();

    var quoted = try parser.parseSqlite(
        std.testing.allocator,
        "SELECT \"ilike\", 'value::text' FROM users",
    );
    defer quoted.deinit();
}
