const std = @import("std");
const sqlz = @import("sqlz");
const support = @import("example_support");

const copy_permission = sqlz.Query(.{
    .sql = "INSERT OR IGNORE INTO role_permissions(role_id, permission_key) SELECT role_id, :new_key FROM role_permissions WHERE permission_key=:old_key",
    .backends = .{ .sqlite = true },
    .cardinality = .exec,
    .params = struct { new_key: []const u8, old_key: []const u8 },
});

pub fn run(allocator: std.mem.Allocator) !void {
    var conn = try support.openMemory(allocator);
    defer conn.deinit();
    try conn.raw().execNoArgs("CREATE TABLE role_permissions(role_id INTEGER NOT NULL, permission_key TEXT NOT NULL, PRIMARY KEY(role_id, permission_key)); INSERT INTO role_permissions VALUES(7,'read');");
    const first = try support.unwrap(copy_permission.execute(&conn, .{ .new_key = "share", .old_key = "read" }));
    const second = try support.unwrap(copy_permission.execute(&conn, .{ .new_key = "share", .old_key = "read" }));
    if (first.rows_affected != 1 or second.rows_affected != 0) return error.ExpectedIdempotency;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa);
}
