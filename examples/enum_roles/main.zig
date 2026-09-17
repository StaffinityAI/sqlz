//! A checked query whose parameter and result column are an application enum.
//! `sqlz.ziggy` registers the `tier` codec, `build.zig` binds it to
//! `types.Tier`, and sqlz converts through the stored INTEGER on both sides.

const std = @import("std");
const support = @import("example_support");
const queries = @import("queries");
const types = @import("types");

const promote = queries.app.enum_roles.promote;
const by_tier = queries.app.enum_roles.by_tier;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    try support.seed(&conn, "INSERT INTO accounts VALUES(1,'Ada',0),(2,'Bob',0),(3,'Cyd',1);");

    {
        var promoted = try support.unwrap(promote.fetchOne(&conn, .{ .tier = .premium, .id = 1 }));
        defer promoted.deinit();
        if (promoted.row().tier != types.Tier.premium) return error.UnexpectedTier;
    }

    var rows = try support.unwrap(by_tier.fetch(&conn, .{ .tier = .premium }));
    defer rows.deinit();
    var premium: usize = 0;
    while (try support.unwrap(rows.next())) |row| {
        if (row.tier != types.Tier.premium) return error.UnexpectedTier;
        premium += 1;
    }
    if (premium != 2) return error.UnexpectedTierCount;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
