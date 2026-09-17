//! Compatibility coverage for third-party `std.Io` implementations.
//!
//! sqlz never depends on a concrete runtime: connections are initialized with
//! whatever `std.Io` the application already runs on. These tests drive the
//! SQLite backend with an `std.Io` produced by zio's runtime, including from
//! inside a zio task, so the plumbing that the PostgreSQL backend will rely on
//! is exercised against a non-std implementation.

const std = @import("std");
const zio = @import("zio");
const sqlz = @import("sqlz");

const User = struct { id: i64, name: []const u8 };

const create_user = sqlz.Query(.{
    .sql = "INSERT INTO users(name) VALUES (:name) RETURNING id, name",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct { name: []const u8 },
    .row = User,
});

const list_users = sqlz.Query(.{
    .sql = "SELECT id, name FROM users ORDER BY id",
    .backends = .{ .sqlite = true },
    .cardinality = .many,
    .row = User,
});

fn unwrap(result: anytype) !@TypeOf(result.ok) {
    return switch (result) {
        .ok => |value| value,
        .err => |*err| {
            defer err.deinit();
            return error.SqlzQueryFailed;
        },
    };
}

fn workload(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try sqlz.sqlite.open(allocator, io, ":memory:", .{});
    defer conn.deinit();

    // The connection keeps exactly the implementation it was initialized with.
    try std.testing.expectEqual(io.userdata, conn.io.userdata);
    try std.testing.expectEqual(io.vtable, conn.io.vtable);

    try conn.raw().execNoArgs("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL);");

    {
        // Finalize the RETURNING statement before the transaction below: SQLite
        // refuses to commit while a statement is still in progress.
        var inserted = try unwrap(create_user.fetchOne(&conn, .{ .name = "Ada" }));
        defer inserted.deinit();
        try std.testing.expectEqual(@as(i64, 1), inserted.row().id);
    }

    {
        var tx = try unwrap(conn.begin());
        defer tx.deinit();
        try std.testing.expectEqual(io.vtable, tx.io().vtable);
        _ = try unwrap(tx.execute("INSERT INTO users(name) VALUES (:name)", .{"Grace"}));
        try unwrap(tx.commit());
    }

    var rows = try unwrap(list_users.fetch(&conn, .{}));
    defer rows.deinit();
    // A streaming cursor outlives the call that produced it, so it must carry
    // the interface itself.
    try std.testing.expectEqual(io.vtable, rows.io.vtable);
    var count: usize = 0;
    while (try unwrap(rows.next())) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "zio std.Io initializes sqlz connections" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    try workload(std.testing.allocator, runtime.io());
}

test "sqlz connections run inside zio tasks" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var task = try runtime.spawn(workload, .{ std.testing.allocator, runtime.io() });
    try task.join();
}

test "the retained std.Io stays usable for file system work" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/sqlz.db",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    var conn = try sqlz.sqlite.open(std.testing.allocator, runtime.io(), path, .{});
    defer conn.deinit();
    try conn.raw().execNoArgs("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL);");

    // Reach the file sqlite just created through the connection's own `std.Io`,
    // proving the stored interface is a live zio-backed implementation.
    const stat = try tmp.dir.statFile(conn.io, "sqlz.db", .{});
    try std.testing.expect(stat.size > 0);
}

fn poolWorkload(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var pool = try sqlz.sqlite.Pool.init(allocator, io, path, .{ .size = 2 });
    defer pool.deinit();

    // The pool acquires on the caller's runtime, so every handle it produces
    // must carry that same implementation.
    try std.testing.expectEqual(io.userdata, pool.io.userdata);
    try std.testing.expectEqual(io.vtable, pool.io.vtable);

    {
        var conn = try pool.acquire();
        defer conn.deinit();
        try std.testing.expectEqual(io.vtable, conn.io.vtable);
        try conn.raw().execNoArgs(
            "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL);" ++
                "INSERT INTO users(id,name) VALUES(1,'Ada'),(2,'Grace');",
        );
    }

    var rows = try unwrap(list_users.fetch(&pool, .{}));
    defer rows.deinit();
    try std.testing.expectEqual(io.vtable, rows.io.vtable);
    var count: usize = 0;
    while (try unwrap(rows.next())) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "pooled handles keep the caller's std.Io" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/pool.db",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    var task = try runtime.spawn(poolWorkload, .{ std.testing.allocator, runtime.io(), path });
    try task.join();
}
