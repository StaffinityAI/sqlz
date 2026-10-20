const std = @import("std");
const inputs = @import("sqlz_inputs");
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

    var project_inputs = try inputs.Inputs.init(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer project_inputs.deinit();
    var discovery = try query_files.discover(
        std.testing.allocator,
        &project_inputs,
        tmp.dir,
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
    var project_inputs = try inputs.Inputs.init(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer project_inputs.deinit();
    try std.testing.expectError(error.DuplicateQueryVariant, query_files.discover(
        std.testing.allocator,
        &project_inputs,
        tmp.dir,
    ));
}

test "a query name repeats freely across directories" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const query = "-- sqlz.name: find\n-- sqlz.backends: sqlite\n" ++
        "-- sqlz.cardinality: exec\nDELETE FROM users";
    for ([_][]const u8{ "users", "admins" }) |directory| {
        var dir = try tmp.dir.createDirPathOpen(std.testing.io, directory, .{});
        defer dir.close(std.testing.io);
        try dir.writeFile(std.testing.io, .{ .sub_path = "find.sql", .data = query });
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "find.sql", .data = query });

    var project_inputs = try inputs.Inputs.init(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer project_inputs.deinit();
    var discovery = try query_files.discover(
        std.testing.allocator,
        &project_inputs,
        tmp.dir,
    );
    defer discovery.deinit();
    try std.testing.expectEqual(@as(usize, 3), discovery.sources.len);
}

test "variants group by directory and name in one pass" {
    const sqlite = "-- sqlz.backends: sqlite\n-- sqlz.cardinality: exec\nDELETE FROM users";
    const postgres = "-- sqlz.backends: postgres\n-- sqlz.cardinality: exec\nDELETE FROM users";
    const both = "-- sqlz.backends: sqlite, postgres\n-- sqlz.cardinality: exec\nDELETE FROM users";
    const files = [_]struct { []const u8, []const u8 }{
        .{ "a/one.sql", "-- sqlz.name: q\n" ++ sqlite },
        .{ "a/two.sql", "-- sqlz.name: q\n" ++ postgres },
        .{ "a/three.sql", "-- sqlz.name: q\n" ++ both },
        .{ "b/one.sql", "-- sqlz.name: q\n" ++ both },
    };
    var sources: [files.len]query_files.Source = undefined;
    var parsed: usize = 0;
    defer for (sources[0..parsed]) |*source| source.deinit();
    for (files, 0..) |file, index| {
        sources[index] = try query_files.parse(std.testing.allocator, file[0], file[1]);
        parsed += 1;
    }
    var variants = try query_files.Variants.init(std.testing.allocator, &sources);
    defer variants.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(usize, &.{ 0, 0, 0, 3 }, variants.group);
    try std.testing.expectEqual(@as(?usize, null), variants.duplicate[0]);
    try std.testing.expectEqual(@as(?usize, null), variants.duplicate[1]);
    // Both backends collide; the earlier source is reported.
    try std.testing.expectEqual(@as(?usize, 0), variants.duplicate[2]);
    try std.testing.expectEqual(@as(?usize, null), variants.duplicate[3]);
}
