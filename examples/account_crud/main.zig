const std = @import("std");
const sqlz = @import("sqlz");
const support = @import("example_support");

const User = struct { id: i64, name: []const u8 };
const create = sqlz.Query(.{
    .sql = "INSERT INTO users(name) VALUES (:name) RETURNING id, name",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct { name: []const u8 },
    .row = User,
});
const list = sqlz.Query(.{
    .sql = "SELECT id, name FROM users ORDER BY id",
    .backends = .{ .sqlite = true },
    .cardinality = .many,
    .row = User,
});

pub fn run(allocator: std.mem.Allocator) !void {
    var conn = try support.openMemory(allocator);
    defer conn.deinit();
    try conn.raw().execNoArgs("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL);");
    var inserted = try support.unwrap(create.fetchOne(&conn, .{ .name = "Ada" }));
    defer inserted.deinit();
    var rows = try support.unwrap(list.fetch(&conn, .{}));
    defer rows.deinit();
    const row = (try support.unwrap(rows.next())).?;
    if (row.id != 1 or !std.mem.eql(u8, row.name, "Ada")) return error.UnexpectedRow;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa);
}
