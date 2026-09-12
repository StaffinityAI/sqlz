const sqlz = @import("sqlz");

pub const get_embedded_user = sqlz.Query(.{
    .sql = "SELECT id, name FROM users WHERE id=:id",
    .backends = .{ .sqlite = true },
    .cardinality = .optional,
    .params = struct { id: i64 },
    .row = struct { id: i64, name: []const u8 },
});
