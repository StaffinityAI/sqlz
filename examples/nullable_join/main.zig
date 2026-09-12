const std = @import("std");
const sqlz = @import("sqlz");
const support = @import("example_support");

const lookup = sqlz.Query(.{
    .sql = "SELECT u.name, p.label FROM users u LEFT JOIN profiles p ON p.user_id=u.id WHERE u.id=:id",
    .backends = .{ .sqlite = true },
    .cardinality = .optional,
    .params = struct { id: i64 },
    .row = struct { name: []const u8, label: ?[]const u8 },
});

pub fn run(allocator: std.mem.Allocator) !void {
    var conn = try support.openMemory(allocator);
    defer conn.deinit();
    try conn.raw().execNoArgs("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL); CREATE TABLE profiles(user_id INTEGER PRIMARY KEY, label TEXT); INSERT INTO users VALUES(1,'Ada');");
    var result = (try support.unwrap(lookup.fetchOptional(&conn, .{ .id = 1 }))).?;
    defer result.deinit();
    if (result.row().label != null) return error.ExpectedNull;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa);
}
