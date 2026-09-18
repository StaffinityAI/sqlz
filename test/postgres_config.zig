const std = @import("std");
const postgres_config = @import("postgres_config");

test "live PostgreSQL configuration accepts supported majors" {
    inline for (15..19) |major| {
        try (postgres_config.Config{
            .host = "127.0.0.1",
            .port = 5432,
            .database = "sqlz_test",
            .username = "sqlz_test",
            .password = "sqlz_test",
            .expected_major = major,
        }).validate();
    }
}

test "live PostgreSQL configuration rejects invalid targets" {
    try std.testing.expectError(error.InvalidPort, (postgres_config.Config{
        .host = "127.0.0.1",
        .port = 0,
        .database = "sqlz_test",
        .username = "sqlz_test",
        .password = "sqlz_test",
        .expected_major = 18,
    }).validate());
    try std.testing.expectError(error.UnsupportedMajor, (postgres_config.Config{
        .host = "127.0.0.1",
        .port = 5432,
        .database = "sqlz_test",
        .username = "sqlz_test",
        .password = "sqlz_test",
        .expected_major = 19,
    }).validate());
}
