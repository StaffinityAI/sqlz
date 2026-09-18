const std = @import("std");
const analysis = @import("sqlz_analysis");
const checker = @import("sqlz_checker");
const catalog = @import("sqlz_catalog");
const migrations = @import("sqlz_migrations");
const query_files = @import("sqlz_query_files");
const zig_queries = @import("sqlz_zig_queries");

test "replays SQLite migrations in graph order" {
    const inputs = [_]checker.MigrationInput{
        .{
            .revision = .{ .id = "dddddddddddd", .parents = &.{ "bbbbbbbbbbbb", "cccccccccccc" } },
            .common_sql = "CREATE UNIQUE INDEX accounts_email_key ON accounts(email)",
        },
        .{
            .revision = .{ .id = "cccccccccccc", .parents = &.{"aaaaaaaaaaaa"} },
            .common_sql = "ALTER TABLE accounts ADD COLUMN email TEXT NOT NULL;" ++
                "CREATE TABLE profiles (id BIGINT PRIMARY KEY)",
        },
        .{
            .revision = .{ .id = "aaaaaaaaaaaa", .parents = &.{} },
            .common_sql = "CREATE TABLE accounts (id BIGINT PRIMARY KEY)",
        },
        .{
            .revision = .{ .id = "bbbbbbbbbbbb", .parents = &.{"aaaaaaaaaaaa"} },
            .common_sql = "ALTER TABLE accounts ADD COLUMN email TEXT NOT NULL;" ++
                "CREATE TABLE profiles (id BIGINT PRIMARY KEY)",
        },
    };

    var schema = try checker.replaySqlite(std.testing.allocator, &inputs);
    defer schema.deinit();
    try std.testing.expect(schema.table("profiles") != null);
    try std.testing.expect(!schema.table("accounts").?.columns.get("email").?.nullable);
    try std.testing.expect(schema.indexes.get("accounts_email_key").?.unique);
}

test "a failed revision leaves the prior catalog unchanged" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applySqliteRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY)",
        "",
    );

    try std.testing.expectError(
        error.DuplicateTable,
        checker.applySqliteRevisionAtomic(
            &schema,
            std.testing.allocator,
            "ALTER TABLE users ADD COLUMN active BOOLEAN NOT NULL;" ++
                "CREATE TABLE users (other BIGINT)",
            "",
        ),
    );
    try std.testing.expect(schema.table("users").?.columns.get("active") == null);
}

test "ordered replay rejects an invalid graph before applying SQL" {
    const inputs = [_]checker.MigrationInput{
        .{
            .revision = migrations.Revision{
                .id = "aaaaaaaaaaaa",
                .parents = &.{"bbbbbbbbbbbb"},
            },
            .common_sql = "CREATE TABLE should_not_exist (id BIGINT)",
        },
    };
    try std.testing.expectError(
        error.MissingParent,
        checker.replaySqlite(std.testing.allocator, &inputs),
    );
}

test "replays PostgreSQL common and backend SQL" {
    const inputs = [_]checker.MigrationInput{
        .{
            .revision = .{ .id = "aaaaaaaaaaaa", .parents = &.{} },
            .common_sql = "CREATE TABLE accounts (id BIGINT PRIMARY KEY, email TEXT NOT NULL)",
            .postgres_sql = "CREATE UNIQUE INDEX accounts_email_key ON accounts(email)",
        },
    };

    var schema = try checker.replayPostgresWithDialect(
        std.testing.allocator,
        &inputs,
        .{ .profile = .v18 },
    );
    defer schema.deinit();
    try std.testing.expect(schema.table("accounts") != null);
    try std.testing.expect(schema.indexes.get("accounts_email_key").?.unique);
}

test "PostgreSQL replay ignores SQLite-specific SQL" {
    const inputs = [_]checker.MigrationInput{
        .{
            .revision = .{ .id = "aaaaaaaaaaaa", .parents = &.{} },
            .common_sql = "CREATE TABLE accounts (id BIGINT PRIMARY KEY)",
            .sqlite_sql = "CREATE TABLE sqlite_only (id BIGINT)",
            .postgres_sql = "CREATE TABLE postgres_only (id BIGINT)",
        },
    };

    var schema = try checker.replayPostgres(std.testing.allocator, &inputs);
    defer schema.deinit();
    try std.testing.expect(schema.table("accounts") != null);
    try std.testing.expect(schema.table("postgres_only") != null);
    try std.testing.expect(schema.table("sqlite_only") == null);
}

