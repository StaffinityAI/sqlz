const std = @import("std");
const support = @import("example_support");
const queries = @import("queries");

const cleanup = queries.app.delete_cleanup.cleanup;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    try support.seed(&conn, "INSERT INTO sessions VALUES('a',1,'csrf',10),('b',1,'csrf',20),('c',1,'csrf',30);");
    const result = try support.unwrap(cleanup.execute(&conn, .{ .now = 20 }));
    if (result.rows_affected != 2) return error.UnexpectedCleanupCount;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
