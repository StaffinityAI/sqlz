const std = @import("std");
const sqlz = @import("sqlz");

test "named parameters are rewritten once and retain first-use order" {
    var rewritten = try sqlz.rewriteSqlite(
        std.testing.allocator,
        "SELECT :identity = :identity, :other, ':ignored', \" :also_ignored\" -- :comment\n",
    );
    defer rewritten.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "SELECT ?1 = ?1, ?2, ':ignored', \" :also_ignored\" -- :comment\n",
        rewritten.sql,
    );
    try std.testing.expectEqual(@as(usize, 2), rewritten.names.len);
    try std.testing.expectEqualStrings("identity", rewritten.names[0]);
    try std.testing.expectEqualStrings("other", rewritten.names[1]);
}

test "Query exposes the cardinality-selected method" {
    const insert_user = sqlz.Query(.{
        .sql = "INSERT INTO users(name) VALUES (:name)",
        .backends = .{ .sqlite = true },
        .cardinality = .exec,
        .params = struct { name: []const u8 },
    });
    try std.testing.expect(@hasDecl(insert_user, "execute"));
    try std.testing.expect(!@hasDecl(insert_user, "fetch"));
}

test "owned text rows release all duplicated fields" {
    const Row = struct { id: i64, name: []const u8, note: ?[]const u8 };
    const row: Row = .{ .id = 1, .name = "Ada", .note = "first" };
    var owned = try sqlz.cloneRow(std.testing.allocator, row);
    defer sqlz.deinitOwnedRow(std.testing.allocator, &owned);
    try std.testing.expectEqualStrings("Ada", owned.name);
    try std.testing.expectEqualStrings("first", owned.note.?);
}
