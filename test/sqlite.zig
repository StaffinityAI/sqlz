const std = @import("std");
const sqlz = @import("sqlz");

const User = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
    active: bool,
};

const create_user = sqlz.Query(.{
    .sql = "INSERT INTO users(name, email, active) VALUES (:name, :email, :active) RETURNING id, name, email, active",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct { name: []const u8, email: []const u8, active: bool },
    .row = User,
});

const find_user = sqlz.Query(.{
    .sql = "SELECT id, name, email, active FROM users WHERE email=:email",
    .backends = .{ .sqlite = true },
    .cardinality = .optional,
    .params = struct { email: []const u8 },
    .row = User,
});

const must_find_user = sqlz.Query(.{
    .sql = "SELECT id, name, email, active FROM users WHERE email=:email",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct { email: []const u8 },
    .row = User,
});

const list_users = sqlz.Query(.{
    .sql = "SELECT id, name, email, active FROM users ORDER BY lower(name), id",
    .backends = .{ .sqlite = true },
    .cardinality = .many,
    .row = User,
});

const deactivate_user = sqlz.Query(.{
    .sql = "UPDATE users SET active=0 WHERE id=:id",
    .backends = .{ .sqlite = true },
    .cardinality = .exec,
    .params = struct { id: i64 },
});

const upsert_preference = sqlz.Query(.{
    .sql = "INSERT INTO preferences(user_id, theme, updated_at) VALUES (:user_id, :theme, :updated_at) " ++
        "ON CONFLICT(user_id) DO UPDATE SET theme=excluded.theme, updated_at=excluded.updated_at " ++
        "RETURNING user_id, theme, updated_at",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct { user_id: i64, theme: []const u8, updated_at: i64 },
    .row = struct { user_id: i64, theme: []const u8, updated_at: i64 },
});

const list_children = sqlz.Query(.{
    .sql = "WITH RECURSIVE descendants(id, depth) AS (" ++
        "SELECT id, 0 FROM nodes WHERE id=:root " ++
        "UNION ALL SELECT n.id, d.depth+1 FROM nodes n JOIN descendants d ON n.parent_id=d.id WHERE d.depth<:max_depth" ++
        ") SELECT id, depth FROM descendants ORDER BY depth, id",
    .backends = .{ .sqlite = true },
    .cardinality = .many,
    .params = struct { root: i64, max_depth: i64 },
    .row = struct { id: i64, depth: i64 },
});

const membership = sqlz.Query(.{
    .sql = "SELECT u.id, u.name, m.label FROM users u LEFT JOIN memberships m ON m.user_id=u.id " ++
        "WHERE u.id=:id",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct { id: i64 },
    .row = struct { id: i64, name: []const u8, label: ?[]const u8 },
});

test "all four cardinalities execute through SQLite" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs(
        "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, active INTEGER NOT NULL CHECK(active IN (0,1)));",
    );

    var inserted = try unwrap(create_user.fetchOne(&conn, .{ .name = "Ada", .email = "ada@example.test", .active = true }));
    defer inserted.deinit();
    try std.testing.expectEqualStrings("Ada", inserted.row().name);

    var found = (try unwrap(find_user.fetchOptional(&conn, .{ .email = "ada@example.test" }))).?;
    defer found.deinit();
    try std.testing.expect(found.row().active);

    const changed = try unwrap(deactivate_user.execute(&conn, .{ .id = inserted.row().id }));
    try std.testing.expectEqual(@as(?u64, 1), changed.rows_affected);

    var rows = try unwrap(list_users.fetch(&conn, .{}));
    defer rows.deinit();
    const first = (try unwrap(rows.next())).?;
    try std.testing.expect(!first.active);
    try std.testing.expect((try unwrap(rows.next())) == null);
}

test "optional and one preserve distinct empty-result behavior" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs(
        "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, active INTEGER NOT NULL);",
    );

    try std.testing.expect((try unwrap(find_user.fetchOptional(&conn, .{ .email = "missing@example.test" }))) == null);
    const result = must_find_user.fetchOne(&conn, .{ .email = "missing@example.test" });
    switch (result) {
        .ok => |value| {
            var single = value;
            single.deinit();
            return error.ExpectedConstraint;
        },
        .err => |*err| {
            defer err.deinit();
            try std.testing.expectEqual(sqlz.ErrorClass.invalid_data, err.class);
        },
    }
}

test "upsert returning exposes the winning row" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs(
        "CREATE TABLE preferences(user_id INTEGER PRIMARY KEY, theme TEXT NOT NULL, updated_at INTEGER NOT NULL);",
    );
    var first = try unwrap(upsert_preference.fetchOne(&conn, .{ .user_id = 7, .theme = "light", .updated_at = 1 }));
    first.deinit();
    var second = try unwrap(upsert_preference.fetchOne(&conn, .{ .user_id = 7, .theme = "dark", .updated_at = 2 }));
    defer second.deinit();
    try std.testing.expectEqualStrings("dark", second.row().theme);
    try std.testing.expectEqual(@as(i64, 2), second.row().updated_at);
}