test "a failed PostgreSQL revision leaves the prior catalog unchanged" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applyPostgresRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY)",
        "",
    );

    try std.testing.expectError(
        error.DuplicateTable,
        checker.applyPostgresRevisionAtomic(
            &schema,
            std.testing.allocator,
            "ALTER TABLE users ADD COLUMN active BOOLEAN NOT NULL;" ++
                "CREATE TABLE users (other BIGINT)",
            "",
        ),
    );
    try std.testing.expect(schema.table("users").?.columns.get("active") == null);
}

test "merge replay accepts convergent parent catalogs" {
    const inputs = [_]checker.MigrationInput{
        .{
            .revision = .{ .id = "aaaaaaaaaaaa", .parents = &.{} },
            .common_sql = "CREATE TABLE accounts (id BIGINT PRIMARY KEY)",
        },
        .{
            .revision = .{ .id = "bbbbbbbbbbbb", .parents = &.{"aaaaaaaaaaaa"} },
        },
        .{
            .revision = .{ .id = "cccccccccccc", .parents = &.{"aaaaaaaaaaaa"} },
        },
        .{
            .revision = .{ .id = "dddddddddddd", .parents = &.{ "bbbbbbbbbbbb", "cccccccccccc" } },
            .common_sql = "ALTER TABLE accounts ADD COLUMN email TEXT",
        },
    };

    var schema = try checker.replayPostgres(std.testing.allocator, &inputs);
    defer schema.deinit();
    try std.testing.expect(schema.table("accounts").?.columns.get("email") != null);
}

test "merge replay rejects divergent parent catalogs" {
    const inputs = [_]checker.MigrationInput{
        .{
            .revision = .{ .id = "aaaaaaaaaaaa", .parents = &.{} },
            .common_sql = "CREATE TABLE accounts (id BIGINT PRIMARY KEY)",
        },
        .{
            .revision = .{ .id = "bbbbbbbbbbbb", .parents = &.{"aaaaaaaaaaaa"} },
            .common_sql = "ALTER TABLE accounts ADD COLUMN email TEXT",
        },
        .{
            .revision = .{ .id = "cccccccccccc", .parents = &.{"aaaaaaaaaaaa"} },
            .common_sql = "ALTER TABLE accounts ADD COLUMN name TEXT",
        },
        .{
            .revision = .{ .id = "dddddddddddd", .parents = &.{ "bbbbbbbbbbbb", "cccccccccccc" } },
        },
    };

    try std.testing.expectError(
        error.DivergentMerge,
        checker.replayPostgres(std.testing.allocator, &inputs),
    );
}

test "checks a named PostgreSQL query against replayed migrations" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applyPostgresRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL)",
        "",
    );
    var source = try query_files.parse(std.testing.allocator, "get_user.sql",
        \\-- sqlz.name: get_user
        \\-- sqlz.backends: postgres
        \\-- sqlz.cardinality: optional
        \\
        \\SELECT id, name FROM users WHERE id=:id
    );
    defer source.deinit();
    var checked = try checker.checkNamedPostgres(std.testing.allocator, &schema, &source);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 1), checked.analysis.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), checked.analysis.columns.len);
    try std.testing.expectEqualStrings("SELECT id, name FROM users WHERE id=$1", checked.parsed.rewritten.sql);
}

test "PostgreSQL codecs resolve against PostgreSQL type patterns" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applyPostgresRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE accounts (id BIGINT PRIMARY KEY, tier INTEGER NOT NULL)",
        "",
    );
    var source = try query_files.parse(std.testing.allocator, "accounts/by_tier.sql",
        \\-- sqlz.name: accounts_by_tier
        \\-- sqlz.backends: postgres
        \\-- sqlz.cardinality: many
        \\-- sqlz.param.tier: tier
        \\-- sqlz.column.tier: tier
        \\
        \\SELECT id, tier FROM accounts WHERE tier=:tier
    );
    defer source.deinit();
    const codecs = [_]checker.CodecInfo{.{ .id = "tier", .postgres_type = .integer }};
    var checked = try checker.checkNamedPostgresWithCodecs(
        std.testing.allocator,
        &schema,
        &source,
        .{},
        &codecs,
    );
    defer checked.deinit();
    try std.testing.expectEqualStrings("tier", checked.analysis.parameters[0].codec.?);
    try std.testing.expectEqualStrings("tier", checked.analysis.columns[1].codec.?);
}

