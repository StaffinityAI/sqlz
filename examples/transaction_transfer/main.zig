const std = @import("std");
const support = @import("example_support");
const queries = @import("queries");

const transfer = queries.app.transaction_transfer.transfer;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    try support.seed(&conn, "INSERT INTO workspaces VALUES(7,1);");
    var tx = try support.unwrap(conn.begin(.{}));
    defer tx.deinit();
    const result = try support.unwrap(transfer.execute(&tx, .{ .new_owner = 2, .workspace = 7, .old_owner = 1 }));
    if (result.rows_affected != 1) return error.TransferFailed;
    try support.unwrap(tx.commit());
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
