const std = @import("std");
const query_files = @import("sqlz_query_files");

test "parses strict named SQL directives" {
    var source = try query_files.parse(std.testing.allocator, "users/get.sql",
        \\-- sqlz.name: get_user
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: optional
        \\
        \\SELECT id, name FROM users WHERE id=:id;
    );
    defer source.deinit();
    try std.testing.expectEqualStrings("get_user", source.name);
    try std.testing.expect(source.backends.sqlite);
    try std.testing.expect(!source.backends.postgres);
    try std.testing.expectEqual(query_files.Cardinality.optional, source.cardinality);
    try std.testing.expect(std.mem.startsWith(u8, source.sql, "SELECT"));
}

test "discovers SQL recursively in bytewise path order" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var nested = try tmp.dir.createDirPathOpen(std.testing.io, "users", .{});
    defer nested.close(std.testing.io);
    try nested.writeFile(std.testing.io, .{
        .sub_path = "z.sql",
        .data = "-- sqlz.name: zed\n-- sqlz.backends: sqlite\n" ++
            "-- sqlz.cardinality: exec\nDELETE FROM users",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "a.sql",
        .data = "-- sqlz.name: alpha\n-- sqlz.backends: sqlite\n" ++
            "-- sqlz.cardinality: many\nSELECT id FROM users",
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ignored.txt", .data = "not sql" });

    var discovery = try query_files.discover(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        1024 * 1024,
    );
    defer discovery.deinit();
    try std.testing.expectEqual(@as(usize, 2), discovery.sources.len);
    try std.testing.expectEqualStrings("a.sql", discovery.sources[0].path);
    try std.testing.expectEqualStrings("users/z.sql", discovery.sources[1].path);
}

test "rejects unknown directives and overlapping query names" {
    try std.testing.expectError(error.UnknownDirective, query_files.parse(
        std.testing.allocator,
        "bad.sql",
        "-- sqlz.name: bad\n-- sqlz.backends: sqlite\n" ++
            "-- sqlz.cardinality: exec\n-- sqlz.typo: yes\nDELETE FROM users",
    ));

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const duplicate = "-- sqlz.name: duplicate\n-- sqlz.backends: sqlite\n" ++
        "-- sqlz.cardinality: exec\nDELETE FROM users";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.sql", .data = duplicate });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.sql", .data = duplicate });
    try std.testing.expectError(error.DuplicateQueryVariant, query_files.discover(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        1024 * 1024,
    ));
}
