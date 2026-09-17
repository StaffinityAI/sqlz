//! Owned rows taken from an arena scope: the whole result set is released in
//! one call, so no row needs its own `deinit`.

const std = @import("std");
const support = @import("example_support");
const queries = @import("queries");

const all_users = queries.app.arena_rows.all_users;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    try support.seed(&conn, "INSERT INTO users VALUES(1,'Ada'),(2,'Bob'),(3,'Cyd');");

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var scope = conn.ownedScope(arena.allocator(), .{ .free_rows = false });
    defer scope.deinit();

    var rows = try support.unwrap(all_users.fetch(&conn, .{}));
    const users = try support.unwrap(rows.collectOwned(null));
    rows.deinit();

    // The cursor is finished, yet every name is still readable: the rows own
    // their memory now, and the arena will release all of it at once.
    if (users.items.len != 3) return error.UnexpectedRowCount;
    if (!std.mem.eql(u8, users.items[2].name, "Cyd")) return error.UnexpectedRow;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
