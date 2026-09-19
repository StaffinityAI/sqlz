const std = @import("std");
const codegen = @import("sqlz_codegen");
const diagnostics = @import("sqlz_diagnostics");

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

test "project checking accumulates query diagnostics in source order" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeDiagnosticProject(&tmp, 10);
    var list: diagnostics.List = .init(std.testing.allocator, 100);
    defer list.deinit();
    try std.testing.expectError(error.ProjectCheckFailed, codegen.generateProjectWithCodecsAndDiagnostics(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "sqlz.ziggy",
        &.{},
        &list,
    ));
    try std.testing.expectEqual(@as(usize, 2), list.slice().len);
    try std.testing.expectEqualStrings("a.sql", list.slice()[0].primary.?.path);
    try std.testing.expectEqualStrings("b.sql", list.slice()[1].primary.?.path);
    try std.testing.expectEqualStrings("C001", list.slice()[0].code);
    try std.testing.expect(!list.truncated);
}

test "project diagnostic limit truncates deterministically" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeDiagnosticProject(&tmp, 1);
    var list: diagnostics.List = .init(std.testing.allocator, 100);
    defer list.deinit();
    try std.testing.expectError(error.ProjectCheckFailed, codegen.generateProjectWithCodecsAndDiagnostics(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "sqlz.ziggy",
        &.{},
        &list,
    ));
    try std.testing.expectEqual(@as(usize, 1), list.slice().len);
    try std.testing.expectEqualStrings("a.sql", list.slice()[0].primary.?.path);
    try std.testing.expect(list.truncated);
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

test "groups disjoint backend query variants" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeVariantProject(&tmp, false);

    const generated = try codegen.generateProject(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "sqlz.ziggy",
    );
    defer std.testing.allocator.free(generated);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, generated, "pub const search_users = sqlz.Query"));
    try std.testing.expect(std.mem.indexOf(u8, generated, "name LIKE :pattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "name ILIKE $1") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".parameter_names = .{ \"pattern\",") != null);
}

test "rejects backend variants with incompatible contracts" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeVariantProject(&tmp, true);

    try std.testing.expectError(
        error.IncompatibleBackendContract,
        codegen.generateProject(std.testing.allocator, std.testing.io, tmp.dir, "sqlz.ziggy"),
    );
}

test "generates PostgreSQL enum codecs and domain base types" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeCustomTypeProject(&tmp);
    const bindings = [_]codegen.CodecBinding{
        .{ .id = "role", .import_name = "sqlz_codec_role", .declaration = "Role" },
    };
    const generated = try codegen.generateProjectWithCodecs(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "sqlz.ziggy",
        &bindings,
    );
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "id: i64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "role: sqlz_codec_role.Role,") != null);
}

test "generates PostgreSQL array contracts" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeArrayProject(&tmp);
    const generated = try codegen.generateProject(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "sqlz.ziggy",
    );
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "tags: []const ?[]const u8,") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "ratings: ?[]const ?i32,") != null);
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

fn writeVariantProject(tmp: *std.testing.TmpDir, mismatch: bool) !void {
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
        .sub_path = "common.up.sql",
        .data = "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL)",
    });
    try migration.writeFile(std.testing.io, .{
        .sub_path = "common.down.sql",
        .data = "DROP TABLE users",
    });
    var queries = try tmp.dir.createDirPathOpen(std.testing.io, "queries/users", .{});
    defer queries.close(std.testing.io);
    try queries.writeFile(std.testing.io, .{
        .sub_path = "search.sqlite.sql",
        .data =
        \\-- sqlz.name: search_users
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: many
        \\
        \\SELECT id FROM users WHERE name LIKE :pattern
        ,
    });
    try queries.writeFile(std.testing.io, .{
        .sub_path = "search.postgres.sql",
        .data = if (mismatch)
            \\-- sqlz.name: search_users
            \\-- sqlz.backends: postgres
            \\-- sqlz.cardinality: optional
            \\
            \\SELECT id FROM users WHERE name ILIKE :pattern
        else
            \\-- sqlz.name: search_users
            \\-- sqlz.backends: postgres
            \\-- sqlz.cardinality: many
            \\
            \\SELECT id FROM users WHERE name ILIKE :pattern
        ,
    });
}

