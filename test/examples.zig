const std = @import("std");

test "account CRUD example" {
    try @import("account_crud").run(std.testing.allocator);
}

test "preferences upsert example" {
    try @import("preferences_upsert").run(std.testing.allocator);
}

test "recursive roles example" {
    try @import("recursive_roles").run(std.testing.allocator);
}

test "nullable join example" {
    try @import("nullable_join").run(std.testing.allocator);
}

test "transaction transfer example" {
    try @import("transaction_transfer").run(std.testing.allocator);
}

test "session lookup example" {
    try @import("session_lookup").run(std.testing.allocator);
}

test "aggregate counts example" {
    try @import("aggregate_counts").run(std.testing.allocator);
}

test "insert select example" {
    try @import("insert_select").run(std.testing.allocator);
}

test "paginated search example" {
    try @import("paginated_search").run(std.testing.allocator);
}

test "delete cleanup example" {
    try @import("delete_cleanup").run(std.testing.allocator);
}
