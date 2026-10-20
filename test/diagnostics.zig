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
    try std.testing.expectEqualStrings("Q001", diagnostics.codeForError(error.MissingDeclaredField));
    try std.testing.expectEqual(@as(u8, 1), diagnostics.exitCode(error.MissingDeclaredField));
    try std.testing.expectEqual(@as(u8, 1), diagnostics.exitCode(error.DeclaredTypeMismatch));
    try std.testing.expectEqualStrings("Q023", diagnostics.codeForError(error.ConflictingResultType));
    try std.testing.expectEqualStrings("Q024", diagnostics.codeForError(error.ConflictingParameterType));
}

test "human diagnostics render excerpts with tabs expanded and multibyte columns" {
    // A tab before the column and a multibyte character inside the span.
    const query = "-- sqlz.name: get\n\tSELECT naïve FROM users";
    const migration = "\xEF\xBB\xBFCREATE TABLE users (\r\n  name TEXT\r\n)";
    const name_offset = std.mem.indexOf(u8, query, "naïve").?;
    const column_offset = std.mem.indexOf(u8, migration, "name").?;
    const diagnostic: diagnostics.Diagnostic = .{
        .severity = .err,
        .code = "Q021",
        .message = "column `naïve` does not exist",
        .primary = diagnostics.spanAt("queries/get.sql", query, name_offset, name_offset + "naïve".len),
        .labels = &.{.{
            .span = diagnostics.spanAt("migrations/a/common.up.sql", migration, column_offset, column_offset + 4),
            .message = "available column",
        }},
        .help = "did you mean `name`?",
    };
    try std.testing.expectEqual(@as(usize, 2), diagnostic.primary.?.start.line);
    try std.testing.expectEqual(@as(usize, 9), diagnostic.primary.?.start.column);
    try std.testing.expectEqual(@as(usize, 14), diagnostic.primary.?.end.column);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try diagnostics.render(&output.writer, diagnostic, .human);
    try std.testing.expectEqualStrings(
        \\queries/get.sql:2:9: error[Q021]: column `naïve` does not exist
        \\  |
        \\2 |     SELECT naïve FROM users
        \\  |            ^^^^^
        \\  migrations/a/common.up.sql:2:3: note: available column
        \\  |
        \\2 |   name TEXT
        \\  |   ----
        \\  = help: did you mean `name`?
        \\
    , output.written());
}

test "excerpts survive copying into a diagnostic list" {
    var list: diagnostics.List = .init(std.testing.allocator, 10);
    defer list.deinit();
    {
        const text = try std.testing.allocator.dupe(u8, "SELECT x\nFROM t");
        defer std.testing.allocator.free(text);
        try list.appendDiagnostic(.{
            .severity = .err,
            .code = "Q020",
            .message = "relation `t` does not exist",
            .primary = diagnostics.spanAt("q.sql", text, 14, 15),
        });
    }
    try std.testing.expectEqualStrings("FROM t", list.slice()[0].primary.?.excerpt.?);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try diagnostics.render(&output.writer, list.slice()[0], .human);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "2 | FROM t\n  |      ^\n") != null);
}

test "a span reaching past its line underlines to the line end" {
    const text = "SELECT a,\n  b";
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try diagnostics.render(&output.writer, .{
        .severity = .err,
        .code = "S010",
        .message = "syntax error",
        .primary = diagnostics.spanAt("q.sql", text, 7, text.len),
    }, .human);
    try std.testing.expectEqualStrings(
        \\q.sql:1:8: error[S010]: syntax error
        \\  |
        \\1 | SELECT a,
        \\  |        ^^
        \\
    , output.written());
}

test "UTF-8 and lexical limit codes are checked-source errors" {
    try std.testing.expectEqualStrings("S011", diagnostics.codeForError(error.InvalidUtf8));
    try std.testing.expectEqualStrings("S021", diagnostics.codeForError(error.TokenLimitExceeded));
    try std.testing.expectEqualStrings("S021", diagnostics.codeForError(error.NestingLimitExceeded));
    try std.testing.expectEqual(@as(u8, 1), diagnostics.exitCode(error.InvalidUtf8));
    try std.testing.expectEqual(@as(u8, 1), diagnostics.exitCode(error.NestingLimitExceeded));
}
