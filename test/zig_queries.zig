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

test "captures the declared parameter and row structs" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id, label FROM users WHERE id=:id",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .optional,
        \\    .params = struct { id: i64 },
        \\    .row = struct { id: i64, label: ?[]const u8 },
        \\});
    ;
    var discovery = try zig_queries.parse(std.testing.allocator, "src/users.zig", source);
    defer discovery.deinit();
    const declared = discovery.sources[0].declared;
    try std.testing.expect(declared.embedded);

    const params = declared.params.?;
    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expectEqualStrings("id", params[0].name);
    try std.testing.expectEqualStrings("i64", params[0].type_text);
    try std.testing.expect(!params[0].optional);

    const row = declared.row.?;
    try std.testing.expectEqual(@as(usize, 2), row.len);
    try std.testing.expectEqualStrings("label", row[1].name);
    // The `?` is recorded separately and the spelling is whitespace-normalized.
    try std.testing.expectEqualStrings("[]const u8", row[1].type_text);
    try std.testing.expect(row[1].optional);
}

test "an omitted parameter struct declares no parameters" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\pub const list = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = struct { id: i64 },
        \\});
    ;
    var discovery = try zig_queries.parse(std.testing.allocator, "src/users.zig", source);
    defer discovery.deinit();
    const declared = discovery.sources[0].declared;
    try std.testing.expect(!declared.params_present);
    try std.testing.expectEqual(@as(usize, 0), declared.params.?.len);
    try std.testing.expect(declared.row_present);
}

test "reads codec maps and resolves a row struct named in the same file" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\const Account = struct { id: i64, tier: Tier };
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id, tier FROM accounts WHERE tier=:tier",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .param_codecs = .{ .tier = "tier" },
        \\    .column_codecs = .{ .tier = "tier" },
        \\    .params = struct { tier: Tier },
        \\    .row = Account,
        \\});
    ;
    var discovery = try zig_queries.parse(std.testing.allocator, "src/accounts.zig", source);
    defer discovery.deinit();
    const source_one = discovery.sources[0];
    try std.testing.expectEqualStrings("tier", source_one.param_codecs[0].name);
    try std.testing.expectEqualStrings("tier", source_one.param_codecs[0].codec);
    try std.testing.expectEqualStrings("tier", source_one.column_codecs[0].name);

    const row = source_one.declared.row.?;
    try std.testing.expectEqual(@as(usize, 2), row.len);
    try std.testing.expectEqualStrings("Tier", row[1].type_text);
}

test "a declared type the parser cannot read stays unread" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\const types = @import("types");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = types.User,
        \\});
    ;
    var discovery = try zig_queries.parse(std.testing.allocator, "src/users.zig", source);
    defer discovery.deinit();
    const declared = discovery.sources[0].declared;
    try std.testing.expect(declared.row_present);
    try std.testing.expect(declared.row == null);
}

test "rejects a tuple row struct" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = struct { i64 },
        \\});
    ;
    try std.testing.expectError(
        error.InvalidDeclaredType,
        zig_queries.parse(std.testing.allocator, "src/users.zig", source),
    );
}