test "PostgreSQL resolves qualified and search-path relations" {
    const inputs = [_]checker.MigrationInput{
        .{
            .revision = .{ .id = "aaaaaaaaaaaa", .parents = &.{} },
            .postgres_sql = "CREATE TABLE app.users (id BIGINT PRIMARY KEY, name TEXT NOT NULL)",
        },
    };
    var schema = try checker.replayPostgres(std.testing.allocator, &inputs);
    defer schema.deinit();
    try schema.setPostgresSearchPath(&.{ "app", "public" });

    var unqualified = try query_files.parse(std.testing.allocator, "users/get.sql",
        \\-- sqlz.name: get_user
        \\-- sqlz.backends: postgres
        \\-- sqlz.cardinality: optional
        \\
        \\SELECT id, name FROM users WHERE id=:id
    );
    defer unqualified.deinit();
    var checked_unqualified = try checker.checkNamedPostgres(
        std.testing.allocator,
        &schema,
        &unqualified,
    );
    defer checked_unqualified.deinit();

    var qualified = try query_files.parse(std.testing.allocator, "users/get_qualified.sql",
        \\-- sqlz.name: get_qualified_user
        \\-- sqlz.backends: postgres
        \\-- sqlz.cardinality: optional
        \\
        \\SELECT users.id, users.name FROM app.users WHERE users.id=:id
    );
    defer qualified.deinit();
    var checked_qualified = try checker.checkNamedPostgres(
        std.testing.allocator,
        &schema,
        &qualified,
    );
    defer checked_qualified.deinit();
    try std.testing.expectEqual(@as(usize, 2), checked_qualified.analysis.columns.len);
}

test "PostgreSQL domains use their base scalar and enums require a matching codec" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applyPostgresRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE DOMAIN app.user_id AS BIGINT;" ++
            "CREATE TYPE app.user_role AS ENUM ('member', 'admin');" ++
            "CREATE TABLE app.users (id app.user_id PRIMARY KEY, role app.user_role NOT NULL)",
        "",
    );
    try schema.setPostgresSearchPath(&.{"app"});
    var source = try query_files.parse(std.testing.allocator, "users/by_role.sql",
        \\-- sqlz.name: users_by_role
        \\-- sqlz.backends: postgres
        \\-- sqlz.cardinality: many
        \\-- sqlz.param.role: role
        \\-- sqlz.column.role: role
        \\
        \\SELECT id, role FROM users WHERE role=:role
    );
    defer source.deinit();
    const patterns = [_][]const u8{"app.user_role"};
    const codecs = [_]checker.CodecInfo{.{
        .id = "role",
        .postgres_patterns = &patterns,
    }};
    var checked = try checker.checkNamedPostgresWithCodecs(
        std.testing.allocator,
        &schema,
        &source,
        .{},
        &codecs,
    );
    defer checked.deinit();
    try std.testing.expectEqual(analysis.ScalarType.integer, checked.analysis.columns[0].scalar_type);
    try std.testing.expectEqualStrings("app.user_id", checked.analysis.columns[0].database_type.?);
    try std.testing.expectEqualStrings("role", checked.analysis.parameters[0].codec.?);
    try std.testing.expectEqualStrings("role", checked.analysis.columns[1].codec.?);

    const wrong_patterns = [_][]const u8{"app.other_role"};
    const wrong = [_]checker.CodecInfo{.{
        .id = "role",
        .postgres_patterns = &wrong_patterns,
    }};
    try std.testing.expectError(error.IncompatibleCodec, checker.checkNamedPostgresWithCodecs(
        std.testing.allocator,
        &schema,
        &source,
        .{},
        &wrong,
    ));
}

