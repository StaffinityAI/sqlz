const std = @import("std");
const sqlz = @import("sqlz");
const support = @import("example_support");

const page = sqlz.Query(.{
    .sql = "SELECT id, name FROM users WHERE name LIKE :pattern ORDER BY lower(name), id LIMIT :limit OFFSET :offset",
    .backends = .{ .sqlite = true },
    .cardinality = .many,
    .params = struct { pattern: []const u8, limit: i64, offset: i64 },
    .row = struct { id: i64, name: []const u8 },
});

pub fn run(allocator: std.mem.Allocator) !void {
    var conn = try support.openMemory(allocator);
    defer conn.deinit();
    try conn.raw().execNoArgs("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL); INSERT INTO users VALUES(1,'Ada'),(2,'Bob'),(3,'Cyd');");
    var rows = try support.unwrap(page.fetch(&conn, .{ .pattern = "%", .limit = 1, .offset = 1 }));
    defer rows.deinit();
    const row = (try support.unwrap(rows.next())).?;
    if (row.id != 2 or (try support.unwrap(rows.next())) != null) return error.UnexpectedPage;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa);
}
