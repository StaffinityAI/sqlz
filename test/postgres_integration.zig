const std = @import("std");
const sqlz = @import("sqlz");
const postgres_config = @import("postgres_config");
const options = @import("postgres_test_options");

const allocator = std.testing.allocator;
const io = std.testing.io;

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

const Fixture = struct {
    conn: sqlz.postgres.Conn,
    schema: [32]u8,
    schema_len: usize,

    fn init() !Fixture {
        var fixture: Fixture = .{
            .conn = try open(),
            .schema = undefined,
            .schema_len = 0,
        };
        errdefer fixture.conn.deinit();
        var random: [8]u8 = undefined;
        try io.randomSecure(&random);
        const name = try std.fmt.bufPrint(&fixture.schema, "sqlz_live_{x}", .{std.mem.readInt(u64, &random, .little)});
        fixture.schema_len = name.len;
        var sql: [80]u8 = undefined;
        try unwrap(fixture.conn.executeScript(try std.fmt.bufPrint(&sql, "CREATE SCHEMA {s}", .{name})));
        errdefer {
            const cleanup = std.fmt.bufPrint(&sql, "DROP SCHEMA IF EXISTS {s} CASCADE", .{name}) catch unreachable;
            _ = fixture.conn.executeScript(cleanup);
        }
        try unwrap(fixture.conn.executeScript(try std.fmt.bufPrint(&sql, "SET search_path TO {s}", .{name})));
        return fixture;
    }

    fn deinit(self: *Fixture) void {
        var sql: [80]u8 = undefined;
        const cleanup = std.fmt.bufPrint(&sql, "DROP SCHEMA IF EXISTS {s} CASCADE", .{self.schema[0..self.schema_len]}) catch unreachable;
        _ = self.conn.executeScript(cleanup);
        self.conn.deinit();
    }
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
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const conn = &fixture.conn;
    try resetUsers(conn);

    const inserted = try unwrap(conn.execute(
        "INSERT INTO users(name, active, score) VALUES ($1, $2, $3)",
        .{ "Ada", true, @as(?f64, 9.5) },
    ));
    try std.testing.expectEqual(@as(?u64, 1), inserted.rows_affected);
    _ = try unwrap(conn.execute(
        "INSERT INTO users(name, active, score) VALUES ($1, $2, $3)",
        .{ "Lin", false, @as(?f64, null) },
    ));

    var single = try unwrap(conn.fetchOne(
        User,
        "SELECT id, name, active, score FROM users WHERE name=$1",
        .{"Ada"},
    ));
    var owned = try unwrap(single.toOwned(allocator));
    defer owned.deinit();
    single.deinit();
    try std.testing.expectEqualStrings("Ada", owned.row().name);
    try std.testing.expect(owned.row().active);

    const missing = try unwrap(conn.fetchOptional(
        User,
        "SELECT id, name, active, score FROM users WHERE name=$1",
        .{"missing"},
    ));
    try std.testing.expect(missing == null);

    var rows = try unwrap(conn.fetch(
        User,
        "SELECT id, name, active, score FROM users ORDER BY id",
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
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const conn = &fixture.conn;
    try unwrap(conn.executeScript("CREATE TABLE transactions(value BIGINT NOT NULL)"));

    {
        var tx = try unwrap(conn.begin(.{}));
        defer tx.deinit();
        _ = try unwrap(tx.execute("INSERT INTO transactions(value) VALUES ($1)", .{@as(i64, 10)}));
        try unwrap(tx.commit());
    }
    {
        var tx = try unwrap(conn.begin(.{}));
        defer tx.deinit();
        _ = try unwrap(tx.execute("INSERT INTO transactions(value) VALUES ($1)", .{@as(i64, 20)}));
        try unwrap(tx.rollback());
    }
    {
        var tx = try unwrap(conn.begin(.{}));
        defer tx.deinit();
        _ = try unwrap(tx.execute("INSERT INTO transactions(value) VALUES ($1)", .{@as(i64, 30)}));
    }

    var count = try unwrap(conn.fetchOne(
        struct { count: i64 },
        "SELECT count(*)::bigint AS count FROM transactions",
        .{},
    ));
    defer count.deinit();
    try std.testing.expectEqual(@as(i64, 1), count.row().count);
}

test "PostgreSQL arrays preserve null arrays and nullable elements" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const Row = struct {
        ids: []const ?i32,
        flags: ?[]const ?bool,
        labels: []const ?[]const u8,
    };
    var row = try unwrap(fixture.conn.fetchOne(
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
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const conn = &fixture.conn;
    try unwrap(conn.executeScript(
        "CREATE TYPE role AS ENUM ('member', 'admin');" ++
            "CREATE DOMAIN user_id AS BIGINT CHECK (VALUE > 0);" ++
            "CREATE TABLE typed(" ++
            "id user_id PRIMARY KEY," ++
            "role role NOT NULL UNIQUE);",
    ));

    try unwrap(conn.executeScript("INSERT INTO typed(id, role) VALUES (1, 'member')"));
    var typed = try unwrap(conn.fetchOne(
        struct { id: i64, role: TextRole },
        "SELECT id, role FROM typed WHERE id=$1",
        .{@as(i64, 1)},
    ));
    try std.testing.expectEqual(@as(i64, 1), typed.row().id);
    try std.testing.expectEqual(TextRole.member, typed.row().role);
    typed.deinit();

    switch (conn.executeScript("INSERT INTO typed(id, role) VALUES (2, 'member')")) {
        .ok => return error.ExpectedConstraintError,
        .err => |*err| {
            defer err.deinit();
            try std.testing.expectEqual(sqlz.ErrorClass.constraint, err.class);
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
        "CREATE TABLE users(" ++
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
