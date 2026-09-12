const std = @import("std");
const sqlz = @import("sqlz");
const support = @import("example_support");

const transfer = sqlz.Query(.{
    .sql = "UPDATE workspaces SET owner_id=:new_owner WHERE id=:workspace AND owner_id=:old_owner",
    .backends = .{ .sqlite = true },
    .cardinality = .exec,
    .params = struct { new_owner: i64, workspace: i64, old_owner: i64 },
});

pub fn run(allocator: std.mem.Allocator) !void {
    var conn = try support.openMemory(allocator);
    defer conn.deinit();
    try conn.raw().execNoArgs("CREATE TABLE workspaces(id INTEGER PRIMARY KEY, owner_id INTEGER NOT NULL); INSERT INTO workspaces VALUES(7,1);");
    var tx = try support.unwrap(conn.begin());
    defer tx.deinit();
    const result = try support.unwrap(transfer.execute(&tx, .{ .new_owner = 2, .workspace = 7, .old_owner = 1 }));
    if (result.rows_affected != 1) return error.TransferFailed;
    try support.unwrap(tx.commit());
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa);
}
