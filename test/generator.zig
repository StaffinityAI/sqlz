const std = @import("std");
const catalog = @import("sqlz_catalog");
const checker = @import("sqlz_checker");
const generator = @import("sqlz_generator");
const query_files = @import("sqlz_query_files");

test "deterministically emits parseable Zig for a checked named query" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applySqliteRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL)",
        "",
    );
    var source = try query_files.parse(std.testing.allocator, "users/get.sql",
        \\-- sqlz.name: get_user
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: optional
        \\
        \\SELECT id, name FROM users WHERE id=:id
    );
    defer source.deinit();
    var checked = try checker.checkNamedSqlite(std.testing.allocator, &schema, &source);
    defer checked.deinit();

    const generated = try generator.generateQuery(std.testing.allocator, &source, &checked);
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "id: i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "name: []const u8") != null);
    const terminated = try std.testing.allocator.dupeZ(u8, generated);
    defer std.testing.allocator.free(terminated);
    var ast = try std.zig.Ast.parse(std.testing.allocator, terminated, .zig);
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    const again = try generator.generateQuery(std.testing.allocator, &source, &checked);
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualStrings(generated, again);
}

test "assembles checked queries into deterministic path namespaces" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applySqliteRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL)",
        "",
    );
    var list_source = try query_files.parse(std.testing.allocator, "users/list.sql",
        \\-- sqlz.name: list_users
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: many
        \\
        \\SELECT id, name FROM users
    );
    defer list_source.deinit();
    var get_source = try query_files.parse(std.testing.allocator, "users/admin/get.sql",
        \\-- sqlz.name: get_user
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: optional
        \\
        \\SELECT id, name FROM users WHERE id=:id
    );
    defer get_source.deinit();
    var list_checked = try checker.checkNamedSqlite(std.testing.allocator, &schema, &list_source);
    defer list_checked.deinit();
    var get_checked = try checker.checkNamedSqlite(std.testing.allocator, &schema, &get_source);
    defer get_checked.deinit();

    const inputs = [_]generator.CheckedInput{
        .{ .source = &list_source, .checked = &list_checked },
        .{ .source = &get_source, .checked = &get_checked },
    };
    const generated = try generator.generateModule(std.testing.allocator, "app", &inputs);
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const app = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const users = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const admin = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const get_user = sqlz.Query") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const list_users = sqlz.Query") != null);

    const terminated = try std.testing.allocator.dupeZ(u8, generated);
    defer std.testing.allocator.free(terminated);
    var ast = try std.zig.Ast.parse(std.testing.allocator, terminated, .zig);
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    const reversed = [_]generator.CheckedInput{ inputs[1], inputs[0] };
    const generated_again = try generator.generateModule(std.testing.allocator, "app", &reversed);
    defer std.testing.allocator.free(generated_again);
    try std.testing.expectEqualStrings(generated, generated_again);
}
