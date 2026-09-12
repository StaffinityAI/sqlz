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
    try schema.applyParserJson(parsed.ast_json);

    const users = schema.table("users").?;
    try std.testing.expectEqual(@as(usize, 3), users.columns.count());
    try std.testing.expect(users.columns.get("id").?.primary_key);
    try std.testing.expect(!users.columns.get("email").?.nullable);
    try std.testing.expect(users.columns.get("display_name").?.nullable);
    try std.testing.expectEqualStrings("int8", users.columns.get("id").?.database_type);
}

test "catalog rejects duplicate tables across migration inputs" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY)",
    );
    defer parsed.deinit();

    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserJson(parsed.ast_json);
    try std.testing.expectError(
        error.DuplicateTable,
        schema.applyParserJson(parsed.ast_json),
    );
}
