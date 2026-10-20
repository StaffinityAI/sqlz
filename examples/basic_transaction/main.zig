//! A transaction is an executor like the connection: the same query runs on
//! either. Nothing inside it is visible until `commit`, and `rollback` (or
//! `deinit` without a commit) discards it.

const std = @import("std");
const sqlz = @import("sqlz");

pub const insert_name = sqlz.Query(.{
    .sql = "INSERT INTO users(name) VALUES (:name)",
    .backends = .{ .sqlite = true, .postgres = true },
    .cardinality = .exec,
    .params = struct { name: []const u8 },
});

pub const total_users = sqlz.Query(.{
    .sql = "SELECT COUNT(*) AS total FROM users",
    .backends = .{ .sqlite = true, .postgres = true },
    .cardinality = .one,
    .row = struct { total: i64 },
});

pub fn run(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer) !void {
    var conn = try sqlz.sqlite.open(allocator, io, ":memory:", .{});
    defer conn.deinit();
    try sqlz.unwrap(conn.executeScript("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL);"));

    {
        var tx = try sqlz.unwrap(conn.begin(.{}));
        defer tx.deinit();
        _ = try sqlz.unwrap(insert_name.execute(&tx, .{ .name = "Ada" }));
        try sqlz.unwrap(tx.rollback());
    }
    try out.print("after rollback: {d} users\n", .{try countUsers(&conn)});

    {
        var tx = try sqlz.unwrap(conn.begin(.{}));
        defer tx.deinit();
        _ = try sqlz.unwrap(insert_name.execute(&tx, .{ .name = "Grace" }));
        try sqlz.unwrap(tx.commit());
    }
    try out.print("after commit: {d} users\n", .{try countUsers(&conn)});
}

fn countUsers(conn: *sqlz.sqlite.Conn) !i64 {
    var result = try sqlz.unwrap(total_users.fetchOne(conn, .{}));
    defer result.deinit();
    return result.row().total;
}

pub fn main(init: std.process.Init) !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try run(init.gpa, init.io, &stdout.interface);
    try stdout.interface.flush();
}
