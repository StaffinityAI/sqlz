const std = @import("std");
const diagnostics = @import("sqlz_diagnostics");

const sample: diagnostics.Diagnostic = .{
    .severity = .err,
    .code = "Q021",
    .message = "column `nickname` does not exist",
    .primary = .{
        .path = "queries/get_user.sql",
        .start = .{ .offset = 7, .line = 6, .column = 8 },
        .end = .{ .offset = 15, .line = 6, .column = 16 },
    },
    .labels = &.{.{
        .span = .{
            .path = "migrations/create_users/common.up.sql",
            .start = .{ .offset = 20, .line = 4, .column = 3 },
            .end = .{ .offset = 32, .line = 4, .column = 15 },
        },
        .message = "available column",
    }},
    .notes = &.{"users is declared by revision a1b2c3d4e5f6"},
    .help = "did you mean `display_name`?",
};

test "human diagnostic rendering is stable" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try diagnostics.render(&output.writer, sample, .human);
    try std.testing.expectEqualStrings(
        \\queries/get_user.sql:6:8: error[Q021]: column `nickname` does not exist
        \\  migrations/create_users/common.up.sql:4:3: note: available column
        \\  = note: users is declared by revision a1b2c3d4e5f6
        \\  = help: did you mean `display_name`?
        \\
    , output.written());
}

test "JSON diagnostic rendering is a versioned record" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try diagnostics.render(&output.writer, sample, .json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), object.get("format_version").?.integer);
    try std.testing.expectEqualStrings("diagnostic", object.get("kind").?.string);
    try std.testing.expectEqualStrings("Q021", object.get("code").?.string);
    try std.testing.expectEqual(@as(usize, 1), object.get("labels").?.array.items.len);
}

test "error codes and exit classes are stable" {
    try std.testing.expectEqualStrings("M001", diagnostics.codeForError(error.MissingParent));
    try std.testing.expectEqual(@as(u8, 1), diagnostics.exitCode(error.MissingParent));
    try std.testing.expectEqualStrings("S001", diagnostics.codeForError(error.InvalidArguments));
    try std.testing.expectEqual(@as(u8, 2), diagnostics.exitCode(error.InvalidArguments));
}
