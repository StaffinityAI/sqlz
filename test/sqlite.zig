const std = @import("std");
const sqlz = @import("sqlz");

const User = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
    active: bool,
};

const create_user = sqlz.Query(.{
    .sql = "INSERT INTO users(name, email, active) VALUES (:name, :email, :active) RETURNING id, name, email, active",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct { name: []const u8, email: []const u8, active: bool },
    .row = User,
});

const find_user = sqlz.Query(.{
    .sql = "SELECT id, name, email, active FROM users WHERE email=:email",
    .backends = .{ .sqlite = true },
    .cardinality = .optional,
    .params = struct { email: []const u8 },
    .row = User,
});

const must_find_user = sqlz.Query(.{
    .sql = "SELECT id, name, email, active FROM users WHERE email=:email",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct { email: []const u8 },
    .row = User,
});

const list_users = sqlz.Query(.{
    .sql = "SELECT id, name, email, active FROM users ORDER BY lower(name), id",
    .backends = .{ .sqlite = true },
    .cardinality = .many,
    .row = User,
});

const deactivate_user = sqlz.Query(.{
    .sql = "UPDATE users SET active=0 WHERE id=:id",
    .backends = .{ .sqlite = true },
    .cardinality = .exec,
    .params = struct { id: i64 },
});

const upsert_preference = sqlz.Query(.{
    .sql = "INSERT INTO preferences(user_id, theme, updated_at) VALUES (:user_id, :theme, :updated_at) " ++
        "ON CONFLICT(user_id) DO UPDATE SET theme=excluded.theme, updated_at=excluded.updated_at " ++
        "RETURNING user_id, theme, updated_at",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct { user_id: i64, theme: []const u8, updated_at: i64 },
    .row = struct { user_id: i64, theme: []const u8, updated_at: i64 },
});

const list_children = sqlz.Query(.{
    .sql = "WITH RECURSIVE descendants(id, depth) AS (" ++
        "SELECT id, 0 FROM nodes WHERE id=:root " ++
        "UNION ALL SELECT n.id, d.depth+1 FROM nodes n JOIN descendants d ON n.parent_id=d.id WHERE d.depth<:max_depth" ++
        ") SELECT id, depth FROM descendants ORDER BY depth, id",
    .backends = .{ .sqlite = true },
    .cardinality = .many,
    .params = struct { root: i64, max_depth: i64 },
    .row = struct { id: i64, depth: i64 },
});

const membership = sqlz.Query(.{
    .sql = "SELECT u.id, u.name, m.label FROM users u LEFT JOIN memberships m ON m.user_id=u.id " ++
        "WHERE u.id=:id",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct { id: i64 },
    .row = struct { id: i64, name: []const u8, label: ?[]const u8 },
});

test "all four cardinalities execute through SQLite" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, ":memory:");
    defer conn.deinit();
    try conn.raw().execNoArgs(
        "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, active INTEGER NOT NULL CHECK(active IN (0,1)));",
    );

    var inserted = try unwrap(create_user.fetchOne(&conn, .{ .name = "Ada", .email = "ada@example.test", .active = true }));
    defer inserted.deinit();
    try std.testing.expectEqualStrings("Ada", inserted.row().name);

    var found = (try unwrap(find_user.fetchOptional(&conn, .{ .email = "ada@example.test" }))).?;
    defer found.deinit();
    try std.testing.expect(found.row().active);

    const changed = try unwrap(deactivate_user.execute(&conn, .{ .id = inserted.row().id }));
    try std.testing.expectEqual(@as(?u64, 1), changed.rows_affected);

    var rows = try unwrap(list_users.fetch(&conn, .{}));
    defer rows.deinit();
    const first = (try unwrap(rows.next())).?;
    try std.testing.expect(!first.active);
    try std.testing.expect((try unwrap(rows.next())) == null);
}