test "PostgreSQL arrays infer element types and nullability" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applyPostgresRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE posts (id BIGINT PRIMARY KEY, tags TEXT[] NOT NULL, ratings INTEGER[])",
        "",
    );
    var source = try query_files.parse(std.testing.allocator, "posts/by_tags.sql",
        \\-- sqlz.name: posts_by_tags
        \\-- sqlz.backends: postgres
        \\-- sqlz.cardinality: many
        \\
        \\SELECT tags, ratings FROM posts WHERE tags=:tags
    );
    defer source.deinit();
    var checked = try checker.checkNamedPostgres(std.testing.allocator, &schema, &source);
    defer checked.deinit();
    try std.testing.expectEqual(analysis.ScalarType.text, checked.analysis.parameters[0].scalar_type);
    try std.testing.expectEqual(@as(u8, 1), checked.analysis.parameters[0].array_dimensions);
    try std.testing.expect(!checked.analysis.parameters[0].nullable);
    try std.testing.expect(checked.analysis.parameters[0].element_nullable);
    try std.testing.expectEqual(@as(u8, 1), checked.analysis.columns[0].array_dimensions);
    try std.testing.expect(!checked.analysis.columns[0].nullable);
    try std.testing.expectEqual(analysis.ScalarType.integer, checked.analysis.columns[1].scalar_type);
    try std.testing.expect(checked.analysis.columns[1].nullable);
}

test "PostgreSQL array codecs require an array type pattern" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applyPostgresRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TYPE app.user_role AS ENUM ('member', 'admin');" ++
            "CREATE TABLE app.teams (roles app.user_role[] NOT NULL)",
        "",
    );
    try schema.setPostgresSearchPath(&.{"app"});
    var source = try query_files.parse(std.testing.allocator, "teams/roles.sql",
        \\-- sqlz.name: team_roles
        \\-- sqlz.backends: postgres
        \\-- sqlz.cardinality: many
        \\-- sqlz.column.roles: role
        \\
        \\SELECT roles FROM teams
    );
    defer source.deinit();
    const scalar_patterns = [_][]const u8{"app.user_role"};
    const scalar_codec = [_]checker.CodecInfo{.{
        .id = "role",
        .postgres_patterns = &scalar_patterns,
    }};
    try std.testing.expectError(error.IncompatibleCodec, checker.checkNamedPostgresWithCodecs(
        std.testing.allocator,
        &schema,
        &source,
        .{},
        &scalar_codec,
    ));
    const array_patterns = [_][]const u8{"app.user_role[]"};
    const array_codec = [_]checker.CodecInfo{.{
        .id = "role",
        .postgres_patterns = &array_patterns,
    }};
    var checked = try checker.checkNamedPostgresWithCodecs(
        std.testing.allocator,
        &schema,
        &source,
        .{},
        &array_codec,
    );
    defer checked.deinit();
    try std.testing.expectEqualStrings("role", checked.analysis.columns[0].codec.?);
}

test "embedded PostgreSQL array declarations require nullable elements" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applyPostgresRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE posts (tags TEXT[] NOT NULL)",
        "",
    );
    var valid = try zig_queries.parse(std.testing.allocator, "src/posts.zig",
        \\const sqlz = @import("sqlz");
        \\pub const list = sqlz.Query(.{
        \\    .sql = "SELECT tags FROM posts",
        \\    .backends = .{ .postgres = true },
        \\    .cardinality = .many,
        \\    .row = struct { tags: []const ?[]const u8 },
        \\});
    );
    defer valid.deinit();
    var checked = try checker.checkNamedPostgres(
        std.testing.allocator,
        &schema,
        &valid.sources[0],
    );
    checked.deinit();

    var invalid = try zig_queries.parse(std.testing.allocator, "src/posts.zig",
        \\const sqlz = @import("sqlz");
        \\pub const list = sqlz.Query(.{
        \\    .sql = "SELECT tags FROM posts",
        \\    .backends = .{ .postgres = true },
        \\    .cardinality = .many,
        \\    .row = struct { tags: []const []const u8 },
        \\});
    );
    defer invalid.deinit();
    try std.testing.expectError(error.DeclaredTypeMismatch, checker.checkNamedPostgres(
        std.testing.allocator,
        &schema,
        &invalid.sources[0],
    ));
}

