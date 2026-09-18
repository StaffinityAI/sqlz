const std = @import("std");
const sqlz = @import("sqlz");

const User = struct {
    id: i64,
    name: []const u8,
    active: bool,
};

test "PostgreSQL executes typed CRUD and streams rows" {
    var conn = try open();
    defer conn.deinit();

    try unwrap(conn.executeScript(
        "DROP TABLE IF EXISTS sqlz_integration_users;" ++
            "CREATE TABLE sqlz_integration_users(" ++
            "id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY," ++
            "name TEXT NOT NULL UNIQUE," ++
            "active BOOLEAN NOT NULL);",
    ));
    defer _ = conn.executeScript("DROP TABLE IF EXISTS sqlz_integration_users");

    const inserted = try unwrap(conn.execute(
        "INSERT INTO sqlz_integration_users(name, active) VALUES ($1, $2)",
        .{ "Ada", true },
    ));
    try std.testing.expectEqual(@as(?u64, 1), inserted.rows_affected);

    var single = try unwrap(conn.fetchOne(
        User,
        "SELECT id, name, active FROM sqlz_integration_users WHERE name=$1",
        .{"Ada"},
    ));
    try std.testing.expectEqualStrings("Ada", single.row().name);
    try std.testing.expect(single.row().active);
    single.deinit();

    var rows = try unwrap(conn.fetch(
        User,
        "SELECT id, name, active FROM sqlz_integration_users ORDER BY id",
        .{},
    ));
    defer rows.deinit();
    try std.testing.expect((try unwrap(rows.next())) != null);
    try std.testing.expect((try unwrap(rows.next())) == null);
}

test "PostgreSQL transaction rollback is observable" {
    var conn = try open();
    defer conn.deinit();

    try unwrap(conn.executeScript(
        "DROP TABLE IF EXISTS sqlz_integration_transactions;" ++
            "CREATE TABLE sqlz_integration_transactions(value BIGINT NOT NULL);",
    ));
    defer _ = conn.executeScript("DROP TABLE IF EXISTS sqlz_integration_transactions");

    {
        var tx = try unwrap(conn.begin(.{}));
        defer tx.deinit();
        _ = try unwrap(tx.execute("INSERT INTO sqlz_integration_transactions(value) VALUES ($1)", .{@as(i64, 42)}));
    }

    var count = try unwrap(conn.fetchOne(
        struct { count: i64 },
        "SELECT count(*)::bigint AS count FROM sqlz_integration_transactions",
        .{},
    ));
    defer count.deinit();
    try std.testing.expectEqual(@as(i64, 0), count.row().count);
}

fn open() !sqlz.postgres.Conn {
    return sqlz.postgres.open(std.testing.allocator, std.testing.io, .{
        .connect = .{ .host = "127.0.0.1", .port = 55432 },
        .auth = .{
            .username = "sqlz_test",
            .password = "sqlz_test",
            .database = "sqlz_test",
        },
    });
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
