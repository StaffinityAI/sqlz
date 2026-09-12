const std = @import("std");
const queries = @import("queries");

test "consumer imports checked cache module" {
    try std.testing.expect(@hasDecl(queries.app.users.get_user, "fetchOptional"));
}
