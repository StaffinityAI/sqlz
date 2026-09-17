const std = @import("std");
const support = @import("example_support");
const queries = @import("queries");

const lookup = queries.app.nullable_join.lookup;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    try support.seed(&conn, "INSERT INTO users VALUES(1,'Ada');");
    var result = (try support.unwrap(lookup.fetchOptional(&conn, .{ .id = 1 }))).?;
    defer result.deinit();
    if (result.row().label != null) return error.ExpectedNull;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
