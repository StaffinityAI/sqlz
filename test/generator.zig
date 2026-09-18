const std = @import("std");
const catalog = @import("sqlz_catalog");
const checker = @import("sqlz_checker");
const generator = @import("sqlz_generator");
const query_files = @import("sqlz_query_files");

test "deterministically emits parseable Zig for a checked named query" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applySqliteRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL)",
        "",
    );
    var source = try query_files.parse(std.testing.allocator, "users/get.sql",
        \\-- sqlz.name: get_user
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: optional
        \\
        \\SELECT id, name FROM users WHERE id=:id
    );
    defer source.deinit();
    var checked = try checker.checkNamedSqlite(std.testing.allocator, &schema, &source);
    defer checked.deinit();

    const generated = try generator.generateQuery(std.testing.allocator, &source, &checked);
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "id: i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "name: []const u8") != null);
    const terminated = try std.testing.allocator.dupeZ(u8, generated);
    defer std.testing.allocator.free(terminated);
    var ast = try std.zig.Ast.parse(std.testing.allocator, terminated, .zig);
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    const again = try generator.generateQuery(std.testing.allocator, &source, &checked);
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualStrings(generated, again);
}

test "emits a PostgreSQL-only checked query" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applyPostgresRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL)",
        "",
    );
    var source = try query_files.parse(std.testing.allocator, "users/get.sql",
        \\-- sqlz.name: get_user
        \\-- sqlz.backends: postgres
        \\-- sqlz.cardinality: optional
        \\
        \\SELECT id, name FROM users WHERE id=:id
    );
    defer source.deinit();
    var checked = try checker.checkNamedPostgres(std.testing.allocator, &schema, &source);
    defer checked.deinit();

    const generated = try generator.generateQuery(std.testing.allocator, &source, &checked);
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".postgres = true") != null);
    const terminated = try std.testing.allocator.dupeZ(u8, generated);
    defer std.testing.allocator.free(terminated);
    var ast = try std.zig.Ast.parse(std.testing.allocator, terminated, .zig);
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
}

test "assembles checked queries into deterministic path namespaces" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applySqliteRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL)",
        "",
    );
    var list_source = try query_files.parse(std.testing.allocator, "users/list.sql",
        \\-- sqlz.name: list_users
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: many
        \\
        \\SELECT id, name FROM users
    );
    defer list_source.deinit();
    var get_source = try query_files.parse(std.testing.allocator, "users/admin/get.sql",
        \\-- sqlz.name: get_user
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: optional
        \\
        \\SELECT id, name FROM users WHERE id=:id
    );
    defer get_source.deinit();
    var list_checked = try checker.checkNamedSqlite(std.testing.allocator, &schema, &list_source);
    defer list_checked.deinit();
    var get_checked = try checker.checkNamedSqlite(std.testing.allocator, &schema, &get_source);
    defer get_checked.deinit();

    const inputs = [_]generator.CheckedInput{
        .{ .source = &list_source, .checked = &list_checked },
        .{ .source = &get_source, .checked = &get_checked },
    };
    const generated = try generator.generateModule(std.testing.allocator, "app", &inputs);
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const app = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const users = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const admin = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const get_user = sqlz.Query") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const list_users = sqlz.Query") != null);

    const terminated = try std.testing.allocator.dupeZ(u8, generated);
    defer std.testing.allocator.free(terminated);
    var ast = try std.zig.Ast.parse(std.testing.allocator, terminated, .zig);
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    const reversed = [_]generator.CheckedInput{ inputs[1], inputs[0] };
    const generated_again = try generator.generateModule(std.testing.allocator, "app", &reversed);
    defer std.testing.allocator.free(generated_again);
    try std.testing.expectEqualStrings(generated, generated_again);
}

test "codec overrides name the bound Zig declaration" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applySqliteRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE accounts (id BIGINT PRIMARY KEY, tier INTEGER NOT NULL)",
        "",
    );
    var source = try query_files.parse(std.testing.allocator, "accounts/by_tier.sql",
        \\-- sqlz.name: accounts_by_tier
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: many
        \\-- sqlz.column.tier: tier
        \\-- sqlz.param.tier: tier
        \\
        \\SELECT id, tier FROM accounts WHERE tier=:tier
    );
    defer source.deinit();
    const codecs = [_]checker.CodecInfo{.{ .id = "tier", .sqlite_type = .integer }};
    var checked = try checker.checkNamedSqliteWithCodecs(
        std.testing.allocator,
        &schema,
        &source,
        .{},
        &codecs,
    );
    defer checked.deinit();

    const bindings = [_]generator.CodecBinding{
        .{ .id = "tier", .import_name = "sqlz_codec_tier", .declaration = "Tier" },
    };
    const inputs = [_]generator.CheckedInput{.{ .source = &source, .checked = &checked }};
    const roots = [_]generator.RootInput{.{ .alias = "app", .inputs = &inputs }};
    const generated = try generator.generateProjectModuleWithCodecs(
        std.testing.allocator,
        &roots,
        &bindings,
    );
    defer std.testing.allocator.free(generated);

    try std.testing.expect(std.mem.indexOf(u8, generated, "const sqlz_codec_tier = @import(\"sqlz_codec_tier\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "sqlz.assertCodec(sqlz_codec_tier.Tier);") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "tier: sqlz_codec_tier.Tier,") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "id: i64") != null);

    const terminated = try std.testing.allocator.dupeZ(u8, generated);
    defer std.testing.allocator.free(terminated);
    var ast = try std.zig.Ast.parse(std.testing.allocator, terminated, .zig);
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

    const again = try generator.generateProjectModuleWithCodecs(std.testing.allocator, &roots, &bindings);
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualStrings(generated, again);
}

test "a codec conflicting with the inferred type is rejected" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applySqliteRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE accounts (id BIGINT PRIMARY KEY, label TEXT NOT NULL)",
        "",
    );
    var source = try query_files.parse(std.testing.allocator, "accounts/label.sql",
        \\-- sqlz.name: accounts_label
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: many
        \\-- sqlz.column.label: tier
        \\
        \\SELECT label FROM accounts
    );
    defer source.deinit();
    const codecs = [_]checker.CodecInfo{.{ .id = "tier", .sqlite_type = .integer }};
    try std.testing.expectError(error.IncompatibleCodec, checker.checkNamedSqliteWithCodecs(
        std.testing.allocator,
        &schema,
        &source,
        .{},
        &codecs,
    ));
}

test "a codec the project never registered is rejected" {
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try checker.applySqliteRevisionAtomic(
        &schema,
        std.testing.allocator,
        "CREATE TABLE accounts (id BIGINT PRIMARY KEY, tier INTEGER NOT NULL)",
        "",
    );
    var source = try query_files.parse(std.testing.allocator, "accounts/tier.sql",
        \\-- sqlz.name: accounts_tier
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: many
        \\-- sqlz.column.tier: missing_codec
        \\
        \\SELECT tier FROM accounts
    );
    defer source.deinit();
    try std.testing.expectError(error.UnknownCodec, checker.checkNamedSqliteWithCodecs(
        std.testing.allocator,
        &schema,
        &source,
        .{},
        &.{},
    ));
}