test "left joins decode nullable fields and owned rows survive result cleanup" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs(
        "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, active INTEGER NOT NULL);" ++
            "CREATE TABLE memberships(user_id INTEGER PRIMARY KEY REFERENCES users(id), label TEXT);" ++
            "INSERT INTO users(id,name,email,active) VALUES(1,'Ada','ada@example.test',1);",
    );
    var single = try unwrap(membership.fetchOne(&conn, .{ .id = 1 }));
    var owned = try unwrap(single.toOwned(std.testing.allocator));
    single.deinit();
    defer owned.deinit();
    try std.testing.expectEqualStrings("Ada", owned.row().name);
    try std.testing.expectEqual(@as(?[]const u8, null), owned.row().label);
}

test "recursive CTE streams a bounded hierarchy" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs(
        "CREATE TABLE nodes(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES nodes(id));" ++
            "INSERT INTO nodes VALUES(1,NULL),(2,1),(3,2),(4,3);",
    );
    var rows = try unwrap(list_children.fetch(&conn, .{ .root = 1, .max_depth = 2 }));
    defer rows.deinit();
    var expected: i64 = 1;
    while (try unwrap(rows.next())) |row| : (expected += 1) try std.testing.expectEqual(expected, row.id);
    try std.testing.expectEqual(@as(i64, 4), expected);
}

test "transaction deinit rolls back and commit persists" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, active INTEGER NOT NULL);");
    {
        var tx = try unwrap(conn.begin());
        defer tx.deinit();
        var inserted = try unwrap(create_user.fetchOne(&tx, .{ .name = "Ada", .email = "ada@example.test", .active = true }));
        inserted.deinit();
    }
    try std.testing.expect((try unwrap(find_user.fetchOptional(&conn, .{ .email = "ada@example.test" }))) == null);
    {
        var tx = try unwrap(conn.begin());
        defer tx.deinit();
        var inserted = try unwrap(create_user.fetchOne(&tx, .{ .name = "Ada", .email = "ada@example.test", .active = true }));
        inserted.deinit();
        try unwrap(tx.commit());
    }
    var found = (try unwrap(find_user.fetchOptional(&conn, .{ .email = "ada@example.test" }))).?;
    defer found.deinit();
}

test "a borrowed connection keeps the caller's handle and io" {
    var owner = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer owner.deinit();
    try owner.raw().execNoArgs("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, active INTEGER NOT NULL);");

    {
        var borrowed = sqlz.sqlite.borrow(std.testing.allocator, std.testing.io, owner.raw());
        // `deinit` must not close a handle the caller still owns.
        defer borrowed.deinit();
        try std.testing.expectEqual(std.testing.io.vtable, borrowed.io.vtable);
        var inserted = try unwrap(create_user.fetchOne(&borrowed, .{ .name = "Ada", .email = "ada@example.test", .active = true }));
        inserted.deinit();
    }

    var found = (try unwrap(find_user.fetchOptional(&owner, .{ .email = "ada@example.test" }))).?;
    defer found.deinit();
}

const pragma_foreign_keys = sqlz.Query(.{
    .sql = "PRAGMA foreign_keys",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct {},
    .row = struct { enabled: i64 },
});

fn tempDatabasePath(allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/pool.db", .{sub_path});
}

test "a pool hands out connections and takes them back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempDatabasePath(std.testing.allocator, &tmp.sub_path);
    defer std.testing.allocator.free(path);

    var pool = try sqlz.sqlite.Pool.init(std.testing.allocator, std.testing.io, path, .{
        .size = 2,
        .connection = .{ .foreign_keys = true, .busy_timeout_ms = 500 },
    });
    defer pool.deinit();

    {
        var conn = try pool.acquire();
        defer conn.deinit();
        try conn.raw().execNoArgs(user_schema);

        // The typed options reached every pooled connection.
        var pragma = try unwrap(pragma_foreign_keys.fetchOne(&conn, .{}));
        defer pragma.deinit();
        try std.testing.expectEqual(@as(i64, 1), pragma.row().enabled);
    }

    // Both connections are back in the pool, so the whole pool can be used again.
    var first = try pool.acquire();
    var second = try pool.acquire();
    first.deinit();
    second.deinit();

    var third = try pool.acquire();
    defer third.deinit();
    var rows = try unwrap(list_users.fetch(&third, .{}));
    defer rows.deinit();
    try std.testing.expect((try unwrap(rows.next())) != null);
}

