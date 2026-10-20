//! The smallest checked query. The SQL lives in `examples/queries/basic_sql_file`,
//! the build checks it against the migrations, and `queries` is the module the
//! check generates from it: one declaration per file, with typed parameters and
//! rows.

const std = @import("std");
const sqlz = @import("sqlz");
const queries = @import("queries");

const add_user = queries.app.basic_sql_file.add_user;
const find_user = queries.app.basic_sql_file.find_user;

pub fn run(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer) !void {
    var conn = try sqlz.sqlite.open(allocator, io, ":memory:", .{});
    defer conn.deinit();

    // Every database call returns a `sqlz.Result`: `.ok` with the value, or
    // `.err` with the backend's error class, code, and message.
    switch (conn.executeScript("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL);")) {
        .ok => {},
        .err => |err| {
            defer err.deinit();
            try out.print("could not create the table: {s}\n", .{err.message});
            return error.SqlzFailed;
        },
    }

    // `sqlz.unwrap` turns a `Result` into a Zig error when the details do not
    // matter.
    _ = try sqlz.unwrap(add_user.execute(&conn, .{ .name = "Ada" }));

    var found = (try sqlz.unwrap(find_user.fetchOptional(&conn, .{ .id = 1 }))) orelse
        return error.UserMissing;
    defer found.deinit();
    const user = found.row();
    try out.print("user {d}: {s}\n", .{ user.id, user.name });
}

pub fn main(init: std.process.Init) !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try run(init.gpa, init.io, &stdout.interface);
    try stdout.interface.flush();
}
