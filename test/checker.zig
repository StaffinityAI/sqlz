const std = @import("std");
const checker = @import("sqlz_checker");
const catalog = @import("sqlz_catalog");
const migrations = @import("sqlz_migrations");

test "replays SQLite migrations in graph order" {
    const inputs = [_]checker.MigrationInput{
        .{
            .revision = .{ .id = "dddddddddddd", .parents = &.{ "bbbbbbbbbbbb", "cccccccccccc" } },
            .common_sql = "CREATE UNIQUE INDEX accounts_email_key ON accounts(email)",
        },
        .{
            .revision = .{ .id = "cccccccccccc", .parents = &.{"aaaaaaaaaaaa"} },
            .common_sql = "CREATE TABLE profiles (id BIGINT PRIMARY KEY)",
        },
        .{
            .revision = .{ .id = "aaaaaaaaaaaa", .parents = &.{} },
            .common_sql = "CREATE TABLE accounts (id BIGINT PRIMARY KEY)",
        },
        .{
            .revision = .{ .id = "bbbbbbbbbbbb", .parents = &.{"aaaaaaaaaaaa"} },
            .common_sql = "ALTER TABLE accounts ADD COLUMN email TEXT NOT NULL",
        },
    };

    var schema = try checker.replaySqlite(std.testing.allocator, &inputs);
    defer schema.deinit();
    try std.testing.expect(schema.table("profiles") != null);
    try std.testing.expect(!schema.table("accounts").?.columns.get("email").?.nullable);
    try std.testing.expect(schema.indexes.get("accounts_email_key").?.unique);
}

test "a failed revision leaves the prior catalog unchanged" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applySqliteRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY)",
        "",
    );

    try std.testing.expectError(
        error.DuplicateTable,
        checker.applySqliteRevisionAtomic(
            &schema,
            std.testing.allocator,
            "ALTER TABLE users ADD COLUMN active BOOLEAN NOT NULL;" ++
                "CREATE TABLE users (other BIGINT)",
            "",
        ),
    );
    try std.testing.expect(schema.table("users").?.columns.get("active") == null);
}

test "ordered replay rejects an invalid graph before applying SQL" {
    const inputs = [_]checker.MigrationInput{
        .{
            .revision = migrations.Revision{
                .id = "aaaaaaaaaaaa",
                .parents = &.{"bbbbbbbbbbbb"},
            },
            .common_sql = "CREATE TABLE should_not_exist (id BIGINT)",
        },
    };
    try std.testing.expectError(
        error.MissingParent,
        checker.replaySqlite(std.testing.allocator, &inputs),
    );
}

test "discovery and replay apply common SQL before SQLite SQL" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var revision = try tmp.dir.createDirPathOpen(
        std.testing.io,
        "aaaaaaaaaaaa_create_users",
        .{},
    );
    defer revision.close(std.testing.io);
    try revision.writeFile(std.testing.io, .{
        .sub_path = "revision.ziggy",
        .data =
        \\.format_version = 1,
        \\.revision = "aaaaaaaaaaaa",
        \\.parents = [],
        \\.description = "create users",
        \\.created_utc = "2026-09-03T12:00:00Z",
        \\.backends = [.sqlite],
        \\.reversible = true,
        \\.transaction = .{ .sqlite = .always },
        ,
    });
    try revision.writeFile(std.testing.io, .{
        .sub_path = "common.up.sql",
        .data = "CREATE TABLE users (id BIGINT PRIMARY KEY, email TEXT)",
    });
    try revision.writeFile(std.testing.io, .{
        .sub_path = "sqlite.up.sql",
        .data = "CREATE UNIQUE INDEX users_email_key ON users(email)",
    });

    var discovery = try migrations.discover(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        1024 * 1024,
    );
    defer discovery.deinit();
    var schema = try checker.replayDiscoveredSqlite(std.testing.allocator, &discovery);
    defer schema.deinit();
    try std.testing.expect(schema.table("users") != null);
    try std.testing.expect(schema.indexes.get("users_email_key").?.unique);
}
