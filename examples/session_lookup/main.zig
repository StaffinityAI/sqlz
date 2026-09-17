const std = @import("std");
const support = @import("example_support");
const queries = @import("queries");

const find_session = queries.app.session_lookup.find_session;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    try support.seed(&conn, "INSERT INTO users VALUES(1,'Ada');" ++
        "INSERT INTO sessions VALUES('valid',1,'csrf',200);");
    var row = (try support.unwrap(find_session.fetchOptional(&conn, .{ .token = "valid", .now = 100 }))).?;
    defer row.deinit();
    if (!std.mem.eql(u8, row.row().name, "Ada")) return error.UnexpectedSession;
    if ((try support.unwrap(find_session.fetchOptional(&conn, .{ .token = "valid", .now = 300 }))) != null)
        return error.ExpectedExpiredSession;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