test "a pool executes checked queries and releases with the result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempDatabasePath(std.testing.allocator, &tmp.sub_path);
    defer std.testing.allocator.free(path);

    var pool = try sqlz.sqlite.Pool.init(std.testing.allocator, std.testing.io, path, .{ .size = 1 });
    defer pool.deinit();

    {
        var conn = try pool.acquire();
        defer conn.deinit();
        try conn.raw().execNoArgs(user_schema);
    }

    // A pool of one proves each handle returns its connection on deinit:
    // every step below would block forever otherwise.
    const updated = try unwrap(deactivate_user.execute(&pool, .{ .id = 1 }));
    try std.testing.expectEqual(@as(?u64, 1), updated.rows_affected);

    var single = try unwrap(must_find_user.fetchOne(&pool, .{ .email = "bob@example.test" }));
    try std.testing.expectEqualStrings("Bob", single.row().name);
    single.deinit();

    const missing = try unwrap(find_user.fetchOptional(&pool, .{ .email = "nobody@example.test" }));
    try std.testing.expect(missing == null);

    var rows = try unwrap(list_users.fetch(&pool, .{}));
    var counted: usize = 0;
    while ((try unwrap(rows.next())) != null) counted += 1;
    rows.deinit();
    try std.testing.expectEqual(@as(usize, 3), counted);

    var last = try unwrap(must_find_user.fetchOne(&pool, .{ .email = "ada@example.test" }));
    defer last.deinit();
    try std.testing.expectEqualStrings("Ada", last.row().name);
}

const select_active = sqlz.Query(.{
    .sql = "SELECT 1 FROM users WHERE active=1 LIMIT 1",
    .backends = .{ .sqlite = true },
    .cardinality = .exec,
    .params = struct {},
});

test "execution metadata reports writes and stays quiet about reads" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs(user_schema);

    var created = try unwrap(create_user.fetchOne(&conn, .{
        .name = "Dee",
        .email = "dee@example.test",
        .active = true,
    }));
    defer created.deinit();
    try std.testing.expectEqual(created.row().id, conn.lastInsertRowId());

    const updated = try unwrap(deactivate_user.execute(&conn, .{ .id = created.row().id }));
    try std.testing.expectEqual(@as(?u64, 1), updated.rows_affected);
    try std.testing.expectEqual(@as(u64, 1), conn.changes());

    const missed = try unwrap(deactivate_user.execute(&conn, .{ .id = 9999 }));
    try std.testing.expectEqual(@as(?u64, 0), missed.rows_affected);

    // A read reports no count rather than the previous statement's.
    const read = try unwrap(select_active.execute(&conn, .{}));
    try std.testing.expectEqual(@as(?u64, null), read.rows_affected);
}

test "constraint failures carry the extended result code" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs(user_schema);

    switch (create_user.fetchOne(&conn, .{
        .name = "Duplicate",
        .email = "ada@example.test",
        .active = true,
    })) {
        .ok => |*value| {
            var single = value.*;
            single.deinit();
            return error.ExpectedUniqueViolation;
        },
        .err => |*err| {
            defer err.deinit();
            try std.testing.expectEqual(sqlz.ErrorClass.constraint, err.class);
            // SQLITE_CONSTRAINT_UNIQUE
            try std.testing.expectEqual(@as(?i32, 2067), err.code);
        },
    }
}

const user_schema =
    "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, active INTEGER NOT NULL);" ++
    "INSERT INTO users(id,name,email,active) VALUES(1,'Ada','ada@example.test',1)," ++
    "(2,'Bob','bob@example.test',1),(3,'Cai','cai@example.test',0);";

test "an arena scope owns whole result sets without per-row deinit" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs(user_schema);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var scope = conn.ownedScope(arena.allocator(), .{ .free_rows = false });
    defer scope.deinit();

    var rows = try unwrap(list_users.fetch(&conn, .{}));
    const collected = try unwrap(rows.collectOwned(null));
    rows.deinit();

    try std.testing.expectEqual(@as(usize, 3), collected.items.len);
    try std.testing.expectEqualStrings("Ada", collected.items[0].name);
    try std.testing.expectEqualStrings("cai@example.test", collected.items[2].email);
    try std.testing.expect(!collected.items[2].active);
    // No per-row cleanup: the arena releases every field at once.
    try std.testing.expect(!collected.free_rows);
}

