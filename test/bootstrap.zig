const std = @import("std");
const bootstrap = @import("sqlz_bootstrap");
const catalog = @import("sqlz_catalog");
const parser = @import("sqlz_parser");

test "plans direct SQLite to PostgreSQL table transfer" {
    const allocator = std.testing.allocator;
    var sqlite = catalog.Catalog.init(allocator);
    defer sqlite.deinit();
    var postgres = catalog.Catalog.init(allocator);
    defer postgres.deinit();

    var sqlite_tree = try parser.parse(allocator, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
    defer sqlite_tree.deinit();
    try sqlite.applyParserTree(sqlite_tree.tree);
    var postgres_tree = try parser.parse(allocator, "CREATE TABLE app.users (id BIGINT PRIMARY KEY, name TEXT NOT NULL)");
    defer postgres_tree.deinit();
    try postgres.applyParserTree(postgres_tree.tree);

    var transfer = try bootstrap.plan(allocator, &sqlite, &postgres, "app");
    defer transfer.deinit();
    try std.testing.expectEqual(@as(usize, 1), transfer.tables.len);
    try std.testing.expectEqualStrings("users", transfer.tables[0].source_name);
    try std.testing.expectEqualStrings("app", transfer.tables[0].destination_schema);
    try std.testing.expectEqualStrings("users", transfer.tables[0].destination_name);
    try std.testing.expectEqual(@as(usize, 2), transfer.tables[0].columns.len);
}

test "rejects incompatible destination columns" {
    const allocator = std.testing.allocator;
    var sqlite = catalog.Catalog.init(allocator);
    defer sqlite.deinit();
    var postgres = catalog.Catalog.init(allocator);
    defer postgres.deinit();

    var sqlite_tree = try parser.parse(allocator, "CREATE TABLE users (id INTEGER)");
    defer sqlite_tree.deinit();
    try sqlite.applyParserTree(sqlite_tree.tree);
    var postgres_tree = try parser.parse(allocator, "CREATE TABLE app.users (id TEXT)");
    defer postgres_tree.deinit();
    try postgres.applyParserTree(postgres_tree.tree);

    try std.testing.expectError(
        error.IncompatibleType,
        bootstrap.plan(allocator, &sqlite, &postgres, "app"),
    );
}