fn writeCustomTypeProject(tmp: *std.testing.TmpDir) !void {
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sqlz.ziggy",
        .data =
        \\.format_version = 1,
        \\.project_id = "550e8400-e29b-41d4-a716-446655440000",
        \\.migrations = "migrations",
        \\.sql_roots = .{ .app = "queries" },
        \\.zig_roots = [],
        \\.backends = .{ .postgres = .{ .profile = "15", .search_path = ["app"] } },
        \\.codecs = .{ .role = .{ .postgres_types = ["app.user_role"] } },
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
        \\.backends = [.postgres],
        \\.reversible = true,
        \\.transaction = .{ .postgres = .always },
        ,
    });
    try migration.writeFile(std.testing.io, .{
        .sub_path = "postgres.up.sql",
        .data = "CREATE DOMAIN app.user_id AS BIGINT;" ++
            "CREATE TYPE app.user_role AS ENUM ('member', 'admin');" ++
            "CREATE TABLE app.users (id app.user_id PRIMARY KEY, role app.user_role NOT NULL)",
    });
    try migration.writeFile(std.testing.io, .{
        .sub_path = "postgres.down.sql",
        .data = "DROP TABLE app.users; DROP TYPE app.user_role; DROP DOMAIN app.user_id",
    });
    var queries = try tmp.dir.createDirPathOpen(std.testing.io, "queries", .{});
    defer queries.close(std.testing.io);
    try queries.writeFile(std.testing.io, .{
        .sub_path = "by_role.sql",
        .data =
        \\-- sqlz.name: users_by_role
        \\-- sqlz.backends: postgres
        \\-- sqlz.cardinality: many
        \\-- sqlz.param.role: role
        \\-- sqlz.column.role: role
        \\
        \\SELECT id, role FROM users WHERE role=:role
        ,
    });
}

fn writeArrayProject(tmp: *std.testing.TmpDir) !void {
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sqlz.ziggy",
        .data =
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
        "migrations/aaaaaaaaaaaa_create_posts",
        .{},
    );
    defer migration.close(std.testing.io);
    try migration.writeFile(std.testing.io, .{
        .sub_path = "revision.ziggy",
        .data =
        \\.format_version = 1,
        \\.revision = "aaaaaaaaaaaa",
        \\.parents = [],
        \\.description = "create posts",
        \\.created_utc = "2026-09-18T12:00:00Z",
        \\.backends = [.postgres],
        \\.reversible = true,
        \\.transaction = .{ .postgres = .always },
        ,
    });
    try migration.writeFile(std.testing.io, .{
        .sub_path = "postgres.up.sql",
        .data = "CREATE TABLE posts (id BIGINT PRIMARY KEY, tags TEXT[] NOT NULL, ratings INTEGER[])",
    });
    try migration.writeFile(std.testing.io, .{
        .sub_path = "postgres.down.sql",
        .data = "DROP TABLE posts",
    });
    var queries = try tmp.dir.createDirPathOpen(std.testing.io, "queries", .{});
    defer queries.close(std.testing.io);
    try queries.writeFile(std.testing.io, .{
        .sub_path = "list.sql",
        .data =
        \\-- sqlz.name: list_posts
        \\-- sqlz.backends: postgres
        \\-- sqlz.cardinality: many
        \\
        \\SELECT tags, ratings FROM posts
        ,
    });
}

fn writeDiagnosticProject(tmp: *std.testing.TmpDir, limit: u32) !void {
    const config_source = try std.fmt.allocPrint(std.testing.allocator,
        \\.format_version = 1,
        \\.project_id = "550e8400-e29b-41d4-a716-446655440000",
        \\.migrations = "migrations",
        \\.sql_roots = .{{ .app = "queries" }},
        \\.zig_roots = [],
        \\.backends = .{{ .sqlite = .{{ .profile = "3.53" }} }},
        \\.limits = .{{ .diagnostics = {d} }},
    , .{limit});
    defer std.testing.allocator.free(config_source);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sqlz.ziggy", .data = config_source });
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
        \\.backends = [.sqlite],
        \\.reversible = true,
        \\.transaction = .{ .sqlite = .always },
        ,
    });
    try migration.writeFile(std.testing.io, .{
        .sub_path = "common.up.sql",
        .data = "CREATE TABLE users (id BIGINT PRIMARY KEY)",
    });
    try migration.writeFile(std.testing.io, .{
        .sub_path = "common.down.sql",
        .data = "DROP TABLE users",
    });
    var queries = try tmp.dir.createDirPathOpen(std.testing.io, "queries", .{});
    defer queries.close(std.testing.io);
    const first =
        \\-- sqlz.name: first
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: many
        \\
        \\SELECT missing_a FROM users
    ;
    const second =
        \\-- sqlz.name: second
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: many
        \\
        \\SELECT missing_b FROM users
    ;
    try queries.writeFile(std.testing.io, .{ .sub_path = "a.sql", .data = first });
    try queries.writeFile(std.testing.io, .{ .sub_path = "b.sql", .data = second });
}