test "scopes nest and restore the allocator they replaced" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs(user_schema);

    var outer = conn.ownedScope(std.testing.allocator, .{});
    defer outer.deinit();
    {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var inner = conn.ownedScope(arena.allocator(), .{ .free_rows = false });
        defer inner.deinit();

        var single = try unwrap(must_find_user.fetchOne(&conn, .{ .email = "ada@example.test" }));
        var owned = try unwrap(single.toOwned(null));
        single.deinit();
        try std.testing.expect(owned.allocator == null);
        try std.testing.expectEqualStrings("Ada", owned.row().name);
    }

    var single = try unwrap(must_find_user.fetchOne(&conn, .{ .email = "bob@example.test" }));
    var owned = try unwrap(single.toOwned(null));
    single.deinit();
    defer owned.deinit();
    try std.testing.expect(owned.allocator != null);
    try std.testing.expectEqualStrings("Bob", owned.row().name);
}

test "streamed rows convert one at a time" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs(user_schema);

    var rows = try unwrap(list_users.fetch(&conn, .{}));
    defer rows.deinit();
    var seen: usize = 0;
    while (try unwrap(rows.nextOwned(std.testing.allocator))) |row| {
        var owned = row;
        defer owned.deinit();
        seen += 1;
        try std.testing.expect(owned.row().name.len > 0);
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}

test "an owned conversion without an allocator is refused" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs(user_schema);

    var single = try unwrap(must_find_user.fetchOne(&conn, .{ .email = "ada@example.test" }));
    defer single.deinit();
    switch (single.toOwned(null)) {
        .ok => return error.ExpectedMissingAllocator,
        .err => |*err| {
            defer err.deinit();
            try std.testing.expectEqual(sqlz.ErrorClass.invalid_data, err.class);
        },
    }
}

const Tier = enum(i64) { basic, premium };
const Shade = enum {
    light,
    dark,

    pub const sqlz_storage = .text;
};

const Account = struct {
    id: i64,
    tier: Tier,
    shade: Shade,
    fallback: ?Tier,
    avatar: ?sqlz.Blob,
};

const account_schema =
    "CREATE TABLE accounts(id INTEGER PRIMARY KEY, tier INTEGER NOT NULL, shade TEXT NOT NULL," ++
    " fallback INTEGER, avatar BLOB);";

const insert_account = sqlz.Query(.{
    .sql = "INSERT INTO accounts(id, tier, shade, fallback, avatar) VALUES (:id, :tier, :shade, :fallback, :avatar)",
    .backends = .{ .sqlite = true },
    .cardinality = .exec,
    .params = struct { id: i64, tier: Tier, shade: Shade, fallback: ?Tier, avatar: ?sqlz.Blob },
});

const find_account = sqlz.Query(.{
    .sql = "SELECT id, tier, shade, fallback, avatar FROM accounts WHERE tier=:tier AND shade=:shade",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .params = struct { tier: Tier, shade: Shade },
    .row = Account,
});

test "enums bind and decode through their stored representation" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs(account_schema);

    _ = try unwrap(insert_account.execute(&conn, .{
        .id = 1,
        .tier = .premium,
        .shade = .dark,
        .fallback = null,
        .avatar = sqlz.blob("\x00\xff"),
    }));
    _ = try unwrap(insert_account.execute(&conn, .{
        .id = 2,
        .tier = .basic,
        .shade = .light,
        .fallback = @as(?Tier, .premium),
        .avatar = null,
    }));

    var premium = try unwrap(find_account.fetchOne(&conn, .{ .tier = .premium, .shade = .dark }));
    defer premium.deinit();
    try std.testing.expectEqual(Tier.premium, premium.row().tier);
    try std.testing.expectEqual(Shade.dark, premium.row().shade);
    try std.testing.expectEqual(@as(?Tier, null), premium.row().fallback);
    try std.testing.expectEqualStrings("\x00\xff", premium.row().avatar.?.value);

    var basic = try unwrap(find_account.fetchOne(&conn, .{ .tier = .basic, .shade = .light }));
    defer basic.deinit();
    try std.testing.expectEqual(@as(?Tier, .premium), basic.row().fallback);
    try std.testing.expectEqual(@as(?sqlz.Blob, null), basic.row().avatar);
}

test "a database value outside the enum is reported, not trapped" {
    var conn = try sqlz.sqlite.open(std.testing.allocator, std.testing.io, ":memory:", .{});
    defer conn.deinit();
    try conn.raw().execNoArgs(account_schema ++
        "INSERT INTO accounts(id,tier,shade,fallback,avatar) VALUES(1,9,'dark',NULL,NULL);");

    switch (find_account.fetchOne(&conn, .{ .tier = .premium, .shade = .dark })) {
        .ok => |*value| {
            var single = value.*;
            single.deinit();
            return error.ExpectedDecodeFailure;
        },
        .err => |*err| {
            defer err.deinit();
            try std.testing.expectEqual(sqlz.ErrorClass.invalid_data, err.class);
        },
    }
}

fn unwrap(result: anytype) !@TypeOf(result.ok) {
    return switch (result) {
        .ok => |value| value,
        .err => |*err| {
            defer err.deinit();
            return error.SqlzFailure;
        },
    };
}
