const std = @import("std");
const migrations = @import("sqlz_migrations");
const ziggy = @import("ziggy");

const valid_manifest =
    \\.format_version = 1,
    \\.revision = "a1b2c3d4e5f6",
    \\.parents = ["000000000000"],
    \\.description = "create users",
    \\.created_utc = "2026-09-03T12:00:00Z",
    \\.backends = [.sqlite],
    \\.reversible = true,
    \\.transaction = .{ .sqlite = .always },
;

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

test "parses and validates a strict revision manifest" {
    var meta: ziggy.Deserializer.Meta = .init;
    const source = try std.testing.allocator.dupeZ(u8, valid_manifest);
    defer std.testing.allocator.free(source);
    var loaded = try migrations.parseManifest(std.testing.allocator, source, &meta);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("a1b2c3d4e5f6", loaded.manifest().revision);
    try std.testing.expectEqual(migrations.TransactionPolicy.always, loaded.manifest().transaction.sqlite.?);
}

test "rejects incomplete or invalid revision policies" {
    var meta: ziggy.Deserializer.Meta = .init;
    const never_sqlite = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_manifest,
        ".sqlite = .always",
        ".sqlite = .never",
    );
    defer std.testing.allocator.free(never_sqlite);
    const source = try std.testing.allocator.dupeZ(u8, never_sqlite);
    defer std.testing.allocator.free(source);
    try std.testing.expectError(
        error.UnsupportedSqliteTransaction,
        migrations.parseManifest(std.testing.allocator, source, &meta),
    );

    const duplicate_backend = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_manifest,
        "[.sqlite]",
        "[.sqlite, .sqlite]",
    );
    defer std.testing.allocator.free(duplicate_backend);
    const duplicate_source = try std.testing.allocator.dupeZ(u8, duplicate_backend);
    defer std.testing.allocator.free(duplicate_source);
    try std.testing.expectError(
        error.DuplicateBackend,
        migrations.parseManifest(std.testing.allocator, duplicate_source, &meta),
    );
}

test "discovers revision directories in bytewise order" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var second = try tmp.dir.createDirPathOpen(
        std.testing.io,
        "bbbbbbbbbbbb_add_email",
        .{},
    );
    defer second.close(std.testing.io);
    try second.writeFile(std.testing.io, .{
        .sub_path = "revision.ziggy",
        .data =
        \\.format_version = 1,
        \\.revision = "bbbbbbbbbbbb",
        \\.parents = ["aaaaaaaaaaaa"],
        \\.description = "add email",
        \\.created_utc = "2026-09-04T12:00:00Z",
        \\.backends = [.sqlite],
        \\.reversible = true,
        \\.transaction = .{ .sqlite = .always },
        ,
    });
    try second.writeFile(std.testing.io, .{
        .sub_path = "sqlite.up.sql",
        .data = "ALTER TABLE users ADD COLUMN email TEXT",
    });

    var first = try tmp.dir.createDirPathOpen(
        std.testing.io,
        "aaaaaaaaaaaa_create_users",
        .{},
    );
    defer first.close(std.testing.io);
    try first.writeFile(std.testing.io, .{
        .sub_path = "revision.ziggy",
        .data =
        \\.format_version = 1,
        \\.revision = "aaaaaaaaaaaa",
        \\.parents = [],
        \\.description = "create users",
        \\.created_utc = "2026-09-03T12:00:00Z",
        \\.backends = [.sqlite],
        \\.reversible = true,
        \\.transaction = .{ .sqlite = .always },
        ,
    });
    try first.writeFile(std.testing.io, .{
        .sub_path = "common.up.sql",
        .data = "CREATE TABLE users (id BIGINT PRIMARY KEY)",
    });

    var discovery = try migrations.discover(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        1024 * 1024,
    );
    defer discovery.deinit();
    try std.testing.expectEqual(@as(usize, 2), discovery.revisions.len);
    try std.testing.expectEqualStrings(
        "aaaaaaaaaaaa",
        discovery.revisions[0].manifest.manifest().revision,
    );
    try std.testing.expectEqualStrings(
        "bbbbbbbbbbbb",
        discovery.revisions[1].manifest.manifest().revision,
    );
    try std.testing.expectEqualStrings(
        "ALTER TABLE users ADD COLUMN email TEXT",
        discovery.revisions[1].sqlite_up,
    );
}
