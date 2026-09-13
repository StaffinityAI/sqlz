const std = @import("std");
const sqlz = @import("sqlz");
const support = @import("example_support");

const cleanup = sqlz.Query(.{
    .sql = "DELETE FROM sessions WHERE expires_at<=:now",
    .backends = .{ .sqlite = true },
    .cardinality = .exec,
    .params = struct { now: i64 },
});

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    try conn.raw().execNoArgs("CREATE TABLE sessions(id INTEGER PRIMARY KEY, expires_at INTEGER NOT NULL); INSERT INTO sessions VALUES(1,10),(2,20),(3,30);");
    const result = try support.unwrap(cleanup.execute(&conn, .{ .now = 20 }));
    if (result.rows_affected != 2) return error.UnexpectedCleanupCount;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
