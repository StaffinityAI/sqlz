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
