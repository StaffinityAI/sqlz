const std = @import("std");
const zig_queries = @import("sqlz_zig_queries");

test "discovers direct embedded query declarations in containers" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\const namespace = struct {
        \\    pub const find = sqlz.Query(.{
        \\        .sql =
        \\            \\SELECT id
        \\            \\FROM users WHERE id=:id
        \\        ,
        \\        .backends = .{ .sqlite = true },
        \\        .cardinality = .optional,
        \\        .params = struct { id: i64 },
        \\        .row = struct { id: i64 },
        \\    });
        \\};
    ;
    var discovery = try zig_queries.parse(std.testing.allocator, "src/users.zig", source);
    defer discovery.deinit();
    try std.testing.expectEqual(@as(usize, 1), discovery.sources.len);
    try std.testing.expectEqualStrings("find", discovery.sources[0].name);
    try std.testing.expectEqualStrings("SELECT id\nFROM users WHERE id=:id", discovery.sources[0].sql);
    try std.testing.expect(discovery.sources[0].backends.sqlite);
}

test "rejects computed SQL in embedded declarations" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\const statement = "SELECT 1 AS value";
        \\const query = sqlz.Query(.{
        \\    .sql = statement,
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .one,
        \\    .row = struct { value: i64 },
        \\});
    ;
    try std.testing.expectError(
        error.InvalidSqlExpression,
        zig_queries.parse(std.testing.allocator, "src/query.zig", source),
    );
}

test "discovers Zig roots in deterministic path order" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var nested = try tmp.dir.createDirPathOpen(std.testing.io, "nested", .{});
    defer nested.close(std.testing.io);
    const prefix = "const sqlz = @import(\"sqlz\");\nconst ";
    try nested.writeFile(std.testing.io, .{
        .sub_path = "z.zig",
        .data = prefix ++ "zed = sqlz.Query(.{ .sql = \"DELETE FROM users\", .backends = .{ .sqlite = true }, .cardinality = .exec });",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "a.zig",
        .data = prefix ++ "alpha = sqlz.Query(.{ .sql = \"SELECT id FROM users\", .backends = .{ .sqlite = true }, .cardinality = .many, .row = struct { id: i64 } });",
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ignored.txt", .data = "not Zig" });

    var discovery = try zig_queries.discover(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        1024 * 1024,
    );
    defer discovery.deinit();
    try std.testing.expectEqual(@as(usize, 2), discovery.sources.len);
    try std.testing.expectEqualStrings("alpha", discovery.sources[0].name);
    try std.testing.expectEqualStrings("zed", discovery.sources[1].name);
}
