const std = @import("std");
const sqlz = @import("sqlz");
const support = @import("example_support");

const effective = sqlz.Query(.{
    .sql = "WITH RECURSIVE held(id, depth) AS (SELECT id, 0 FROM roles WHERE id=:role UNION ALL SELECT r.id, h.depth+1 FROM roles r JOIN held h ON r.child_id=h.id WHERE h.depth<:depth) SELECT id, depth FROM held ORDER BY depth",
    .backends = .{ .sqlite = true },
    .cardinality = .many,
    .params = struct { role: i64, depth: i64 },
    .row = struct { id: i64, depth: i64 },
});

pub fn run(allocator: std.mem.Allocator) !void {
    var conn = try support.openMemory(allocator);
    defer conn.deinit();
    try conn.raw().execNoArgs("CREATE TABLE roles(id INTEGER PRIMARY KEY, child_id INTEGER); INSERT INTO roles VALUES(1,NULL),(2,1),(3,2);");
    var rows = try support.unwrap(effective.fetch(&conn, .{ .role = 1, .depth = 8 }));
    defer rows.deinit();
    var count: usize = 0;
    while (try support.unwrap(rows.next())) |_| count += 1;
    if (count != 3) return error.UnexpectedRowCount;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa);
}
