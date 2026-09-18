const std = @import("std");
const sqlz = @import("sqlz");
const postgres_config = @import("postgres_config");
const options = @import("postgres_test_options");

const allocator = std.testing.allocator;
const io = std.testing.io;
const prefix = "sqlz_live_";

const User = struct {
    id: i64,
    name: []const u8,
    active: bool,
    score: ?f64,
};

const TextRole = enum {
    member,
    admin,
    pub const sqlz_storage: sqlz.Storage = .text;
};

fn config() postgres_config.Config {
    return .{
        .host = options.host,
        .port = options.port,
        .database = options.database,
        .username = options.username,
        .password = options.password,
        .expected_major = options.expected_major,
    };
}

test "PostgreSQL server major matches the selected conformance target" {
    const selected = config();
    try selected.validate();
    var conn = try open();
    defer conn.deinit();
    var version = try unwrap(conn.fetchOne(
        struct { major: i32 },
        "SELECT current_setting('server_version_num')::integer / 10000 AS major",
        .{},
    ));
    defer version.deinit();
    try std.testing.expectEqual(@as(i32, @intCast(selected.expected_major)), version.row().major);
}

test "PostgreSQL executes all cardinalities and owned conversion" {
    var conn = try open();
    defer conn.deinit();
    try resetUsers(&conn);
    defer _ = conn.executeScript("DROP TABLE IF EXISTS " ++ prefix ++ "users");

    const inserted = try unwrap(conn.execute(
        "INSERT INTO " ++ prefix ++ "users(name, active, score) VALUES ($1, $2, $3)",
        .{ "Ada", true, @as(?f64, 9.5) },
    ));
    try std.testing.expectEqual(@as(?u64, 1), inserted.rows_affected);
    _ = try unwrap(conn.execute(
        "INSERT INTO " ++ prefix ++ "users(name, active, score) VALUES ($1, $2, $3)",
        .{ "Lin", false, @as(?f64, null) },
    ));

    var single = try unwrap(conn.fetchOne(
        User,
        "SELECT id, name, active, score FROM " ++ prefix ++ "users WHERE name=$1",
        .{"Ada"},
    ));
    var owned = try unwrap(single.toOwned(allocator));
    defer owned.deinit();
    single.deinit();
    try std.testing.expectEqualStrings("Ada", owned.row().name);
    try std.testing.expect(owned.row().active);

    const missing = try unwrap(conn.fetchOptional(
        User,
        "SELECT id, name, active, score FROM " ++ prefix ++ "users WHERE name=$1",
        .{"missing"},
    ));
    try std.testing.expect(missing == null);

    var rows = try unwrap(conn.fetch(
        User,
        "SELECT id, name, active, score FROM " ++ prefix ++ "users ORDER BY id",
        .{},
    ));
    defer rows.deinit();
    var collected = try unwrap(rows.collectOwned(allocator));
    defer collected.deinit();
    try std.testing.expectEqual(@as(usize, 2), collected.items.len);
    try std.testing.expectEqualStrings("Lin", collected.items[1].name);
    try std.testing.expectEqual(@as(?f64, null), collected.items[1].score);
}

test "PostgreSQL transactions commit and roll back" {
    var conn = try open();
    defer conn.deinit();
    try unwrap(conn.executeScript(
        "DROP TABLE IF EXISTS " ++ prefix ++ "transactions;" ++
            "CREATE TABLE " ++ prefix ++ "transactions(value BIGINT NOT NULL);",
    ));
    defer _ = conn.executeScript("DROP TABLE IF EXISTS " ++ prefix ++ "transactions");

    {
        var tx = try unwrap(conn.begin(.{}));
        defer tx.deinit();
        _ = try unwrap(tx.execute("INSERT INTO " ++ prefix ++ "transactions(value) VALUES ($1)", .{@as(i64, 10)}));
        try unwrap(tx.commit());
    }
    {
        var tx = try unwrap(conn.begin(.{}));
        defer tx.deinit();
        _ = try unwrap(tx.execute("INSERT INTO " ++ prefix ++ "transactions(value) VALUES ($1)", .{@as(i64, 20)}));
        try unwrap(tx.rollback());
    }
    {
        var tx = try unwrap(conn.begin(.{}));
        defer tx.deinit();
        _ = try unwrap(tx.execute("INSERT INTO " ++ prefix ++ "transactions(value) VALUES ($1)", .{@as(i64, 30)}));
    }

    var count = try unwrap(conn.fetchOne(
        struct { count: i64 },
        "SELECT count(*)::bigint AS count FROM " ++ prefix ++ "transactions",
        .{},
    ));
    defer count.deinit();
    try std.testing.expectEqual(@as(i64, 1), count.row().count);
}

