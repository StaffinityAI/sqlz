const std = @import("std");
const analysis = @import("sqlz_analysis");
const catalog = @import("sqlz_catalog");
const ir = @import("sqlz_ir");
const parser = @import("sqlz_parser");

test "resolves qualified projected columns and their database types" {
    var schema_sql = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL);" ++
            "CREATE TABLE profiles (user_id BIGINT PRIMARY KEY, label TEXT NOT NULL)",
    );
    defer schema_sql.deinit();
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserJson(schema_sql.ast_json);

    var parsed = try parser.parse(
        std.testing.allocator,
        "SELECT u.name, p.label AS profile_label " ++
            "FROM users u LEFT JOIN profiles p ON p.user_id=u.id WHERE u.id=:id",
    );
    defer parsed.deinit();
    var query = try ir.adapt(std.testing.allocator, parsed.ast_json, parsed.rewritten.names);
    defer query.deinit();
    var result = try analysis.analyze(std.testing.allocator, &schema, &query);
    defer result.deinit();

    try std.testing.expectEqual(analysis.ScalarType.text, result.columns[0].scalar_type);
    try std.testing.expect(!result.columns[0].nullable);
    try std.testing.expectEqual(analysis.ScalarType.text, result.columns[1].scalar_type);
    try std.testing.expect(result.columns[1].nullable);
}

test "rejects missing relations and ambiguous unqualified columns" {
    var schema_sql = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT); CREATE TABLE profiles (id BIGINT)",
    );
    defer schema_sql.deinit();
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserJson(schema_sql.ast_json);

    var missing_sql = try parser.parse(std.testing.allocator, "SELECT id FROM missing");
    defer missing_sql.deinit();
    var missing = try ir.adapt(
        std.testing.allocator,
        missing_sql.ast_json,
        missing_sql.rewritten.names,
    );
    defer missing.deinit();
    try std.testing.expectError(
        error.MissingRelation,
        analysis.analyze(std.testing.allocator, &schema, &missing),
    );

    var ambiguous_sql = try parser.parse(
        std.testing.allocator,
        "SELECT id FROM users JOIN profiles ON users.id=profiles.id",
    );
    defer ambiguous_sql.deinit();
    var ambiguous = try ir.adapt(
        std.testing.allocator,
        ambiguous_sql.ast_json,
        ambiguous_sql.rewritten.names,
    );
    defer ambiguous.deinit();
    try std.testing.expectError(
        error.AmbiguousColumn,
        analysis.analyze(std.testing.allocator, &schema, &ambiguous),
    );
}

test "infers parameters from update assignments comparisons and limits" {
    var schema_sql = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL)",
    );
    defer schema_sql.deinit();
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserJson(schema_sql.ast_json);

    var update_sql = try parser.parse(
        std.testing.allocator,
        "UPDATE users SET name=:name WHERE id=:id RETURNING id",
    );
    defer update_sql.deinit();
    var update = try ir.adapt(
        std.testing.allocator,
        update_sql.ast_json,
        update_sql.rewritten.names,
    );
    defer update.deinit();
    var update_result = try analysis.analyze(std.testing.allocator, &schema, &update);
    defer update_result.deinit();
    try std.testing.expectEqual(analysis.ScalarType.text, update_result.parameters[0].scalar_type);
    try std.testing.expectEqual(analysis.ScalarType.integer, update_result.parameters[1].scalar_type);
    try std.testing.expect(!update_result.parameters[0].nullable);

    var page_sql = try parser.parse(
        std.testing.allocator,
        "SELECT id FROM users LIMIT :limit OFFSET :offset",
    );
    defer page_sql.deinit();
    var page = try ir.adapt(std.testing.allocator, page_sql.ast_json, page_sql.rewritten.names);
    defer page.deinit();
    var page_result = try analysis.analyze(std.testing.allocator, &schema, &page);
    defer page_result.deinit();
    try std.testing.expectEqual(analysis.ScalarType.integer, page_result.parameters[0].scalar_type);
    try std.testing.expectEqual(analysis.ScalarType.integer, page_result.parameters[1].scalar_type);
}

test "infers INSERT values and INSERT SELECT parameters from target columns" {
    var schema_sql = try parser.parse(
        std.testing.allocator,
        "CREATE TABLE users (id BIGINT PRIMARY KEY, name TEXT NOT NULL);" ++
            "CREATE TABLE role_permissions (" ++
            "role_id BIGINT NOT NULL, permission_key TEXT NOT NULL)",
    );
    defer schema_sql.deinit();
    var schema = catalog.Catalog.init(std.testing.allocator);
    defer schema.deinit();
    try schema.applyParserJson(schema_sql.ast_json);

    const cases = [_][]const u8{
        "INSERT INTO users(name) VALUES (:name) RETURNING id, name",
        "INSERT INTO role_permissions(role_id, permission_key) " ++
            "SELECT role_id, :new_key FROM role_permissions " ++
            "WHERE permission_key=:old_key",
    };
    for (cases) |sql| {
        var parsed = try parser.parse(std.testing.allocator, sql);
        defer parsed.deinit();
        var query = try ir.adapt(std.testing.allocator, parsed.ast_json, parsed.rewritten.names);
        defer query.deinit();
        var result = try analysis.analyze(std.testing.allocator, &schema, &query);
        defer result.deinit();
        for (result.parameters) |parameter| {
            try std.testing.expectEqual(analysis.ScalarType.text, parameter.scalar_type);
            try std.testing.expect(!parameter.nullable);
        }
    }
}