test "discovery and replay apply common SQL before SQLite SQL" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var revision = try tmp.dir.createDirPathOpen(
        std.testing.io,
        "aaaaaaaaaaaa_create_users",
        .{},
    );
    defer revision.close(std.testing.io);
    try revision.writeFile(std.testing.io, .{
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
    try revision.writeFile(std.testing.io, .{
        .sub_path = "common.up.sql",
        .data = "CREATE TABLE users (id BIGINT PRIMARY KEY, email TEXT)",
    });
    try revision.writeFile(std.testing.io, .{
        .sub_path = "sqlite.up.sql",
        .data = "CREATE UNIQUE INDEX users_email_key ON users(email)",
    });
    try revision.writeFile(std.testing.io, .{
        .sub_path = "common.down.sql",
        .data = "DROP TABLE users",
    });

    var discovery = try migrations.discover(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        1024 * 1024,
    );
    defer discovery.deinit();
    var schema = try checker.replayDiscoveredSqlite(std.testing.allocator, &discovery);
    defer schema.deinit();
    try std.testing.expect(schema.table("users") != null);
    try std.testing.expect(schema.indexes.get("users_email_key").?.unique);
}

test "checks a named SQLite query against the replayed catalog" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applySqliteRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL)",
        "",
    );
    var source = try query_files.parse(std.testing.allocator, "get_user.sql",
        \\-- sqlz.name: get_user
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: optional
        \\
        \\SELECT id, name FROM users WHERE id=:id
    );
    defer source.deinit();
    var checked = try checker.checkNamedSqlite(std.testing.allocator, &schema, &source);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 1), checked.analysis.parameters.len);
    try std.testing.expectEqual(@as(usize, 2), checked.analysis.columns.len);
}

test "checks a named query against a migration-defined view" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applySqliteRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL);" ++
            "CREATE VIEW user_names AS SELECT id AS user_id, name FROM users",
        "",
    );
    var source = try query_files.parse(std.testing.allocator, "list_user_names.sql",
        \\-- sqlz.name: list_user_names
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: many
        \\
        \\SELECT user_id, name FROM user_names
    );
    defer source.deinit();
    var checked = try checker.checkNamedSqlite(std.testing.allocator, &schema, &source);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 2), checked.analysis.columns.len);
    try std.testing.expectEqualStrings("user_id", checked.analysis.columns[0].name);
    try std.testing.expect(!checked.analysis.columns[1].nullable);
}

test "replays SQLite table options and checks INSERT OR IGNORE" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applySqliteRevisionAtomic(
        &schema,
        std.testing.allocator,
        "",
        "CREATE TABLE memberships (" ++
            "user_id INTEGER NOT NULL, role_id INTEGER NOT NULL, " ++
            "PRIMARY KEY (user_id, role_id)) WITHOUT ROWID;" ++
            "CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT) STRICT",
    );
    try std.testing.expect(schema.table("memberships") != null);
    try std.testing.expect(schema.table("notes") != null);

    var source = try query_files.parse(std.testing.allocator, "assign_role.sql",
        \\-- sqlz.name: assign_role
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: exec
        \\
        \\INSERT OR IGNORE INTO memberships(user_id, role_id) VALUES (:user_id, :role_id)
    );
    defer source.deinit();
    var checked = try checker.checkNamedSqlite(std.testing.allocator, &schema, &source);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 2), checked.analysis.parameters.len);
}

test "uses the selected SQLite profile for checked queries" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    var source = try query_files.parse(std.testing.allocator, "profile_literal.sql",
        \\-- sqlz.name: profile_literal
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: one
        \\SELECT 1_000 AS total
    );
    defer source.deinit();

    try std.testing.expectError(
        error.UnsupportedSqliteFeature,
        checker.checkNamedSqliteWithDialect(
            std.testing.allocator,
            &schema,
            &source,
            .{ .profile = .v3_45 },
        ),
    );
}

const declaration_schema =
    "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL, label TEXT)";

/// Wraps one embedded declaration in a file, checks it against a fixed schema,
/// and reports what the checker made of the declared structs.
fn checkDeclaration(body: [:0]const u8, codecs: []const checker.CodecInfo) !void {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applySqliteRevisionAtomic(
        &schema,
        std.testing.allocator,
        declaration_schema,
        "",
    );
    var discovery = try zig_queries.parse(std.testing.allocator, "src/users.zig", body);
    defer discovery.deinit();
    try std.testing.expectEqual(@as(usize, 1), discovery.sources.len);
    var checked = try checker.checkNamedSqliteWithCodecs(
        std.testing.allocator,
        &schema,
        &discovery.sources[0],
        .{},
        codecs,
    );
    checked.deinit();
}

