const sqlz = @import("sqlz");

/// A row struct named next to its query: the checker resolves it and verifies
/// it against the SQL, same as an inline struct.
const UserLabel = struct { id: i64, label: ?[]const u8 };

pub const get_embedded_user = sqlz.Query(.{
    .sql = "SELECT id, name FROM users WHERE id=:id",
    .backends = .{ .sqlite = true, .postgres = true },
    .cardinality = .optional,
    .params = struct { id: i64 },
    .row = struct { id: i64, name: []const u8 },
});

pub const get_embedded_label = sqlz.Query(.{
    .sql = "SELECT id, label FROM users WHERE id=:id",
    .backends = .{ .sqlite = true, .postgres = true },
    .cardinality = .optional,
    .params = struct { id: i64 },
    .row = UserLabel,
});
