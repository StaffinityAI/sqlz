//! Golden fixtures for the source manager: byte order marks, UTF-8 validity,
//! multibyte columns, tabs, and LF/CRLF line endings.
const std = @import("std");
const source = @import("sqlz_source");

fn expectPosition(text: []const u8, offset: usize, line: usize, column: usize) !void {
    const position = source.positionAt(text, offset);
    try std.testing.expectEqual(offset, position.offset);
    try std.testing.expectEqual(line, position.line);
    try std.testing.expectEqual(column, position.column);
}

test "a byte order mark is accepted and is not a column" {
    const text = "\xEF\xBB\xBFSELECT 1\nSELECT 2";
    try std.testing.expectEqual(@as(usize, 3), source.bomLength(text));
    try std.testing.expectEqualStrings("SELECT 1\nSELECT 2", source.withoutBom(text));
    try std.testing.expectEqual(@as(?usize, null), source.invalidUtf8Offset(text));
    // Offsets stay byte offsets into the file; only columns skip the mark.
    try expectPosition(text, 0, 1, 1);
    try expectPosition(text, 3, 1, 1);
    try expectPosition(text, 10, 1, 8);
    try expectPosition(text, 12, 2, 1);
    try std.testing.expectEqualStrings("SELECT 1", source.lineAt(text, 5));
    try std.testing.expectEqual(@as(usize, 0), source.bomLength("SELECT 1"));
    // Only a leading mark is a byte order mark.
    try expectPosition("a\xEF\xBB\xBFb", 4, 1, 3);
}

test "malformed UTF-8 is reported at its exact byte" {
    const cases = [_]struct { []const u8, ?usize }{
        .{ "SELECT 'ok'", null },
        .{ "SELECT 'é'", null },
        .{ "SELECT '\xF0\x9F\x98\x80'", null },
        .{ "SELECT '\xFF'", 8 },
        // A lone continuation byte.
        .{ "ab\x80", 2 },
        // A truncated two-byte and three-byte sequence.
        .{ "é\xC3", 2 },
        .{ "\xE2\x82", 0 },
        // An overlong encoding of '/'.
        .{ "x\xC0\xAF", 1 },
        // A UTF-16 surrogate half.
        .{ "x\xED\xA0\x80", 1 },
        // Past U+10FFFF.
        .{ "x\xF4\x90\x80\x80", 1 },
    };
    for (cases) |case| {
        const text, const expected = case;
        try std.testing.expectEqual(expected, source.invalidUtf8Offset(text));
    }
}

test "columns count Unicode scalar values, not bytes" {
    // é is two bytes, 😀 is four, and each is one column.
    const text = "-- é😀\nSELECT 'é', x";
    try expectPosition(text, 3, 1, 4);
    try expectPosition(text, 5, 1, 5);
    try expectPosition(text, 9, 1, 6);
    try expectPosition(text, 10, 2, 1);
    try expectPosition(text, 22, 2, 12);
    try std.testing.expectEqual(@as(usize, 4), source.scalarCount("é😀ab"));
    // An offset inside a multibyte character names that character's column.
    try expectPosition(text, 4, 1, 4);
    try expectPosition(text, 7, 1, 5);
}

test "tabs are one column and four display cells" {
    const text = "\tSELECT\tx";
    try expectPosition(text, 1, 1, 2);
    try expectPosition(text, 8, 1, 9);
    try std.testing.expectEqual(@as(usize, 15), source.displayWidth(text));
    try std.testing.expectEqual(@as(usize, 2), source.displayWidth("é😀"));
}

test "LF and CRLF line endings index the same lines" {
    const lf = "SELECT\n  id\nFROM t";
    const crlf = "SELECT\r\n  id\r\nFROM t";
    try expectPosition(lf, 9, 2, 3);
    try expectPosition(crlf, 10, 2, 3);
    try expectPosition(lf, 12, 3, 1);
    try expectPosition(crlf, 14, 3, 1);
    // The CR belongs to the line ending, so it is the column after the text.
    try expectPosition(crlf, 6, 1, 7);
    try std.testing.expectEqualStrings("  id", source.lineAt(crlf, 10));
    try std.testing.expectEqualStrings("SELECT", source.lineAt(crlf, 2));
    try std.testing.expectEqualStrings("FROM t", source.lineAt(crlf, 15));
    // A lone CR is not a line ending.
    try expectPosition("a\rb", 2, 1, 3);
    try std.testing.expectEqualStrings("a\rb", source.lineAt("a\rb", 0));
}

test "offsets past the end clamp to the end" {
    try expectPosition("ab\ncd", 5, 2, 3);
    const position = source.positionAt("ab", 99);
    try std.testing.expectEqual(@as(usize, 2), position.offset);
    try std.testing.expectEqual(@as(usize, 3), position.column);
    try expectPosition("", 0, 1, 1);
    try std.testing.expectEqualStrings("", source.lineAt("", 0));
    try std.testing.expectEqualStrings("", source.lineAt("a\n", 2));
}

test "excerpt text expands tabs and neutralizes control characters" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const text = "\tSELECT 'é'\x1b[31m\x7f";
    try source.writeDisplay(&output.writer, text);
    try std.testing.expectEqualStrings("    SELECT 'é'\u{FFFD}[31m\u{FFFD}", output.written());
    // Display width and written width agree, so underlines line up.
    try std.testing.expectEqual(source.displayWidth(text), std.unicode.utf8CountCodepoints(output.written()) catch unreachable);
}

test "excerpt text survives malformed bytes" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const text = "a\xFFb\xE2\x82c";
    try source.writeDisplay(&output.writer, text);
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}c", output.written());
    try std.testing.expectEqual(source.displayWidth(text), std.unicode.utf8CountCodepoints(output.written()) catch unreachable);
}