test "PostgreSQL arrays preserve null arrays and nullable elements" {
    var conn = try open();
    defer conn.deinit();
    const Row = struct {
        ids: []const ?i32,
        flags: ?[]const ?bool,
        labels: []const ?[]const u8,
    };
    var row = try unwrap(conn.fetchOne(
        Row,
        "SELECT $1::integer[] AS ids, $2::boolean[] AS flags, $3::text[] AS labels",
        .{
            @as([]const ?i32, &.{ 1, null, 3 }),
            @as(?[]const ?bool, null),
            @as([]const ?[]const u8, &.{ "a", null, "c" }),
        },
    ));
    defer row.deinit();
    try std.testing.expectEqual(@as(?i32, 1), row.row().ids[0]);
    try std.testing.expect(row.row().ids[1] == null);
    try std.testing.expect(row.row().flags == null);
    try std.testing.expectEqualStrings("c", row.row().labels[2].?);
}

test "PostgreSQL enums domains and SQLSTATE errors cross the live adapter" {
    var conn = try open();
    defer conn.deinit();
    try unwrap(conn.executeScript(
        "DROP TABLE IF EXISTS " ++ prefix ++ "typed;" ++
            "DROP TYPE IF EXISTS " ++ prefix ++ "role;" ++
            "DROP DOMAIN IF EXISTS " ++ prefix ++ "user_id;" ++
            "CREATE TYPE " ++ prefix ++ "role AS ENUM ('member', 'admin');" ++
            "CREATE DOMAIN " ++ prefix ++ "user_id AS BIGINT CHECK (VALUE > 0);" ++
            "CREATE TABLE " ++ prefix ++ "typed(" ++
            "id " ++ prefix ++ "user_id PRIMARY KEY," ++
            "role " ++ prefix ++ "role NOT NULL UNIQUE);",
    ));
    defer _ = conn.executeScript(
        "DROP TABLE IF EXISTS " ++ prefix ++ "typed;" ++
            "DROP TYPE IF EXISTS " ++ prefix ++ "role;" ++
            "DROP DOMAIN IF EXISTS " ++ prefix ++ "user_id;",
    );

    try unwrap(conn.executeScript(
        "INSERT INTO " ++ prefix ++ "typed(id, role) VALUES (1, 'member')",
    ));
    var typed = try unwrap(conn.fetchOne(
        struct { id: i64, role: TextRole },
        "SELECT id, role FROM " ++ prefix ++ "typed WHERE id=$1",
        .{@as(i64, 1)},
    ));
    defer typed.deinit();
    try std.testing.expectEqual(@as(i64, 1), typed.row().id);
    try std.testing.expectEqual(TextRole.member, typed.row().role);

    switch (conn.fetchOne(
        struct { id: i64 },
        "INSERT INTO " ++ prefix ++ "typed(id, role) VALUES ($1::bigint::" ++ prefix ++ "user_id, 'member') RETURNING id",
        .{@as(i64, 2)},
    )) {
        .ok => return error.ExpectedConstraintError,
        .err => |*err| {
            defer err.deinit();
            // pg.zig currently clears some server payloads while recovering the
            // connection, so the wrapper can only promise a safe owned error here.
            try std.testing.expect(err.class == .constraint or err.class == .other);
            try std.testing.expect(err.message.len != 0);
        },
    }
}

test "PostgreSQL pool drains early results and reuses its checkout" {
    const selected = config();
    var pool = try sqlz.postgres.Pool.init(allocator, io, .{
        .size = 1,
        .connect = .{ .host = selected.host, .port = selected.port },
        .auth = .{
            .username = selected.username,
            .password = selected.password,
            .database = selected.database,
        },
    });
    defer pool.deinit();

    var rows = try unwrap(pool.fetch(
        struct { value: i32 },
        "SELECT value FROM generate_series(1, 4) AS value",
        .{},
    ));
    try std.testing.expectEqual(@as(i32, 1), (try unwrap(rows.next())).?.value);
    try unwrap(rows.drain());
    rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().available);

    var single = try unwrap(pool.fetchOne(
        struct { value: i32 },
        "SELECT 7::integer AS value",
        .{},
    ));
    defer single.deinit();
    try std.testing.expectEqual(@as(i32, 7), single.row().value);
}

fn open() !sqlz.postgres.Conn {
    const selected = config();
    try selected.validate();
    return sqlz.postgres.open(allocator, io, .{
        .connect = .{ .host = selected.host, .port = selected.port },
        .auth = .{
            .username = selected.username,
            .password = selected.password,
            .database = selected.database,
        },
    });
}

fn resetUsers(conn: *sqlz.postgres.Conn) !void {
    try unwrap(conn.executeScript(
        "DROP TABLE IF EXISTS " ++ prefix ++ "users;" ++
            "CREATE TABLE " ++ prefix ++ "users(" ++
            "id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY," ++
            "name TEXT NOT NULL UNIQUE," ++
            "active BOOLEAN NOT NULL," ++
            "score DOUBLE PRECISION);",
    ));
}

fn unwrap(result: anytype) !@TypeOf(result.ok) {
    return switch (result) {
        .ok => |value| value,
        .err => |*err| {
            std.debug.print("PostgreSQL integration error ({s}): {s}\n", .{ @tagName(err.class), err.message });
            defer err.deinit();
            return error.SqlzFailure;
        },
    };
}
