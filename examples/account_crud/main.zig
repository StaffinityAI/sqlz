const std = @import("std");
const support = @import("example_support");
const queries = @import("queries");

const create = queries.app.account_crud.create;
const list = queries.app.account_crud.list;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    var inserted = try support.unwrap(create.fetchOne(&conn, .{ .name = "Ada" }));
    defer inserted.deinit();
    var rows = try support.unwrap(list.fetch(&conn, .{}));
    defer rows.deinit();
    const row = (try support.unwrap(rows.next())).?;
    if (row.id != 1 or !std.mem.eql(u8, row.name, "Ada")) return error.UnexpectedRow;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
