const std = @import("std");
const sqlz = @import("sqlz");
const support = @import("example_support");

const save = sqlz.Query(.{
    .sql = "INSERT INTO preferences(user_id, value) VALUES (:user_id, :value) ON CONFLICT(user_id) DO UPDATE SET value=excluded.value RETURNING user_id, value",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct { user_id: i64, value: []const u8 },
    .row = struct { user_id: i64, value: []const u8 },
});

pub fn run(allocator: std.mem.Allocator) !void {
    var conn = try support.openMemory(allocator);
    defer conn.deinit();
    try conn.raw().execNoArgs("CREATE TABLE preferences(user_id INTEGER PRIMARY KEY, value TEXT NOT NULL);");
    var first = try support.unwrap(save.fetchOne(&conn, .{ .user_id = 1, .value = "light" }));
    first.deinit();
    var second = try support.unwrap(save.fetchOne(&conn, .{ .user_id = 1, .value = "dark" }));
    defer second.deinit();
    if (!std.mem.eql(u8, second.row().value, "dark")) return error.UnexpectedRow;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa);
}
