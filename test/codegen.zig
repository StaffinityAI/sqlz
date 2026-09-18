const std = @import("std");
const codegen = @import("sqlz_codegen");

test "generates a PostgreSQL-only project" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeProject(&tmp, false);

    const generated = try codegen.generateProject(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "sqlz.ziggy",
    );
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".postgres = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".sqlite = true") == null);
}

test "portable project queries require matching backend contracts" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeProject(&tmp, true);

    try std.testing.expectError(
        error.IncompatibleBackendContract,
        codegen.generateProject(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            "sqlz.ziggy",
        ),
    );
}

test "portable codecs may bridge different backend scalar types" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeCodecProject(&tmp);

    const bindings = [_]codegen.CodecBinding{
        .{ .id = "user_id", .import_name = "sqlz_codec_user_id", .declaration = "UserId" },
    };
    const generated = try codegen.generateProjectWithCodecs(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "sqlz.ziggy",
        &bindings,
    );
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "sqlz_codec_user_id.UserId") != null);
}

fn writeProject(tmp: *std.testing.TmpDir, mismatch: bool) !void {
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sqlz.ziggy",
        .data = if (mismatch)
            \\.format_version = 1,
            \\.project_id = "550e8400-e29b-41d4-a716-446655440000",
            \\.migrations = "migrations",
            \\.sql_roots = .{ .app = "queries" },
            \\.zig_roots = [],
            \\.backends = .{
            \\    .sqlite = .{ .profile = "3.53" },
            \\    .postgres = .{ .profile = "15" },
            \\},
        else
            \\.format_version = 1,
            \\.project_id = "550e8400-e29b-41d4-a716-446655440000",
            \\.migrations = "migrations",
            \\.sql_roots = .{ .app = "queries" },
            \\.zig_roots = [],
            \\.backends = .{ .postgres = .{ .profile = "15" } },
        ,
    });
    var migration = try tmp.dir.createDirPathOpen(
        std.testing.io,
        "migrations/aaaaaaaaaaaa_create_users",
        .{},
    );
    defer migration.close(std.testing.io);
    try migration.writeFile(std.testing.io, .{
        .sub_path = "revision.ziggy",
        .data = if (mismatch)
            \\.format_version = 1,
            \\.revision = "aaaaaaaaaaaa",
            \\.parents = [],
            \\.description = "create users",
            \\.created_utc = "2026-09-18T12:00:00Z",
            \\.backends = [.sqlite, .postgres],
            \\.reversible = true,
            \\.transaction = .{ .sqlite = .always, .postgres = .always },
        else
            \\.format_version = 1,
            \\.revision = "aaaaaaaaaaaa",
            \\.parents = [],
            \\.description = "create users",
            \\.created_utc = "2026-09-18T12:00:00Z",
            \\.backends = [.postgres],
            \\.reversible = true,
            \\.transaction = .{ .postgres = .always },
        ,
    });
    if (mismatch) {
        try migration.writeFile(std.testing.io, .{
            .sub_path = "sqlite.up.sql",
            .data = "CREATE TABLE users (id INTEGER PRIMARY KEY)",
        });
        try migration.writeFile(std.testing.io, .{
            .sub_path = "sqlite.down.sql",
            .data = "DROP TABLE users",
        });
        try migration.writeFile(std.testing.io, .{
            .sub_path = "postgres.up.sql",
            .data = "CREATE TABLE users (id TEXT PRIMARY KEY)",
        });
        try migration.writeFile(std.testing.io, .{
            .sub_path = "postgres.down.sql",
            .data = "DROP TABLE users",
        });
    } else {
        try migration.writeFile(std.testing.io, .{
            .sub_path = "postgres.up.sql",
            .data = "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL)",
        });
        try migration.writeFile(std.testing.io, .{
            .sub_path = "postgres.down.sql",
            .data = "DROP TABLE users",
        });
    }
    var queries = try tmp.dir.createDirPathOpen(std.testing.io, "queries", .{});
    defer queries.close(std.testing.io);
    try queries.writeFile(std.testing.io, .{
        .sub_path = "get_user.sql",
        .data = if (mismatch)
            \\-- sqlz.name: get_user
            \\-- sqlz.backends: sqlite, postgres
            \\-- sqlz.cardinality: optional
            \\
            \\SELECT id FROM users WHERE id=:id
        else
            \\-- sqlz.name: get_user
            \\-- sqlz.backends: postgres
            \\-- sqlz.cardinality: optional
            \\
            \\SELECT id, name FROM users WHERE id=:id
        ,
    });
}

fn writeCodecProject(tmp: *std.testing.TmpDir) !void {
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sqlz.ziggy",
        .data =
        \\.format_version = 1,
        \\.project_id = "550e8400-e29b-41d4-a716-446655440000",
        \\.migrations = "migrations",
        \\.sql_roots = .{ .app = "queries" },
        \\.zig_roots = [],
        \\.backends = .{
        \\    .sqlite = .{ .profile = "3.53" },
        \\    .postgres = .{ .profile = "15" },
        \\},
        \\.codecs = .{
        \\    .user_id = .{ .sqlite_types = ["INTEGER"], .postgres_types = ["TEXT"] },
        \\},
        ,
    });
    var migration = try tmp.dir.createDirPathOpen(
        std.testing.io,
        "migrations/aaaaaaaaaaaa_create_users",
        .{},
    );
    defer migration.close(std.testing.io);
    try migration.writeFile(std.testing.io, .{
        .sub_path = "revision.ziggy",
        .data =
        \\.format_version = 1,
        \\.revision = "aaaaaaaaaaaa",
        \\.parents = [],
        \\.description = "create users",
        \\.created_utc = "2026-09-18T12:00:00Z",
        \\.backends = [.sqlite, .postgres],
        \\.reversible = true,
        \\.transaction = .{ .sqlite = .always, .postgres = .always },
        ,
    });
    try migration.writeFile(std.testing.io, .{
        .sub_path = "sqlite.up.sql",
        .data = "CREATE TABLE users (id INTEGER PRIMARY KEY)",
    });
    try migration.writeFile(std.testing.io, .{
        .sub_path = "sqlite.down.sql",
        .data = "DROP TABLE users",
    });
    try migration.writeFile(std.testing.io, .{
        .sub_path = "postgres.up.sql",
        .data = "CREATE TABLE users (id TEXT PRIMARY KEY)",
    });
    try migration.writeFile(std.testing.io, .{
        .sub_path = "postgres.down.sql",
        .data = "DROP TABLE users",
    });
    var queries = try tmp.dir.createDirPathOpen(std.testing.io, "queries", .{});
    defer queries.close(std.testing.io);
    try queries.writeFile(std.testing.io, .{
        .sub_path = "get_user.sql",
        .data =
        \\-- sqlz.name: get_user
        \\-- sqlz.backends: sqlite, postgres
        \\-- sqlz.cardinality: optional
        \\-- sqlz.param.id: user_id
        \\-- sqlz.column.id: user_id
        \\
        \\SELECT id FROM users WHERE id=:id
        ,
    });
}