test "an embedded declaration agreeing with its SQL passes" {
    try checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id, name, label FROM users WHERE id=:id",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .optional,
        \\    .params = struct { id: i64 },
        \\    .row = struct { id: i64, name: []const u8, label: ?[]const u8 },
        \\});
    , &.{});
}

test "a row struct may widen a known non-null column to optional" {
    try checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id, name FROM users WHERE id=:id",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .optional,
        \\    .params = struct { id: i64 },
        \\    .row = struct { id: ?i64, name: []const u8 },
        \\});
    , &.{});
}

test "a named row struct in the same file is verified like an inline one" {
    try std.testing.expectError(error.DeclaredTypeMismatch, checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\const User = struct { id: []const u8, name: []const u8 };
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id, name FROM users WHERE id=:id",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .optional,
        \\    .params = struct { id: i64 },
        \\    .row = User,
        \\});
    , &.{}));
}

test "a row struct missing or gaining a field is reported" {
    try std.testing.expectError(error.MissingDeclaredField, checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id, name FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = struct { id: i64 },
        \\});
    , &.{}));

    try std.testing.expectError(error.UnexpectedDeclaredField, checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id, name FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = struct { id: i64, name: []const u8, extra: i64 },
        \\});
    , &.{}));
}

test "declaring the right fields in the wrong order is reported" {
    try std.testing.expectError(error.DeclaredFieldOrder, checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id, name FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = struct { name: []const u8, id: i64 },
        \\});
    , &.{}));
}

test "a nullable column cannot decode into a non-optional field" {
    try std.testing.expectError(error.DeclaredNullabilityMismatch, checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT label FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = struct { label: []const u8 },
        \\});
    , &.{}));
}

test "a required parameter cannot be declared optional" {
    try std.testing.expectError(error.DeclaredNullabilityMismatch, checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users WHERE id=:id",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .optional,
        \\    .params = struct { id: ?i64 },
        \\    .row = struct { id: i64 },
        \\});
    , &.{}));
}

test "omitting the parameter struct of a parameterized query is reported" {
    try std.testing.expectError(error.MissingDeclaredField, checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users WHERE id=:id",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .optional,
        \\    .row = struct { id: i64 },
        \\});
    , &.{}));
}

test "a field type that cannot carry its column is reported" {
    try std.testing.expectError(error.DeclaredTypeMismatch, checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = struct { id: []const u8 },
        \\});
    , &.{}));
}

test "any integer or float width may carry its column" {
    try checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = struct { id: u32 },
        \\});
    , &.{});
}

test "a custom field type needs a codec entry" {
    const body: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = struct { id: Tier },
        \\});
    ;
    try std.testing.expectError(error.MissingCodecForDeclaredType, checkDeclaration(body, &.{}));

    const mapped: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .column_codecs = .{ .id = "tier" },
        \\    .row = struct { id: Tier },
        \\});
    ;
    const codecs = [_]checker.CodecInfo{.{ .id = "tier", .sqlite_type = .integer }};
    try checkDeclaration(mapped, &codecs);
}

test "a codec pinned to a built-in field is reported" {
    const body: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .column_codecs = .{ .id = "tier" },
        \\    .row = struct { id: i64 },
        \\});
    ;
    const codecs = [_]checker.CodecInfo{.{ .id = "tier", .sqlite_type = .integer }};
    try std.testing.expectError(error.DeclaredTypeMismatch, checkDeclaration(body, &codecs));
}

test "the row struct must match the declared cardinality" {
    try std.testing.expectError(error.MissingDeclaredRow, checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\});
    , &.{}));

    try std.testing.expectError(error.UnexpectedDeclaredRow, checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\pub const remove = sqlz.Query(.{
        \\    .sql = "DELETE FROM users WHERE id=:id",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .exec,
        \\    .params = struct { id: i64 },
        \\    .row = struct { id: i64 },
        \\});
    , &.{}));
}

test "a declared type the checker cannot read is left unverified" {
    try checkDeclaration(
        \\const sqlz = @import("sqlz");
        \\const types = @import("types");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id, name FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = types.User,
        \\});
    , &.{});
}
