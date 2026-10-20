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

test "catalog supplements are rejected until they are loaded" {
    var meta: ziggy.Deserializer.Meta = .init;
    const source = try std.testing.allocator.dupeZ(
        u8,
        valid ++ ".catalog_supplements = [\"sqlz/catalog.ziggy\"],\n",
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectError(
        error.UnsupportedCatalogSupplements,
        config.parse(std.testing.allocator, source, &meta),
    );
}

test "root aliases may not use the generated module's reserved prefix" {
    var meta: ziggy.Deserializer.Meta = .init;
    for ([_][]const u8{ "sqlz", "sqlz_project" }) |alias| {
        const replacement = try std.fmt.allocPrint(std.testing.allocator, ".{{ .{s} = \"queries\" }}", .{alias});
        defer std.testing.allocator.free(replacement);
        const replaced = try std.mem.replaceOwned(
            u8,
            std.testing.allocator,
            valid,
            ".{ .app = \"queries\" }",
            replacement,
        );
        defer std.testing.allocator.free(replaced);
        const source = try std.testing.allocator.dupeZ(u8, replaced);
        defer std.testing.allocator.free(source);
        try std.testing.expectError(
            error.InvalidSqlRootAlias,
            config.parse(std.testing.allocator, source, &meta),
        );
    }
}

test "the loaded value outlives the caller's source buffer" {
    var meta: ziggy.Deserializer.Meta = .init;
    const source = try std.testing.allocator.dupeZ(u8, valid);
    var loaded = config.parse(std.testing.allocator, source, &meta) catch |err| {
        std.testing.allocator.free(source);
        return err;
    };
    defer loaded.deinit();
    @memset(source, 0);
    std.testing.allocator.free(source);
    try std.testing.expect(loaded.config().sql_roots.fields.get("app") != null);
    try std.testing.expectEqual(valid.len, loaded.source_len);
}

test "every format-1 field has exactly one documented use" {
    const nested = .{
        .{ "", config.Config },
        .{ "backends.sqlite.", config.Sqlite },
        .{ "backends.postgres.", config.Postgres },
        .{ "codecs.", config.Codec },
        .{ "limits.", config.Limits },
    };
    var expected: usize = 0;
    inline for (nested) |entry| {
        inline for (@typeInfo(entry[1]).@"struct".fields) |field| {
            const name = entry[0] ++ field.name;
            var matches: usize = 0;
            for (config.field_usage) |usage| {
                if (std.mem.eql(u8, usage.field, name)) matches += 1;
            }
            if (matches != 1) {
                std.debug.print("field `{s}` has {d} usage entries\n", .{ name, matches });
                return error.TestUnexpectedResult;
            }
            expected += 1;
        }
    }
    // Each field matched exactly one entry, so equal counts mean no entry
    // names a field that does not exist.
    try std.testing.expectEqual(expected, config.field_usage.len);
}

fn parseWithLimits(limits: []const u8) !config.Loaded {
    var meta: ziggy.Deserializer.Meta = .init;
    const text = try std.fmt.allocPrint(std.testing.allocator, "{s}\n.limits = .{{ {s} }},\n", .{ valid, limits });
    defer std.testing.allocator.free(text);
    const source = try std.testing.allocator.dupeZ(u8, text);
    defer std.testing.allocator.free(source);
    return config.parse(std.testing.allocator, source, &meta);
}

test "nesting_depth is bounded by the largest depth the parsers accept" {
    var at_bound = try parseWithLimits(".nesting_depth = 1024");
    at_bound.deinit();
    try std.testing.expectEqual(@as(u32, 1024), config.max_nesting_depth);
    try std.testing.expectError(error.InvalidLimit, parseWithLimits(".nesting_depth = 1025"));
    try std.testing.expectError(error.InvalidLimit, parseWithLimits(".tokens_per_source = 0"));
}

test "a configuration may start with a byte order mark" {
    var meta: ziggy.Deserializer.Meta = .init;
    const source = try std.testing.allocator.dupeZ(u8, "\xEF\xBB\xBF" ++ valid);
    defer std.testing.allocator.free(source);
    var loaded = try config.parse(std.testing.allocator, source, &meta);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("migrations", loaded.config().migrations);
}

test "a configuration that is not UTF-8 is rejected before parsing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sqlz.ziggy", .data = valid ++ "\n// \xFF\n" });
    try std.testing.expectError(error.InvalidUtf8, config.load(std.testing.allocator, std.testing.io, tmp.dir, "sqlz.ziggy"));
}
