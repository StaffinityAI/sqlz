const std = @import("std");
const queries = @import("queries");
const types = @import("types");

test "consumer imports checked cache module" {
    try std.testing.expect(@hasDecl(queries.app.users.get_user, "fetchOptional"));
}

test "a registered codec reaches the generated parameter and row types" {
    const by_tier = queries.app.users.users_by_tier;
    try std.testing.expectEqual(types.Tier, @FieldType(by_tier.params, "tier"));
    try std.testing.expectEqual(types.Tier, @FieldType(by_tier.row_type, "tier"));
    try std.testing.expectEqual(i64, @FieldType(by_tier.row_type, "id"));
}

test "embedded declarations are checked and usable" {
    const embedded = @import("embedded");
    try std.testing.expectEqual(i64, @FieldType(embedded.count_users.row_type, "total"));
    // The codec map reached the declaration's own type, not a rewritten one.
    try std.testing.expectEqual(types.Tier, @FieldType(embedded.user_tier.row_type, "tier"));
}
