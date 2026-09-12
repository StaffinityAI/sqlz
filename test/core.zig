const std = @import("std");
const sqlz = @import("sqlz");

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
