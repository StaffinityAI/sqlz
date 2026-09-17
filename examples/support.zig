const std = @import("std");
const sqlz = @import("sqlz");

/// The schema the checker replays offline, applied here at runtime so both
/// halves of every example agree on the same tables. Migration execution is
/// not part of this slice, so the examples run the revision SQL directly.
pub const schema = @embedFile("migrations/aaaaaaaaaaaa_example_schema/common.up.sql");

pub fn unwrap(result: anytype) !@TypeOf(result.ok) {
    return switch (result) {
        .ok => |value| value,
        .err => |*err| {
            defer err.deinit();
            return error.SqlzQueryFailed;
        },
    };
}

pub fn openMemory(allocator: std.mem.Allocator, io: std.Io) !sqlz.sqlite.Conn {
    var conn = try sqlz.sqlite.open(allocator, io, ":memory:", .{});
    errdefer conn.deinit();
    try conn.raw().execNoArgs(schema);
    return conn;
}

/// Opens a pool over a file database with the schema applied once. A pool of
/// in-memory connections would give each connection its own empty database, so
/// pooled examples need a file.
pub fn openPool(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !sqlz.sqlite.Pool {
    var pool = try sqlz.sqlite.Pool.init(allocator, io, path, .{
        .size = 2,
        .connection = .{ .foreign_keys = true, .busy_timeout_ms = 1_000 },
    });
    errdefer pool.deinit();
    var conn = try pool.acquire();
    defer conn.deinit();
    try conn.raw().execNoArgs(schema);
    return pool;
}

/// Seeds a fresh in-memory database with the rows an example needs.
pub fn seed(conn: *sqlz.sqlite.Conn, sql: [*:0]const u8) !void {
    try conn.raw().execNoArgs(sql);
}
