//! Queries declared next to the code that runs them. The checker finds every
//! `sqlz.Query` under the project's Zig roots and checks its SQL, parameters,
//! and row struct, so no `.sql` file or generated module is involved.

const std = @import("std");
const sqlz = @import("sqlz");

pub const insert_user = sqlz.Query(.{
    .sql = "INSERT INTO users(name) VALUES (:name)",
    .backends = .{ .sqlite = true, .postgres = true },
    .cardinality = .exec,
    .params = struct { name: []const u8 },
});

pub const list_users = sqlz.Query(.{
    .sql = "SELECT id, name FROM users ORDER BY id",
    .backends = .{ .sqlite = true, .postgres = true },
    .cardinality = .many,
    .row = struct { id: i64, name: []const u8 },
});

pub fn run(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer) !void {
    var conn = try sqlz.sqlite.open(allocator, io, ":memory:", .{});
    defer conn.deinit();
    try sqlz.unwrap(conn.executeScript("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL);"));

    for ([_][]const u8{ "Ada", "Grace", "Barbara" }) |name| {
        _ = try sqlz.unwrap(insert_user.execute(&conn, .{ .name = name }));
    }

    // Rows stream from the database. Each row borrows from the statement and
    // stays valid until the next call to `next`.
    var rows = try sqlz.unwrap(list_users.fetch(&conn, .{}));
    defer rows.deinit();
    while (try sqlz.unwrap(rows.next())) |user| {
        try out.print("user {d}: {s}\n", .{ user.id, user.name });
    }
}

pub fn main(init: std.process.Init) !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try run(init.gpa, init.io, &stdout.interface);
    try stdout.interface.flush();
}
