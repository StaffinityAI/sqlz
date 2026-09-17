//! Checked queries run straight against a pool: each call borrows a
//! connection and returns it when the result is released.

const std = @import("std");
const support = @import("example_support");
const queries = @import("queries");

const count_users = queries.app.pooled_reads.count_users;
const find_user = queries.app.pooled_reads.find_user;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    // The connection's own runtime supplies the clock, same as everywhere else.
    const stamp: u64 = @truncate(@as(u96, @bitCast(std.Io.Clock.real.now(io).toNanoseconds())));
    const path = try std.fmt.allocPrint(allocator, "sqlz-pooled-{x}.db", .{stamp});
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var pool = try support.openPool(allocator, io, path);
    defer pool.deinit();

    {
        var conn = try pool.acquire();
        defer conn.deinit();
        try support.seed(&conn, "INSERT INTO users VALUES(1,'Ada'),(2,'Bob');");
    }

    var total = try support.unwrap(count_users.fetchOne(&pool, .{}));
    if (total.row().total != 2) return error.UnexpectedCount;
    total.deinit();

    var found = (try support.unwrap(find_user.fetchOptional(&pool, .{ .id = 2 }))).?;
    defer found.deinit();
    if (!std.mem.eql(u8, found.row().name, "Bob")) return error.UnexpectedRow;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
