//! Queries authored as Zig declarations, in a root registered with
//! `sqlz_build`. The checker reads `.params`/`.row` from here and verifies them
//! against the same migrations the `.sql` files are checked against.

const sqlz = @import("sqlz");
const types = @import("types");

pub const count_users = sqlz.Query(.{
    .sql = "SELECT COUNT(*) AS total FROM users",
    .backends = .{ .sqlite = true },
    .cardinality = .one,
    .row = struct { total: i64 },
});

pub const user_tier = sqlz.Query(.{
    .sql = "SELECT id, tier FROM users WHERE id=:id",
    .backends = .{ .sqlite = true },
    .cardinality = .optional,
    .params = struct { id: i64 },
    .column_codecs = .{ .tier = "tier" },
    .row = struct { id: i64, tier: types.Tier },
});
