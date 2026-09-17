const std = @import("std");
const support = @import("example_support");
const queries = @import("queries");

const effective = queries.app.recursive_roles.effective;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    try support.seed(&conn, "INSERT INTO roles VALUES(1,NULL),(2,1),(3,2);");
    var rows = try support.unwrap(effective.fetch(&conn, .{ .role = 1, .depth = 8 }));
    defer rows.deinit();
    var count: usize = 0;
    while (try support.unwrap(rows.next())) |_| count += 1;
    if (count != 3) return error.UnexpectedRowCount;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
