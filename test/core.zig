const std = @import("std");
const sqlz = @import("sqlz");

test "named parameters are rewritten once and retain first-use order" {
    var rewritten = try sqlz.rewriteSqlite(
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
}

test "libpg_query parses shared SQL after portable parameter rewriting" {
    var parsed = try sqlz.parser.parse(
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
    try std.testing.expect(std.mem.indexOf(u8, parsed.ast_json, "SelectStmt") != null);
}

test "libpg_query covers returning and conflict queries used by SQLite examples" {
    var parsed = try sqlz.parser.parse(
        std.testing.allocator,
        "INSERT INTO preferences(user_id, theme) VALUES (:user_id, :theme) " ++
            "ON CONFLICT(user_id) DO UPDATE SET theme=excluded.theme " ++
            "RETURNING user_id, theme",
    );
    defer parsed.deinit();

    try std.testing.expect(std.mem.indexOf(u8, parsed.ast_json, "InsertStmt") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.ast_json, "onConflictClause") != null);
    try std.testing.expectEqual(@as(usize, 2), parsed.rewritten.names.len);
}

test "PostgreSQL casts are not mistaken for named parameters" {
    var rewritten = try sqlz.rewritePostgres(
        std.testing.allocator,
        "SELECT :value::text, ':ignored::cast'",
    );
    defer rewritten.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("SELECT $1::text, ':ignored::cast'", rewritten.sql);
    try std.testing.expectEqual(@as(usize, 1), rewritten.names.len);
    try std.testing.expectEqualStrings("value", rewritten.names[0]);
}

test "Query exposes the cardinality-selected method" {
    const insert_user = sqlz.Query(.{
        .sql = "INSERT INTO users(name) VALUES (:name)",
        .backends = .{ .sqlite = true },
        .cardinality = .exec,
        .params = struct { name: []const u8 },
    });
    try std.testing.expect(@hasDecl(insert_user, "execute"));
    try std.testing.expect(!@hasDecl(insert_user, "fetch"));
}

test "owned text rows release all duplicated fields" {
    const Row = struct { id: i64, name: []const u8, note: ?[]const u8 };
    const row: Row = .{ .id = 1, .name = "Ada", .note = "first" };
    var owned = try sqlz.cloneRow(std.testing.allocator, row);
    defer sqlz.deinitOwnedRow(std.testing.allocator, &owned);
    try std.testing.expectEqualStrings("Ada", owned.name);
    try std.testing.expectEqualStrings("first", owned.note.?);
}
