const std = @import("std");
const support = @import("example_support");
const queries = @import("queries");

const save = queries.app.preferences_upsert.save;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    var first = try support.unwrap(save.fetchOne(&conn, .{ .user_id = 1, .value = "light" }));
    first.deinit();
    var second = try support.unwrap(save.fetchOne(&conn, .{ .user_id = 1, .value = "dark" }));
    defer second.deinit();
    if (!std.mem.eql(u8, second.row().value, "dark")) return error.UnexpectedRow;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
