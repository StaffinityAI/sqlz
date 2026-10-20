const std = @import("std");
const queries = @import("queries");

fn expectBoth(comptime Query: type) !void {
    try std.testing.expect(Query.backends.sqlite);
    try std.testing.expect(Query.backends.postgres);
}

test "every example query is checked for SQLite and PostgreSQL" {
    try expectBoth(queries.app.account_crud.create);
    try expectBoth(queries.app.account_crud.list);
    try expectBoth(queries.app.aggregate_counts.counts);
    try expectBoth(queries.app.arena_rows.all_users);
    try expectBoth(queries.app.delete_cleanup.cleanup);
    try expectBoth(queries.app.enum_roles.by_tier);
    try expectBoth(queries.app.enum_roles.promote);
    try expectBoth(queries.app.insert_select.copy_permission);
    try expectBoth(queries.app.nullable_join.lookup);
    try expectBoth(queries.app.paginated_search.page);
    try expectBoth(queries.app.pooled_reads.count_users);
    try expectBoth(queries.app.pooled_reads.find_user);
    try expectBoth(queries.app.preferences_upsert.save);
    try expectBoth(queries.app.recursive_roles.effective);
    try expectBoth(queries.app.session_lookup.find_session);
    try expectBoth(queries.app.transaction_transfer.transfer);
    try expectBoth(@import("embedded_declarations").promote);
    try expectBoth(@import("embedded_declarations").by_tier);
    try expectBoth(@import("embedded_declarations").newest);
    try expectBoth(queries.app.basic_sql_file.add_user);
    try expectBoth(queries.app.basic_sql_file.find_user);
    try expectBoth(@import("basic_embedded_query").insert_user);
    try expectBoth(@import("basic_embedded_query").list_users);
    try expectBoth(@import("basic_transaction").insert_name);
    try expectBoth(@import("basic_transaction").total_users);
}

fn expectOutput(comptime example: type, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try example.run(std.testing.allocator, std.testing.io, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "basic SQL file example" {
    try expectOutput(@import("basic_sql_file"), "user 1: Ada\n");
}

test "basic embedded query example" {
    try expectOutput(@import("basic_embedded_query"), "user 1: Ada\nuser 2: Grace\nuser 3: Barbara\n");
}

test "basic transaction example" {
    try expectOutput(@import("basic_transaction"), "after rollback: 0 users\nafter commit: 1 users\n");
}

test "account CRUD example" {
    try @import("account_crud").run(std.testing.allocator, std.testing.io);
}

test "preferences upsert example" {
    try @import("preferences_upsert").run(std.testing.allocator, std.testing.io);
}

test "recursive roles example" {
    try @import("recursive_roles").run(std.testing.allocator, std.testing.io);
}

test "nullable join example" {
    try @import("nullable_join").run(std.testing.allocator, std.testing.io);
}

test "transaction transfer example" {
    try @import("transaction_transfer").run(std.testing.allocator, std.testing.io);
}

test "session lookup example" {
    try @import("session_lookup").run(std.testing.allocator, std.testing.io);
}

test "aggregate counts example" {
    try @import("aggregate_counts").run(std.testing.allocator, std.testing.io);
}

test "insert select example" {
    try @import("insert_select").run(std.testing.allocator, std.testing.io);
}

test "paginated search example" {
    try @import("paginated_search").run(std.testing.allocator, std.testing.io);
}

test "delete cleanup example" {
    try @import("delete_cleanup").run(std.testing.allocator, std.testing.io);
}

test "enum roles example" {
    try @import("enum_roles").run(std.testing.allocator, std.testing.io);
}

test "arena rows example" {
    try @import("arena_rows").run(std.testing.allocator, std.testing.io);
}

test "pooled reads example" {
    try @import("pooled_reads").run(std.testing.allocator, std.testing.io);
}

test "embedded declarations example" {
    try @import("embedded_declarations").run(std.testing.allocator, std.testing.io);
}
