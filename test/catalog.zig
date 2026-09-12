const std = @import("std");
const parser = @import("sqlz_parser");
const catalog = @import("sqlz_catalog");

test "replays CREATE TABLE columns from libpg_query AST" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE users (" ++
            "id BIGINT PRIMARY KEY, " ++
            "email TEXT NOT NULL, " ++
            "display_name TEXT" ++
            ")",
    );
    defer parsed.deinit();

    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserTree(parsed.tree);

    const users = schema.table("users").?;
    try std.testing.expectEqual(@as(usize, 3), users.columns.count());
    try std.testing.expect(users.columns.get("id").?.primary_key);
    try std.testing.expect(!users.columns.get("email").?.nullable);
    try std.testing.expect(users.columns.get("display_name").?.nullable);
    try std.testing.expect(users.columns.get("id").?.unique);
    try std.testing.expectEqualStrings("int8", users.columns.get("id").?.database_type);
}

test "replays indexes and ALTER TABLE operations" {
    var initial = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, email TEXT NOT NULL)",
    );
    defer initial.deinit();
    var changes = try parser.parse(
        std.testing.allocator,
        "ALTER TABLE users ADD COLUMN active BOOLEAN NOT NULL;" ++
            "CREATE UNIQUE INDEX users_email_key ON users(email)",
    );
    defer changes.deinit();

    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserTree(initial.tree);
    try schema.applyParserTree(changes.tree);

    const users = schema.table("users").?;
    try std.testing.expect(!users.columns.get("active").?.nullable);
    try std.testing.expect(schema.indexes.get("users_email_key").?.unique);
    try std.testing.expectEqualStrings(
        "email",
        schema.indexes.get("users_email_key").?.columns[0],
    );
}

test "replays DROP INDEX and DROP TABLE" {
    var create = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT);" ++
            "CREATE INDEX users_id_key ON users(id)",
    );
    defer create.deinit();
    var drop = try parser.parse(
        std.testing.allocator,
        "DROP INDEX users_id_key; DROP TABLE users",
    );
    defer drop.deinit();

    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserTree(create.tree);
    try schema.applyParserTree(drop.tree);
    try std.testing.expect(schema.table("users") == null);
    try std.testing.expect(schema.indexes.get("users_id_key") == null);
}

test "catalog rejects duplicate tables across migration inputs" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY)",
    );
    defer parsed.deinit();

    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserTree(parsed.tree);
    try std.testing.expectError(
        error.DuplicateTable,
        schema.applyParserTree(parsed.tree),
    );
}

test "replays table-level primary and unique constraints" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE memberships (" ++
            "organization_id BIGINT, user_id BIGINT, email TEXT, " ++
            "PRIMARY KEY (organization_id, user_id), UNIQUE (email))",
    );
    defer parsed.deinit();

    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserTree(parsed.tree);
    const table = schema.table("memberships").?;
    try std.testing.expect(table.columns.get("organization_id").?.primary_key);
    try std.testing.expect(table.columns.get("user_id").?.primary_key);
    try std.testing.expect(table.columns.get("email").?.unique);
}

test "replays table and column renames through dependent indexes" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL);" ++
            "CREATE INDEX users_name_key ON users(name);" ++
            "ALTER TABLE users RENAME COLUMN name TO display_name;" ++
            "ALTER TABLE users RENAME TO accounts",
    );
    defer parsed.deinit();

    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserTree(parsed.tree);
    try std.testing.expect(schema.table("users") == null);
    const accounts = schema.table("accounts").?;
    try std.testing.expect(accounts.columns.get("name") == null);
    try std.testing.expect(accounts.columns.get("display_name") != null);
    const index = schema.indexes.get("users_name_key").?;
    try std.testing.expectEqualStrings("accounts", index.table_name);
    try std.testing.expectEqualStrings("display_name", index.columns[0]);
}
