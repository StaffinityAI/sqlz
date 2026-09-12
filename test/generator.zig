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