test "optional and one preserve distinct empty-result behavior" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, ":memory:");
    defer conn.deinit();
    try conn.raw().execNoArgs(
        "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, active INTEGER NOT NULL);",
    );

    try std.testing.expect((try unwrap(find_user.fetchOptional(&conn, .{ .email = "missing@example.test" }))) == null);
    const result = must_find_user.fetchOne(&conn, .{ .email = "missing@example.test" });
    switch (result) {
        .ok => |value| {
            var single = value;
            single.deinit();
            return error.ExpectedConstraint;
        },
        .err => |*err| {
            defer err.deinit();
            try std.testing.expectEqual(sqlz.ErrorClass.invalid_data, err.class);
        },
    }
}

test "upsert returning exposes the winning row" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, ":memory:");
    defer conn.deinit();
    try conn.raw().execNoArgs(
        "CREATE TABLE preferences(user_id INTEGER PRIMARY KEY, theme TEXT NOT NULL, updated_at INTEGER NOT NULL);",
    );
    var first = try unwrap(upsert_preference.fetchOne(&conn, .{ .user_id = 7, .theme = "light", .updated_at = 1 }));
    first.deinit();
    var second = try unwrap(upsert_preference.fetchOne(&conn, .{ .user_id = 7, .theme = "dark", .updated_at = 2 }));
    defer second.deinit();
    try std.testing.expectEqualStrings("dark", second.row().theme);
    try std.testing.expectEqual(@as(i64, 2), second.row().updated_at);
}

test "left joins decode nullable fields and owned rows survive result cleanup" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, ":memory:");
    defer conn.deinit();
    try conn.raw().execNoArgs(
        "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, active INTEGER NOT NULL);" ++
            "CREATE TABLE memberships(user_id INTEGER PRIMARY KEY REFERENCES users(id), label TEXT);" ++
            "INSERT INTO users(id,name,email,active) VALUES(1,'Ada','ada@example.test',1);",
    );
    var single = try unwrap(membership.fetchOne(&conn, .{ .id = 1 }));
    var owned = try unwrap(single.toOwned(std.testing.allocator));
    single.deinit();
    defer owned.deinit();
    try std.testing.expectEqualStrings("Ada", owned.row().name);
    try std.testing.expectEqual(@as(?[]const u8, null), owned.row().label);
}

test "recursive CTE streams a bounded hierarchy" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, ":memory:");
    defer conn.deinit();
    try conn.raw().execNoArgs(
        "CREATE TABLE nodes(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES nodes(id));" ++
            "INSERT INTO nodes VALUES(1,NULL),(2,1),(3,2),(4,3);",
    );
    var rows = try unwrap(list_children.fetch(&conn, .{ .root = 1, .max_depth = 2 }));
    defer rows.deinit();
    var expected: i64 = 1;
    while (try unwrap(rows.next())) |row| : (expected += 1) try std.testing.expectEqual(expected, row.id);
    try std.testing.expectEqual(@as(i64, 4), expected);
}

test "transaction deinit rolls back and commit persists" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, ":memory:");
    defer conn.deinit();
    try conn.raw().execNoArgs("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, active INTEGER NOT NULL);");
    {
        var tx = try unwrap(conn.begin());
        defer tx.deinit();
        var inserted = try unwrap(create_user.fetchOne(&tx, .{ .name = "Ada", .email = "ada@example.test", .active = true }));
        inserted.deinit();
    }
    try std.testing.expect((try unwrap(find_user.fetchOptional(&conn, .{ .email = "ada@example.test" }))) == null);
    {
        var tx = try unwrap(conn.begin());
        defer tx.deinit();
        var inserted = try unwrap(create_user.fetchOne(&tx, .{ .name = "Ada", .email = "ada@example.test", .active = true }));
        inserted.deinit();
        try unwrap(tx.commit());
    }
    var found = (try unwrap(find_user.fetchOptional(&conn, .{ .email = "ada@example.test" }))).?;
    defer found.deinit();
}

fn unwrap(result: anytype) !@TypeOf(result.ok) {
    return switch (result) {
        .ok => |value| value,
        .err => |*err| {
            defer err.deinit();
            return error.SqlzFailure;
        },
    };
}
