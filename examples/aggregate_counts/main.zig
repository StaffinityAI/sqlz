const std = @import("std");
const sqlz = @import("sqlz");
const support = @import("example_support");

const counts = sqlz.Query(.{
    .sql = "SELECT (SELECT COUNT(*) FROM organization_members WHERE user_id=:user) + (SELECT COUNT(*) FROM workspace_members WHERE user_id=:user) AS total",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct { user: i64 },
    .row = struct { total: i64 },
});

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    try conn.raw().execNoArgs("CREATE TABLE organization_members(user_id INTEGER NOT NULL); CREATE TABLE workspace_members(user_id INTEGER NOT NULL); INSERT INTO organization_members VALUES(1); INSERT INTO workspace_members VALUES(1),(1),(2);");
    var row = try support.unwrap(counts.fetchOne(&conn, .{ .user = 1 }));
    defer row.deinit();
    if (row.row().total != 3) return error.UnexpectedCount;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
