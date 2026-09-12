const std = @import("std");
const analysis = @import("sqlz_analysis");
const checker = @import("sqlz_checker");
const query_files = @import("sqlz_query_files");

pub const Error = error{UnsupportedType} || std.mem.Allocator.Error;

pub fn generateQuery(
    allocator: std.mem.Allocator,
    source: *const query_files.Source,
    checked: *const checker.CheckedQuery,
) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator,
        \\const sqlz = @import("sqlz");
        \\
    );
    try output.print(allocator, "// Generated from {s}; do not edit.\n", .{source.path});
    try output.print(allocator, "pub const {s} = sqlz.Query(.{{\n", .{source.name});
    try output.print(allocator, "    .sql = \"{f}\",\n", .{std.zig.fmtString(source.sql)});
    try output.appendSlice(allocator, "    .backends = .{");
    if (source.backends.sqlite) try output.appendSlice(allocator, " .sqlite = true,");
    if (source.backends.postgres) try output.appendSlice(allocator, " .postgres = true,");
    try output.appendSlice(allocator, " },\n");
    try output.print(allocator, "    .cardinality = .{s},\n", .{@tagName(source.cardinality)});
    try output.appendSlice(allocator, "    .params = struct {\n");
    for (checked.analysis.parameters) |parameter| {
        try output.print(allocator, "        {s}: ", .{parameter.name});
        try writeType(&output, allocator, parameter);
        try output.appendSlice(allocator, ",\n");
    }
    try output.appendSlice(allocator, "    },\n");
    if (source.cardinality != .exec) {
        try output.appendSlice(allocator, "    .row = struct {\n");
        for (checked.analysis.columns) |column| {
            try output.print(allocator, "        {s}: ", .{column.name});
            try writeType(&output, allocator, column);
            try output.appendSlice(allocator, ",\n");
        }
        try output.appendSlice(allocator, "    },\n");
    }
    try output.appendSlice(allocator, "});\n");
    return output.toOwnedSlice(allocator);
}

fn writeType(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: analysis.ResultColumn,
) Error!void {
    if (value.scalar_type == .unknown) return error.UnsupportedType;
    if (value.nullable) try output.append(allocator, '?');
    try output.appendSlice(allocator, switch (value.scalar_type) {
        .integer => "i64",
        .real => "f64",
        .text, .blob => "[]const u8",
        .boolean => "bool",
        .unknown => unreachable,
    });
}
