const std = @import("std");
const queries = @import("queries");

test "build-cache generated module is importable" {
    try std.testing.expect(@hasDecl(queries.app.users.get_user, "fetchOptional"));
}
