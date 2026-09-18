const std = @import("std");

pub const format_version: u32 = 1;

pub const Severity = enum { err, warning, note };
pub const Format = enum { human, json };

pub const Position = struct {
    offset: usize,
    line: usize,
    column: usize,
};

pub const Span = struct {
    path: []const u8,
    start: Position,
    end: Position,
};

pub const Label = struct {
    span: Span,
    message: []const u8,
    primary: bool = false,
};

pub const Diagnostic = struct {
    severity: Severity,
    code: []const u8,
    message: []const u8,
    primary: ?Span = null,
    labels: []const Label = &.{},
    notes: []const []const u8 = &.{},
    help: ?[]const u8 = null,
};

pub fn render(writer: *std.Io.Writer, diagnostic: Diagnostic, format: Format) !void {
    switch (format) {
        .human => try renderHuman(writer, diagnostic),
        .json => try renderJson(writer, diagnostic),
    }
}

pub fn renderHuman(writer: *std.Io.Writer, diagnostic: Diagnostic) !void {
    if (diagnostic.primary) |span| {
        try writer.print("{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
            span.path,
            span.start.line,
            span.start.column,
            severityName(diagnostic.severity),
            diagnostic.code,
            diagnostic.message,
        });
    } else {
        try writer.print("{s}[{s}]: {s}\n", .{
            severityName(diagnostic.severity),
            diagnostic.code,
            diagnostic.message,
        });
    }
    for (diagnostic.labels) |label| {
        try writer.print("  {s}:{d}:{d}: {s}: {s}\n", .{
            label.span.path,
            label.span.start.line,
            label.span.start.column,
            if (label.primary) "label" else "note",
            label.message,
        });
    }
    for (diagnostic.notes) |note| try writer.print("  = note: {s}\n", .{note});
    if (diagnostic.help) |help| try writer.print("  = help: {s}\n", .{help});
}

pub fn renderJson(writer: *std.Io.Writer, diagnostic: Diagnostic) !void {
    var stringify: std.json.Stringify = .{ .writer = writer };
    try stringify.beginObject();
    try stringify.objectField("format_version");
    try stringify.write(format_version);
    try stringify.objectField("kind");
    try stringify.write("diagnostic");
    try stringify.objectField("severity");
    try stringify.write(severityName(diagnostic.severity));
    try stringify.objectField("code");
    try stringify.write(diagnostic.code);
    try stringify.objectField("message");
    try stringify.write(diagnostic.message);
    try stringify.objectField("primary");
    if (diagnostic.primary) |span| try writeSpan(&stringify, span) else try stringify.write(null);
    try stringify.objectField("labels");
    try stringify.beginArray();
    for (diagnostic.labels) |label| {
        try stringify.beginObject();
        try stringify.objectField("primary");
        try stringify.write(label.primary);
        try stringify.objectField("message");
        try stringify.write(label.message);
        try stringify.objectField("span");
        try writeSpan(&stringify, label.span);
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.objectField("notes");
    try stringify.write(diagnostic.notes);
    try stringify.objectField("help");
    if (diagnostic.help) |help| try stringify.write(help) else try stringify.write(null);
    try stringify.endObject();
    try writer.writeByte('\n');
}

fn severityName(severity: Severity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .note => "note",
    };
}

fn writeSpan(stringify: *std.json.Stringify, span: Span) !void {
    try stringify.beginObject();
    try stringify.objectField("path");
    try stringify.write(span.path);
    try stringify.objectField("start");
    try writePosition(stringify, span.start);
    try stringify.objectField("end");
    try writePosition(stringify, span.end);
    try stringify.endObject();
}

fn writePosition(stringify: *std.json.Stringify, position: Position) !void {
    try stringify.beginObject();
    try stringify.objectField("offset");
    try stringify.write(position.offset);
    try stringify.objectField("line");
    try stringify.write(position.line);
    try stringify.objectField("column");
    try stringify.write(position.column);
    try stringify.endObject();
}

pub fn codeForError(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArguments => "S001",
        error.FileNotFound, error.AccessDenied, error.NotDir => "S002",
        error.ParseError, error.EmptyInput, error.UnsupportedSqliteFeature => "S010",
        error.InvalidRevisionId, error.InvalidParentId, error.MissingParent, error.Cycle, error.MultipleHeads, error.DivergentMerge => "M001",
        error.MissingUpgradeSql, error.MissingDowngradeSql, error.UnexpectedBackendSql => "M002",
        error.MissingRelation, error.MissingColumn, error.AmbiguousColumn, error.UnsupportedStatement, error.DuplicateTable, error.DuplicateColumn => "C001",
        error.BackendNotSelected, error.UnexpectedResultColumns, error.MissingResultColumns, error.ConflictingResultType, error.ConflictingParameterType => "Q001",
        error.UnknownCodec, error.UnknownCodecTarget, error.IncompatibleCodec, error.MissingCodecForDeclaredType => "T001",
        error.InvalidNamespace, error.NamespaceCollision, error.UnsupportedType, error.IncompatibleBackendContract => "G001",
        error.UnsupportedFormatVersion, error.InvalidProjectId, error.InvalidPath, error.InvalidLimit => "S020",
        error.OutOfMemory => "I001",
        else => "I999",
    };
}

pub fn messageForError(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArguments => "invalid sqlz-codegen invocation",
        error.FileNotFound => "required project input was not found",
        error.AccessDenied => "project input could not be accessed",
        error.ParseError => "SQL syntax could not be parsed",
        error.MissingParent => "migration references a missing parent",
        error.Cycle => "migration graph contains a cycle",
        error.MultipleHeads => "migration graph must have one effective head",
        error.DivergentMerge => "migration merge parents have divergent catalogs",
        error.MissingRelation => "query references a missing relation",
        error.MissingColumn => "query references a missing column",
        error.AmbiguousColumn => "query column reference is ambiguous",
        error.UnknownCodec => "query references an unknown codec",
        error.IncompatibleCodec => "codec does not match the inferred database type",
        error.IncompatibleBackendContract => "backend query contracts are incompatible",
        error.OutOfMemory => "sqlz ran out of memory",
        else => "sqlz could not complete the project check",
    };
}

pub fn exitCode(err: anyerror) u8 {
    return if (isCheckedSourceError(err)) 1 else 2;
}

pub fn isCheckedSourceError(err: anyerror) bool {
    const code = codeForError(err);
    return code[0] == 'M' or code[0] == 'C' or code[0] == 'Q' or
        code[0] == 'T' or code[0] == 'G' or std.mem.eql(u8, code, "S010") or
        std.mem.eql(u8, code, "S020");
}
