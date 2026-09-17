//! A downstream application layer built on `sqlz` alone.
//!
//! This module is compiled with exactly one import — `sqlz` — so anything it
//! needs must exist on the sqlz surface. If a feature here ever requires the
//! driver handle behind `raw()`, this file stops compiling, which is the point:
//! `raw()` is an escape hatch, not a dependency.

const std = @import("std");
const sqlz = @import("sqlz");

const Tier = enum(i64) { basic = 0, premium = 1 };
const Theme = enum {
    light,
    dark,

    pub const sqlz_storage = .text;
};

const schema =
    \\CREATE TABLE accounts(
    \\  id INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL UNIQUE,
    \\  tier INTEGER NOT NULL,
    \\  theme TEXT NOT NULL,
    \\  avatar BLOB,
    \\  seats INTEGER NOT NULL
    \\);
    \\CREATE TABLE audit(id INTEGER PRIMARY KEY, account_id INTEGER NOT NULL REFERENCES accounts(id), note TEXT NOT NULL);
    \\CREATE INDEX audit_account ON audit(account_id);
;

const Account = struct {
    id: i64,
    name: []const u8,
    tier: Tier,
    theme: Theme,
    avatar: ?sqlz.Blob,
    seats: u16,
};

const create_account = sqlz.Query(.{
    .sql = "INSERT INTO accounts(name, tier, theme, avatar, seats) VALUES (:name, :tier, :theme, :avatar, :seats)" ++
        " RETURNING id, name, tier, theme, avatar, seats",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct {
        name: []const u8,
        tier: Tier,
        theme: Theme,
        avatar: ?sqlz.Blob,
        seats: u16,
    },
    .row = Account,
});

const find_account = sqlz.Query(.{
    .sql = "SELECT id, name, tier, theme, avatar, seats FROM accounts WHERE name=:name",
    .backends = .{ .sqlite = true },
    .cardinality = .optional,
    .params = struct { name: []const u8 },
    .row = Account,
});

const accounts_in_tier = sqlz.Query(.{
    .sql = "SELECT id, name, tier, theme, avatar, seats FROM accounts WHERE tier=:tier ORDER BY id",
    .backends = .{ .sqlite = true },
    .cardinality = .many,
    .params = struct { tier: Tier },
    .row = Account,
});

const add_note = sqlz.Query(.{
    .sql = "INSERT INTO audit(account_id, note) VALUES (:account_id, :note)",
    .backends = .{ .sqlite = true },
    .cardinality = .exec,
    .params = struct { account_id: i64, note: []const u8 },
});

const read_foreign_keys = sqlz.Query(.{
    .sql = "PRAGMA foreign_keys",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct {},
    .row = struct { enabled: bool },
});

// The library supplies the "did it work" helper, so an application does not
// re-implement one per project.
const unwrap = sqlz.unwrap;

test "an application opens, migrates, and queries with sqlz alone" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{
        .foreign_keys = true,
        .busy_timeout_ms = 250,
    });
    defer conn.deinit();
    try unwrap(conn.executeScript(schema));

    // Connection setup is typed rather than a PRAGMA the application remembers.
    var pragma = try unwrap(read_foreign_keys.fetchOne(&conn, .{}));
    defer pragma.deinit();
    try std.testing.expect(pragma.row().enabled);

    var created = try unwrap(create_account.fetchOne(&conn, .{
        .name = "Ada",
        .tier = .premium,
        .theme = .dark,
        .avatar = sqlz.blob("\x89PNG"),
        .seats = 12,
    }));
    // Own the row, then finalize the RETURNING statement: SQLite will not
    // commit a transaction while a statement is still in progress.
    var account = try unwrap(created.toOwned(std.testing.allocator));
    created.deinit();
    defer account.deinit();

    try std.testing.expectEqual(Tier.premium, account.row().tier);
    try std.testing.expectEqual(Theme.dark, account.row().theme);
    try std.testing.expectEqual(@as(u16, 12), account.row().seats);
    try std.testing.expectEqualStrings("\x89PNG", account.row().avatar.?.value);
    try std.testing.expectEqual(account.row().id, conn.lastInsertRowId());

    const account_id = account.row().id;
    {
        var tx = try unwrap(conn.begin(.{ .behavior = .immediate }));
        defer tx.deinit();
        const written = try unwrap(add_note.execute(&tx, .{ .account_id = account_id, .note = "created" }));
        try std.testing.expectEqual(@as(?u64, 1), written.rows_affected);
        try std.testing.expectEqual(tx.lastInsertRowId(), conn.lastInsertRowId());
        try unwrap(tx.commit());
    }

    // A foreign key the typed options enabled is enforced, and the failure
    // arrives classified instead of as a driver error.
    switch (add_note.execute(&conn, .{ .account_id = 9999, .note = "orphan" })) {
        .ok => return error.ExpectedForeignKeyViolation,
        .err => |*err| {
            defer err.deinit();
            try std.testing.expectEqual(sqlz.ErrorClass.constraint, err.class);
        },
    }

    const missing = try unwrap(find_account.fetchOptional(&conn, .{ .name = "nobody" }));
    try std.testing.expect(missing == null);
}

test "a request-scoped arena owns every row the handler returns" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try unwrap(conn.executeScript(schema));
    try unwrap(conn.executeScript(
        "INSERT INTO accounts(name,tier,theme,avatar,seats) VALUES('Ada',1,'dark',NULL,3),('Bob',1,'light',NULL,4);",
    ));

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var scope = conn.ownedScope(arena.allocator(), .{ .free_rows = false });
    defer scope.deinit();

    var rows = try unwrap(accounts_in_tier.fetch(&conn, .{ .tier = .premium }));
    const premium = try unwrap(rows.collectOwned(null));
    rows.deinit();

    try std.testing.expectEqual(@as(usize, 2), premium.items.len);
    try std.testing.expectEqualStrings("Bob", premium.items[1].name);
    try std.testing.expectEqual(Theme.light, premium.items[1].theme);
}

test "a pool serves checked queries without a driver handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/consumer.db",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    var pool = try sqlz.sqlite.Pool.init(std.testing.allocator, std.testing.io, path, .{
        .size = 2,
        .connection = .{ .foreign_keys = true, .journal_mode = .wal, .busy_timeout_ms = 250 },
    });
    defer pool.deinit();

    try unwrap(pool.executeScript(schema));
    try unwrap(pool.executeScript(
        "INSERT INTO accounts(name,tier,theme,avatar,seats) VALUES('Ada',0,'light',NULL,1);",
    ));

    var found = (try unwrap(find_account.fetchOptional(&pool, .{ .name = "Ada" }))).?;
    defer found.deinit();
    try std.testing.expectEqual(Tier.basic, found.row().tier);

    // Every pooled connection carries the same typed setup.
    var pragma = try unwrap(read_foreign_keys.fetchOne(&pool, .{}));
    defer pragma.deinit();
    try std.testing.expect(pragma.row().enabled);
}
