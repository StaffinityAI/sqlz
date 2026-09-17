const std = @import("std");
const support = @import("example_support");
const queries = @import("queries");

const copy_permission = queries.app.insert_select.copy_permission;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    try support.seed(&conn, "INSERT INTO role_permissions VALUES(7,'read');");
    const first = try support.unwrap(copy_permission.execute(&conn, .{ .new_key = "share", .old_key = "read" }));
    const second = try support.unwrap(copy_permission.execute(&conn, .{ .new_key = "share", .old_key = "read" }));
    if (first.rows_affected != 1 or second.rows_affected != 0) return error.ExpectedIdempotency;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
