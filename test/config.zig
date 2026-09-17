const std = @import("std");
const config = @import("sqlz_config");
const ziggy = @import("ziggy");

const valid =
    \\.format_version = 1,
    \\.project_id = "550e8400-e29b-41d4-a716-446655440000",
    \\.migrations = "migrations",
    \\.sql_roots = .{ .app = "queries" },
    \\.zig_roots = ["src"],
    \\.backends = .{ .sqlite = .{ .profile = "3.53" } },
;

test "loads a complete project configuration with defaults" {
    var meta: ziggy.Deserializer.Meta = .init;
    const source = try std.testing.allocator.dupeZ(u8, valid);
    defer std.testing.allocator.free(source);
    var loaded = try config.parse(std.testing.allocator, source, &meta);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u32, 1), loaded.config().format_version);
    try std.testing.expectEqualStrings("migrations", loaded.config().migrations);
    try std.testing.expectEqualStrings(
        "queries",
        loaded.config().sql_roots.fields.get("app").?,
    );
    try std.testing.expectEqual(@as(u32, 30_000), loaded.config().migration_lock_timeout_ms);
}

test "Ziggy rejects unknown and duplicate fields" {
    var meta: ziggy.Deserializer.Meta = .init;
    const unknown = try std.testing.allocator.dupeZ(u8, valid ++ ".typo = true,\n");
    defer std.testing.allocator.free(unknown);
    try std.testing.expectError(
        error.UnknownField,
        config.parse(std.testing.allocator, unknown, &meta),
    );

    const duplicate = try std.testing.allocator.dupeZ(u8, valid ++ ".format_version = 1,\n");
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(
        error.DuplicateField,
        config.parse(std.testing.allocator, duplicate, &meta),
    );
}

test "semantic validation rejects unsafe project configuration" {
    var meta: ziggy.Deserializer.Meta = .init;
    const replaced = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid,
        "550e8400-e29b-41d4-a716-446655440000",
        "550e8400-e29b-11d4-a716-446655440000",
    );
    defer std.testing.allocator.free(replaced);
    const bad_uuid = try std.testing.allocator.dupeZ(u8, replaced);
    defer std.testing.allocator.free(bad_uuid);
    try std.testing.expectError(
        error.InvalidProjectId,
        config.parse(std.testing.allocator, bad_uuid, &meta),
    );
}

test "rejects unknown SQLite capability manifests" {
    var meta: ziggy.Deserializer.Meta = .init;
    const replaced = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid,
        ".{ .profile = \"3.53\" }",
        ".{ .profile = \"3.53\", .capabilities = \"custom\" }",
    );
    defer std.testing.allocator.free(replaced);
    const source = try std.testing.allocator.dupeZ(u8, replaced);
    defer std.testing.allocator.free(source);
    try std.testing.expectError(
        error.UnsupportedSqliteCapabilities,
        config.parse(std.testing.allocator, source, &meta),
    );
}

test "codec entries need an identifier ID and a database pattern" {
    var meta: ziggy.Deserializer.Meta = .init;

    const registered = try std.testing.allocator.dupeZ(
        u8,
        valid ++ ".codecs = .{ .user_id = .{ .sqlite_types = [\"BLOB\"] } },\n",
    );
    defer std.testing.allocator.free(registered);
    var loaded = try config.parse(std.testing.allocator, registered, &meta);
    defer loaded.deinit();
    try std.testing.expectEqualStrings(
        "BLOB",
        loaded.config().codecs.fields.get("user_id").?.sqlite_types[0],
    );

    const patternless = try std.testing.allocator.dupeZ(
        u8,
        valid ++ ".codecs = .{ .user_id = .{ .sqlite_types = [], .postgres_types = [] } },\n",
    );
    defer std.testing.allocator.free(patternless);
    try std.testing.expectError(
        error.MissingCodecPatterns,
        config.parse(std.testing.allocator, patternless, &meta),
    );
}

test "the project root is a valid source root, unlike a dot component" {
    var meta: ziggy.Deserializer.Meta = .init;

    const only_root =
        \\.format_version = 1,
        \\.project_id = "550e8400-e29b-41d4-a716-446655440000",
        \\.migrations = "migrations",
        \\.sql_roots = .{ .app = "queries" },
        \\.zig_roots = ["."],
        \\.backends = .{ .sqlite = .{ .profile = "3.53" } },
    ;
    const accepted = try std.testing.allocator.dupeZ(u8, only_root);
    defer std.testing.allocator.free(accepted);
    var loaded = try config.parse(std.testing.allocator, accepted, &meta);
    defer loaded.deinit();
    try std.testing.expectEqualStrings(".", loaded.config().zig_roots[0]);

    const unnormalized = try std.testing.allocator.dupeZ(u8,
        \\.format_version = 1,
        \\.project_id = "550e8400-e29b-41d4-a716-446655440000",
        \\.migrations = "migrations",
        \\.sql_roots = .{ .app = "queries" },
        \\.zig_roots = ["src/./queries"],
        \\.backends = .{ .sqlite = .{ .profile = "3.53" } },
    );
    defer std.testing.allocator.free(unnormalized);
    try std.testing.expectError(
        error.InvalidPath,
        config.parse(std.testing.allocator, unnormalized, &meta),
    );
}
