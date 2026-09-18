//! Queries declared in Zig rather than in `.sql` files.
//!
//! `examples/sqlz.ziggy` lists this directory as a Zig root, so the checker
//! discovers the declarations below, checks their SQL against the same
//! migrations, and verifies the `.params`/`.row` structs against what the SQL
//! actually produces. The declarations are ordinary Zig, so the example runs
//! them directly — no generated module is involved.

const std = @import("std");
const sqlz = @import("sqlz");
const support = @import("example_support");
const types = @import("types");

const Account = struct {
    id: i64,
    name: []const u8,
    tier: types.Tier,
};

pub const promote = sqlz.Query(.{
    .sql = "UPDATE accounts SET tier=:tier WHERE name=:name",
    .backends = .{ .sqlite = true, .postgres = true },
    .cardinality = .exec,
    .param_codecs = .{ .tier = "tier" },
    .params = struct { tier: types.Tier, name: []const u8 },
});

pub const by_tier = sqlz.Query(.{
    .sql = "SELECT id, name, tier FROM accounts WHERE tier=:tier ORDER BY id",
    .backends = .{ .sqlite = true, .postgres = true },
    .cardinality = .many,
    .param_codecs = .{ .tier = "tier" },
    .column_codecs = .{ .tier = "tier" },
    .params = struct { tier: types.Tier },
    .row = Account,
});

pub const newest = sqlz.Query(.{
    .sql = "SELECT id, name, tier FROM accounts ORDER BY id DESC LIMIT 1",
    .backends = .{ .sqlite = true, .postgres = true },
    .cardinality = .optional,
    .row = struct { id: i64, name: []const u8, tier: types.Tier },
    .column_codecs = .{ .tier = "tier" },
});

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var conn = try support.openMemory(allocator, io);
    defer conn.deinit();
    try support.seed(&conn, "INSERT INTO accounts VALUES(1,'Ada',0),(2,'Bob',0);");

    const promoted = try support.unwrap(promote.execute(&conn, .{ .tier = .premium, .name = "Ada" }));
    if (promoted.rows_affected != 1) return error.UnexpectedUpdateCount;

    var rows = try support.unwrap(by_tier.fetch(&conn, .{ .tier = .premium }));
    defer rows.deinit();
    const row = (try support.unwrap(rows.next())).?;
    if (row.tier != types.Tier.premium or !std.mem.eql(u8, row.name, "Ada"))
        return error.UnexpectedRow;
    if ((try support.unwrap(rows.next())) != null) return error.UnexpectedRowCount;

    var last = (try support.unwrap(newest.fetchOptional(&conn, .{}))).?;
    defer last.deinit();
    if (last.row().tier != types.Tier.basic) return error.UnexpectedTier;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}
