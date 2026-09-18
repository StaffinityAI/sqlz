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

test "replays views with projected column metadata and DROP VIEW" {
    var create = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL, nickname TEXT);" ++
            "CREATE VIEW user_names (user_id, display_name, nickname) AS " ++
            "SELECT id, name, nickname FROM users",
    );
    defer create.deinit();
    var drop = try parser.parse(std.testing.allocator, "DROP VIEW user_names");
    defer drop.deinit();

    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserTree(create.tree);
    const view = schema.table("user_names").?;
    try std.testing.expect(view.is_view);
    try std.testing.expectEqualStrings("int8", view.columns.get("user_id").?.database_type);
    try std.testing.expect(!view.columns.get("display_name").?.nullable);
    try std.testing.expect(view.columns.get("nickname").?.nullable);

    try schema.applyParserTree(drop.tree);
    try std.testing.expect(schema.table("user_names") == null);
}

test "accepts generated columns foreign checks and partial indexes" {
    var parsed = try parser.parseSqlite(
        std.testing.allocator,
        "CREATE TABLE parents (id INTEGER PRIMARY KEY);" ++
            "CREATE TABLE children (" ++
            "id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL REFERENCES parents(id), " ++
            "score INTEGER CHECK(score >= 0), " ++
            "doubled INTEGER GENERATED ALWAYS AS (score * 2) STORED, " ++
            "FOREIGN KEY (parent_id) REFERENCES parents(id));" ++
            "CREATE INDEX positive_children ON children(score) WHERE score > 0",
    );
    defer parsed.deinit();

    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserTree(parsed.tree);
    const children = schema.table("children").?;
    try std.testing.expect(children.columns.get("doubled") != null);
    try std.testing.expect(!children.columns.get("parent_id").?.nullable);
    try std.testing.expect(schema.indexes.get("positive_children") != null);
}

test "dropping a table removes its indexes" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT);" ++
            "CREATE INDEX users_id_key ON users(id);" ++
            "DROP TABLE users",
    );
    defer parsed.deinit();

    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserTree(parsed.tree);
    try std.testing.expect(schema.table("users") == null);
    try std.testing.expect(schema.indexes.get("users_id_key") == null);
}

test "catalog retains PostgreSQL schema-qualified table identity" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE app.users (id BIGINT PRIMARY KEY)",
    );
    defer parsed.deinit();

    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserTree(parsed.tree);
    try std.testing.expect(schema.table("app.users") != null);
    try std.testing.expect(schema.table("users") == null);
    try schema.setPostgresSearchPath(&.{"app"});
    try std.testing.expect(schema.table("users") != null);
}

test "replays PostgreSQL enums domains and enum extension" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "CREATE TYPE app.user_role AS ENUM ('member', 'admin');" ++
            "ALTER TYPE app.user_role ADD VALUE 'owner' BEFORE 'admin';" ++
            "CREATE DOMAIN app.user_id AS BIGINT CHECK (VALUE > 0);" ++
            "CREATE TABLE app.users (id app.user_id PRIMARY KEY, role app.user_role NOT NULL)",
    );
    defer parsed.deinit();

    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserTree(parsed.tree);
    try schema.setPostgresSearchPath(&.{ "app", "public" });

    const role = schema.databaseType("user_role").?;
    try std.testing.expectEqual(catalog.TypeKind.enumeration, role.kind);
    try std.testing.expectEqual(@as(usize, 3), role.enum_values.len);
    try std.testing.expectEqualStrings("member", role.enum_values[0]);
    try std.testing.expectEqualStrings("owner", role.enum_values[1]);
    try std.testing.expectEqualStrings("admin", role.enum_values[2]);
    const user_id = schema.databaseType("user_id").?;
    try std.testing.expectEqual(catalog.TypeKind.domain, user_id.kind);
    try std.testing.expectEqualStrings("int8", user_id.base_type.?);
    try std.testing.expectEqualStrings("app.user_id", schema.table("users").?.columns.get("id").?.database_type);
    try std.testing.expectEqualStrings("app.user_role", schema.table("users").?.columns.get("role").?.database_type);
}

test "drops PostgreSQL enums and domains" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "CREATE TYPE app.user_role AS ENUM ('member');" ++
            "CREATE DOMAIN app.user_id AS BIGINT;" ++
            "DROP TYPE app.user_role; DROP DOMAIN app.user_id",
    );
    defer parsed.deinit();
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserTree(parsed.tree);
    try std.testing.expect(schema.databaseType("app.user_role") == null);
    try std.testing.expect(schema.databaseType("app.user_id") == null);
}
