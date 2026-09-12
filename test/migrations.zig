const std = @import("std");
const migrations = @import("sqlz_migrations");

test "orders a branched migration graph deterministically before its merge" {
    const revisions = [_]migrations.Revision{
        .{ .id = "dddddddddddd", .parents = &.{"bbbbbbbbbbbb"} },
        .{ .id = "aaaaaaaaaaaa", .parents = &.{} },
        .{ .id = "cccccccccccc", .parents = &.{"aaaaaaaaaaaa"} },
        .{ .id = "bbbbbbbbbbbb", .parents = &.{"aaaaaaaaaaaa"} },
        .{ .id = "eeeeeeeeeeee", .parents = &.{ "cccccccccccc", "dddddddddddd" } },
    };
    var order = try migrations.validateAndOrder(std.testing.allocator, &revisions);
    defer order.deinit();

    const expected = [_][]const u8{
        "aaaaaaaaaaaa",
        "bbbbbbbbbbbb",
        "cccccccccccc",
        "dddddddddddd",
        "eeeeeeeeeeee",
    };
    for (expected, order.indices) |id, index|
        try std.testing.expectEqualStrings(id, revisions[index].id);
    try std.testing.expectEqualStrings("eeeeeeeeeeee", revisions[order.head].id);
}

test "rejects missing parents cycles and multiple heads" {
    const missing = [_]migrations.Revision{
        .{ .id = "aaaaaaaaaaaa", .parents = &.{"bbbbbbbbbbbb"} },
    };
    try std.testing.expectError(
        error.MissingParent,
        migrations.validateAndOrder(std.testing.allocator, &missing),
    );

    const cycle = [_]migrations.Revision{
        .{ .id = "aaaaaaaaaaaa", .parents = &.{"bbbbbbbbbbbb"} },
        .{ .id = "bbbbbbbbbbbb", .parents = &.{"aaaaaaaaaaaa"} },
    };
    try std.testing.expectError(
        error.Cycle,
        migrations.validateAndOrder(std.testing.allocator, &cycle),
    );

    const heads = [_]migrations.Revision{
        .{ .id = "aaaaaaaaaaaa", .parents = &.{} },
        .{ .id = "bbbbbbbbbbbb", .parents = &.{} },
    };
    try std.testing.expectError(
        error.MultipleHeads,
        migrations.validateAndOrder(std.testing.allocator, &heads),
    );
}
