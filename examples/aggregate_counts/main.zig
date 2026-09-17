const std = @import("std");
const support = @import("example_support");
const queries = @import("queries");

const counts = queries.app.aggregate_counts.counts;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    try support.seed(&conn, "INSERT INTO organization_members VALUES(1);" ++
        "INSERT INTO workspace_members VALUES(1),(1),(2);");
    var row = try support.unwrap(counts.fetchOne(&conn, .{ .user = 1 }));
    defer row.deinit();
    if (row.row().total != 3) return error.UnexpectedCount;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
