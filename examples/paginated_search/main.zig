const std = @import("std");
const support = @import("example_support");
const queries = @import("queries");

const page = queries.app.paginated_search.page;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    try support.seed(&conn, "INSERT INTO users VALUES(1,'Ada'),(2,'Bob'),(3,'Cyd');");
    var rows = try support.unwrap(page.fetch(&conn, .{ .pattern = "%", .limit = 1, .offset = 1 }));
    defer rows.deinit();
    const row = (try support.unwrap(rows.next())).?;
    if (row.id != 2 or (try support.unwrap(rows.next())) != null) return error.UnexpectedPage;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
