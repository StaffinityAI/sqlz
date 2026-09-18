const std = @import("std");
const queries = @import("queries");

test "build-cache generated module is importable" {
    try std.testing.expect(@hasDecl(queries.app.users.get_user, "fetchOptional"));
    try std.testing.expect(@hasDecl(queries.app.users.search_users, "fetch"));
    try std.testing.expectEqualStrings("pattern", queries.app.users.search_users.parameter_names[0]);
    try std.testing.expectEqualStrings(
        "SELECT id, name FROM users WHERE name LIKE :pattern;",
        queries.app.users.search_users.sql.sqlite,
    );
    try std.testing.expectEqualStrings(
        "SELECT id, name FROM users WHERE name ILIKE $1;",
        queries.app.users.search_users.sql.postgres,
    );
}
