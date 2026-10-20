//! The source manager: how sqlz reads the bytes of a project source and how it
//! names a place in them. Offsets are always byte offsets into the original
//! file, BOM included, so checksums and excerpts see exactly what is on disk.
//! Lines and columns are for people: a UTF-8 byte order mark is not a column,
//! a column counts Unicode scalar values, and a line ends at LF, with a CR
//! directly before it belonging to the line ending.
const std = @import("std");

pub const bom = "\xEF\xBB\xBF";

/// Excerpts render a tab at this fixed width, whatever the terminal does.
pub const tab_width: u32 = 4;

pub const Position = struct {
    offset: usize,
    line: usize,
    column: usize,
};

/// Length of the byte order mark at the start of `text`, or zero.
pub fn bomLength(text: []const u8) usize {
    return if (std.mem.startsWith(u8, text, bom)) bom.len else 0;
}

/// The text after a byte order mark, for consumers that parse it. Offsets into
/// the result are `bomLength(text)` bytes behind offsets into `text`.
pub fn withoutBom(text: []const u8) []const u8 {
    return text[bomLength(text)..];
}

/// Returns the byte offset of the first byte that is not part of well-formed
/// UTF-8, or null when the whole text is valid. Overlong encodings, surrogate
/// code points, and values past U+10FFFF are malformed.
pub fn invalidUtf8Offset(text: []const u8) ?usize {
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return index;
        if (index + length > text.len) return index;
        _ = std.unicode.utf8Decode(text[index..][0..length]) catch return index;
        index += length;
    }
    std.debug.assert(index == text.len);
    return null;
}

/// The line and column of `offset`. An offset past the end clamps to the end,
/// and an offset inside the byte order mark or a multibyte sequence names the
/// column of the character that holds it.
pub fn positionAt(text: []const u8, offset: usize) Position {
    const clamped = @min(offset, text.len);
    var line: usize = 1;
    var line_start: usize = bomLength(text);
    var index: usize = line_start;
    while (std.mem.indexOfScalarPos(u8, text[0..clamped], index, '\n')) |newline| {
        line += 1;
        line_start = newline + 1;
        index = line_start;
    }
    // Back up to the first byte of the character holding the offset.
    var counted = clamped;
    var steps: u32 = 0;
    while (counted > line_start and counted < text.len and text[counted] & 0xC0 == 0x80 and steps < 3) : (steps += 1) {
        counted -= 1;
    }
    const column = scalarCount(text[@min(line_start, counted)..counted]) + 1;
    std.debug.assert(line >= 1 and column >= 1);
    return .{ .offset = clamped, .line = line, .column = column };
}

/// The text of the line holding `offset`, without its line ending and without
/// a byte order mark.
pub fn lineAt(text: []const u8, offset: usize) []const u8 {
    const clamped = @min(offset, text.len);
    const first = bomLength(text);
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..clamped], '\n')) |newline|
        newline + 1
    else
        @min(first, text.len);
    var end = std.mem.indexOfScalarPos(u8, text, @max(start, clamped), '\n') orelse text.len;
    if (end > start and text[end - 1] == '\r') end -= 1;
    std.debug.assert(start <= end);
    return text[start..end];
}

/// Counts Unicode scalar values. A byte that cannot start a sequence counts as
/// one, so a column is still defined for text that failed validation.
pub fn scalarCount(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }
    return count;
}

/// The width an excerpt gives `text`: a tab is `tab_width`, any other scalar
/// value is one.
pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    for (text) |byte| {
        if (byte == '\t') {
            width += tab_width;
        } else if (byte & 0xC0 != 0x80) {
            width += 1;
        }
    }
    return width;
}

/// Writes one excerpt line with tabs expanded and control characters replaced,
/// so a source cannot move the cursor or recolor the terminal it is shown on.
/// The output has exactly `displayWidth(text)` columns.
pub fn writeDisplay(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '\t') {
            try writer.splatByteAll(' ', tab_width);
            index += 1;
            continue;
        }
        // A stray continuation byte has no column of its own, matching
        // `displayWidth`; a malformed sequence is one replacement character.
        if (byte & 0xC0 == 0x80) {
            index += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch {
            try writer.writeAll("\u{FFFD}");
            index += 1;
            continue;
        };
        const sequence = text[index..@min(index + length, text.len)];
        const scalar: u21 = std.unicode.utf8Decode(sequence) catch {
            try writer.writeAll("\u{FFFD}");
            index += 1;
            continue;
        };
        if (scalar < 0x20 or (scalar >= 0x7F and scalar < 0xA0)) {
            try writer.writeAll("\u{FFFD}");
        } else {
            try writer.writeAll(sequence);
        }
        index += sequence.len;
    }
}
