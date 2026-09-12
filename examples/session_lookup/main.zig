const std = @import("std");
const sqlz = @import("sqlz");
const support = @import("example_support");

const find_session = sqlz.Query(.{
    .sql = "SELECT u.id, u.name, s.csrf_token FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=:token AND s.expires_at>:now",
    .backends = .{ .sqlite = true },
    .cardinality = .optional,
    .params = struct { token: []const u8, now: i64 },
    .row = struct { id: i64, name: []const u8, csrf_token: []const u8 },
});

pub fn run(allocator: std.mem.Allocator) !void {
    var conn = try support.openMemory(allocator);
    defer conn.deinit();
    try conn.raw().execNoArgs("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL); CREATE TABLE sessions(token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL, csrf_token TEXT NOT NULL, expires_at INTEGER NOT NULL); INSERT INTO users VALUES(1,'Ada'); INSERT INTO sessions VALUES('valid',1,'csrf',200);");
    var row = (try support.unwrap(find_session.fetchOptional(&conn, .{ .token = "valid", .now = 100 }))).?;
    defer row.deinit();
    if (!std.mem.eql(u8, row.row().name, "Ada")) return error.UnexpectedSession;
    if ((try support.unwrap(find_session.fetchOptional(&conn, .{ .token = "valid", .now = 300 }))) != null) return error.ExpectedExpiredSession;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa);
}
