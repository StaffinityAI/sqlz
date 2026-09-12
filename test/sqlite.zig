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

fn unwrap(result: anytype) !@TypeOf(result.ok) {
    return switch (result) {
        .ok => |value| value,
        .err => |*err| {
            defer err.deinit();
            return error.SqlzFailure;
        },
    };
}
