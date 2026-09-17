const std = @import("std");
const sqlz = @import("sqlz");

test "Query exposes the cardinality-selected method" {
    const insert_user = sqlz.Query(.{
        .sql = "INSERT INTO users(name) VALUES (:name)",
        .backends = .{ .sqlite = true },
        .cardinality = .exec,
        .params = struct { name: []const u8 },
    });
    try std.testing.expect(@hasDecl(insert_user, "execute"));
    try std.testing.expect(!@hasDecl(insert_user, "fetch"));
}

test "owned text rows release all duplicated fields" {
    const Row = struct { id: i64, name: []const u8, note: ?[]const u8 };
    const row: Row = .{ .id = 1, .name = "Ada", .note = "first" };
    var owned = try sqlz.cloneRow(std.testing.allocator, row);
    defer sqlz.deinitOwnedRow(std.testing.allocator, &owned);
    try std.testing.expectEqualStrings("Ada", owned.name);
    try std.testing.expectEqualStrings("first", owned.note.?);
}

const Profile = struct { label: []const u8, tag: ?[:0]const u8 };
const Kind = enum(i64) { basic, premium };
const WideRow = struct {
    id: i64,
    kind: Kind,
    name: []const u8,
    note: ?[]const u8,
    token: [:0]const u8,
    profile: Profile,
};

fn cloneWideRow(allocator: std.mem.Allocator) !void {
    const row: WideRow = .{
        .id = 7,
        .kind = .premium,
        .name = "Ada",
        .note = null,
        .token = "sentinel",
        .profile = .{ .label = "owner", .tag = "tagged" },
    };
    var owned = try sqlz.cloneRow(allocator, row);
    defer sqlz.deinitOwnedRow(allocator, &owned);
    try std.testing.expect(owned.name.ptr != row.name.ptr);
    try std.testing.expect(owned.token.ptr != row.token.ptr);
    try std.testing.expect(owned.profile.tag.?.ptr != row.profile.tag.?.ptr);
    try std.testing.expectEqual(Kind.premium, owned.kind);
    try std.testing.expectEqual(@as(u8, 0), owned.token.ptr[owned.token.len]);
    try std.testing.expectEqualStrings("sentinel", owned.token);
    try std.testing.expectEqualStrings("owner", owned.profile.label);
    try std.testing.expectEqual(@as(?[]const u8, null), owned.note);
}

test "owned rows copy sentinel slices, nested structs, and enums" {
    try cloneWideRow(std.testing.allocator);
}

test "a partially copied owned row frees what it already duplicated" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneWideRow, .{});
}

const Tier = enum(i64) { basic, premium };
const Shade = enum {
    light,
    dark,

    pub const sqlz_storage = .text;
};

test "enum parameters lower to their stored representation" {
    const bound = sqlz.bindArgs(.{
        .tier = Tier.premium,
        .shade = Shade.dark,
        .name = "Ada",
        .fallback = @as(?Tier, null),
        .previous = @as(?Shade, .light),
    });
    try std.testing.expectEqual(@as(i64, 1), bound.tier);
    try std.testing.expectEqualStrings("dark", bound.shade);
    try std.testing.expectEqualStrings("Ada", bound.name);
    try std.testing.expectEqual(@as(?i64, null), bound.fallback);
    try std.testing.expectEqualStrings("light", bound.previous.?);
}

test "positional parameters stay a tuple after lowering" {
    const bound = sqlz.bindArgs(.{ Tier.basic, "Grace" });
    try std.testing.expect(@typeInfo(@TypeOf(bound)).@"struct".is_tuple);
    try std.testing.expectEqual(@as(i64, 0), bound[0]);
    try std.testing.expectEqualStrings("Grace", bound[1]);
}

test "parameters without enums are passed through unchanged" {
    const args = .{ .id = @as(i64, 4), .name = "Ada" };
    try std.testing.expectEqual(@TypeOf(args), sqlz.BoundArgs(@TypeOf(args)));
}

test "unwrap releases the error payload it discards" {
    const failed: sqlz.Result(u32) = .{ .err = .{
        .allocator = std.testing.allocator,
        .class = .constraint,
        .backend = .sqlite,
        .operation = .execute,
        .message = try std.testing.allocator.dupe(u8, "UNIQUE constraint failed"),
    } };
    try std.testing.expectError(error.SqlzFailed, sqlz.unwrap(failed));

    const worked: sqlz.Result(u32) = .{ .ok = 7 };
    try std.testing.expectEqual(@as(u32, 7), try sqlz.unwrap(worked));
}
