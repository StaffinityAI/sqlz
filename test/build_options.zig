const std = @import("std");
const sqlz_build = @import("sqlz_build");

test "PostgreSQL TLS requires the PostgreSQL runtime" {
    try std.testing.expectError(
        error.PostgresTlsRequiresPostgres,
        sqlz_build.validateRuntimeOptions(.{ .postgres_tls = true }),
    );
    try sqlz_build.validateRuntimeOptions(.{
        .postgres = true,
        .postgres_tls = true,
    });
}

test "a project runtime must be a subset of the dependency's adapters" {
    try sqlz_build.validateProjectRuntime(.{}, .{});
    try sqlz_build.validateProjectRuntime(.{ .sqlite = true }, .{ .sqlite = true, .postgres = true });
    try sqlz_build.validateProjectRuntime(.{ .sqlite = true, .postgres = true }, .{ .sqlite = true, .postgres = true });
    try std.testing.expectError(
        error.SqliteRuntimeUnavailable,
        sqlz_build.validateProjectRuntime(.{ .sqlite = true }, .{ .postgres = true }),
    );
    try std.testing.expectError(
        error.PostgresRuntimeUnavailable,
        sqlz_build.validateProjectRuntime(.{ .postgres = true }, .{ .sqlite = true }),
    );
}
