const std = @import("std");

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
