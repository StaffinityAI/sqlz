const std = @import("std");
const source = @import("sqlz_source");

pub const format_version: u32 = 1;

pub const Severity = enum { err, warning, note };
pub const Format = enum { human, json };

pub const Position = source.Position;

pub const Span = struct {
    path: []const u8,
    start: Position,
    end: Position,
    /// The original text of the line holding `start`, without its line ending,
    /// when the producer had the source at hand. Human output renders it with
    /// an underline; JSON consumers already have the offsets.
    excerpt: ?[]const u8 = null,
};

pub fn positionAt(text: []const u8, offset: usize) Position {
    return source.positionAt(text, offset);
}

/// The span of `start..end` in `text`, carrying the excerpt of its first line.
pub fn spanAt(path: []const u8, text: []const u8, start: usize, end: usize) Span {
    return .{
        .path = path,
        .start = source.positionAt(text, start),
        .end = source.positionAt(text, @max(start, end)),
        .excerpt = source.lineAt(text, start),
    };
}

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

pub const List = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic) = .empty,
    limit: usize,
    truncated: bool = false,

    pub fn init(allocator: std.mem.Allocator, limit: usize) List {
        return .{ .arena = .init(allocator), .limit = limit };
    }

    pub fn deinit(self: *List) void {
        self.items.deinit(self.arena.child_allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn appendDiagnostic(self: *List, diagnostic: Diagnostic) std.mem.Allocator.Error!void {
        if (self.items.items.len >= self.limit) {
            self.truncated = true;
            return;
        }
        const allocator = self.arena.allocator();
        const primary = if (diagnostic.primary) |span| try duplicateSpan(allocator, span) else null;
        const labels = try allocator.alloc(Label, diagnostic.labels.len);
        for (diagnostic.labels, labels) |label, *copy| copy.* = .{
            .span = try duplicateSpan(allocator, label.span),
            .message = try allocator.dupe(u8, label.message),
            .primary = label.primary,
        };
        const notes = try allocator.alloc([]const u8, diagnostic.notes.len);
        for (diagnostic.notes, notes) |note, *copy| copy.* = try allocator.dupe(u8, note);
        try self.items.append(self.arena.child_allocator, .{
            .severity = diagnostic.severity,
            .code = try allocator.dupe(u8, diagnostic.code),
            .message = try allocator.dupe(u8, diagnostic.message),
            .primary = primary,
            .labels = labels,
            .notes = notes,
            .help = if (diagnostic.help) |help| try allocator.dupe(u8, help) else null,
        });
    }

    pub fn appendError(
        self: *List,
        err: anyerror,
        path: ?[]const u8,
    ) std.mem.Allocator.Error!void {
        if (self.items.items.len >= self.limit) {
            self.truncated = true;
            return;
        }
        const allocator = self.arena.allocator();
        const note = try allocator.dupe(u8, @errorName(err));
        const notes = try allocator.alloc([]const u8, 1);
        notes[0] = note;
        const primary: ?Span = if (path) |value| .{
            .path = try allocator.dupe(u8, value),
            .start = .{ .offset = 0, .line = 1, .column = 1 },
            .end = .{ .offset = 0, .line = 1, .column = 1 },
        } else null;
        try self.items.append(self.arena.child_allocator, .{
            .severity = .err,
            .code = codeForError(err),
            .message = messageForError(err),
            .primary = primary,
            .notes = notes,
        });
    }

    pub fn setLimit(self: *List, limit: usize) void {
        self.limit = limit;
        if (self.items.items.len > self.limit) {
            self.items.shrinkRetainingCapacity(self.limit);
            self.truncated = true;
        }
    }

    pub fn slice(self: *const List) []const Diagnostic {
        return self.items.items;
    }
};

fn duplicateSpan(allocator: std.mem.Allocator, span: Span) std.mem.Allocator.Error!Span {
    return .{
        .path = try allocator.dupe(u8, span.path),
        .start = span.start,
        .end = span.end,
        .excerpt = if (span.excerpt) |text| try allocator.dupe(u8, text) else null,
    };
}

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
    if (diagnostic.primary) |span| try renderExcerpt(writer, span, '^');
    for (diagnostic.labels) |label| {
        try writer.print("  {s}:{d}:{d}: {s}: {s}\n", .{
            label.span.path,
            label.span.start.line,
            label.span.start.column,
            if (label.primary) "label" else "note",
            label.message,
        });
        try renderExcerpt(writer, label.span, if (label.primary) '^' else '-');
    }
    for (diagnostic.notes) |note| try writer.print("  = note: {s}\n", .{note});
    if (diagnostic.help) |help| try writer.print("  = help: {s}\n", .{help});
}

/// Renders a span's excerpt under a gutter as wide as its line number:
///
///   |
/// 6 | SELECT nickname FROM users
///   |        ^^^^^^^^
///
/// Tabs are expanded to the fixed excerpt width, so the underline lines up
/// with the text above it on any terminal.
fn renderExcerpt(writer: *std.Io.Writer, span: Span, mark: u8) !void {
    const line = span.excerpt orelse return;
    const gutter = std.fmt.count("{d}", .{span.start.line});
    const start = scalarPrefix(line, span.start.column - 1);
    const end = if (span.end.line == span.start.line and span.end.column > span.start.column)
        scalarPrefix(line, span.end.column - 1)
    else
        line.len;
    const pad = source.displayWidth(line[0..start]);
    const width = @max(source.displayWidth(line[start..@max(start, end)]), 1);
    try writer.splatByteAll(' ', gutter + 1);
    try writer.writeAll("|\n");
    try writer.print("{d} | ", .{span.start.line});
    try source.writeDisplay(writer, line);
    try writer.writeByte('\n');
    try writer.splatByteAll(' ', gutter + 1);
    try writer.writeAll("| ");
    try writer.splatByteAll(' ', pad);
    try writer.splatByteAll(mark, width);
    try writer.writeByte('\n');
}

/// The byte length of the first `count` scalar values of `line`, clamped to
/// the line.
fn scalarPrefix(line: []const u8, count: usize) usize {
    var seen: usize = 0;
    for (line, 0..) |byte, index| {
        if (byte & 0xC0 == 0x80) continue;
        if (seen == count) return index;
        seen += 1;
    }
    return line.len;
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
        error.InvalidUtf8 => "S011",
        error.InvalidRevisionId, error.InvalidParentId, error.MissingParent, error.Cycle, error.MultipleHeads, error.DivergentMerge => "M001",
        error.MissingUpgradeSql, error.MissingDowngradeSql, error.UnexpectedBackendSql => "M002",
        error.MissingRelation => "Q020",
        error.MissingColumn => "Q021",
        error.AmbiguousColumn => "Q022",
        error.ConflictingResultType => "Q023",
        error.ConflictingParameterType => "Q024",
        error.UnsupportedStatement, error.DuplicateTable, error.DuplicateColumn => "C001",
        error.BackendNotSelected, error.UnexpectedResultColumns, error.MissingResultColumns, error.MissingDeclaredField, error.UnexpectedDeclaredField, error.DeclaredFieldOrder, error.DeclaredTypeMismatch, error.DeclaredNullabilityMismatch, error.UninferredDeclaredType, error.MissingDeclaredRow, error.UnexpectedDeclaredRow => "Q001",
        error.UnknownCodec, error.UnknownCodecTarget, error.IncompatibleCodec, error.MissingCodecForDeclaredType => "T001",
        error.InvalidNamespace, error.NamespaceCollision, error.DuplicateQueryVariant, error.UnsupportedType, error.IncompatibleBackendContract => "G001",
        error.ProjectCheckFailed => "G002",
        error.DiagnosticLimitReached => "S099",
        error.UnsupportedFormatVersion, error.InvalidProjectId, error.InvalidPath, error.InvalidLimit, error.RuntimeBackendWithoutProfile, error.MissingBackend, error.InvalidSqlRootAlias, error.UnsupportedSqliteProfile, error.UnsupportedSqliteCapabilities, error.UnsupportedPostgresProfile, error.InvalidCodecId, error.MissingCodecPatterns, error.UnsupportedCatalogSupplements => "S020",
        error.ConfigurationTooLarge, error.SourceTooLarge, error.RegisteredSourceLimitExceeded, error.RevisionLimitExceeded, error.QueryLimitExceeded, error.TokenLimitExceeded, error.NestingLimitExceeded => "S021",
        error.PathEscapesProject, error.SymlinkedDirectory, error.NotRegularFile => "S022",
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
        error.InvalidUtf8 => "source is not valid UTF-8",
        error.MissingParent => "migration references a missing parent",
        error.Cycle => "migration graph contains a cycle",
        error.MultipleHeads => "migration graph must have one effective head",
        error.DivergentMerge => "migration merge parents have divergent catalogs",
        error.MissingRelation => "query references a missing relation",
        error.MissingColumn => "query references a missing column",
        error.AmbiguousColumn => "query column reference is ambiguous",
        error.ConflictingResultType => "set-operation result branches have conflicting types",
        error.ConflictingParameterType => "named parameter uses have conflicting types",
        error.UnknownCodec => "query references an unknown codec",
        error.DuplicateQueryVariant => "two query files in one directory define the same name for the same backend",
        error.RuntimeBackendWithoutProfile => "runtime backend has no checking profile in sqlz.ziggy",
        error.UnsupportedCatalogSupplements => "catalog supplements are not supported in sqlz 0.1",
        error.ConfigurationTooLarge => "sqlz.ziggy exceeds the 1 MiB configuration bound",
        error.SourceTooLarge => "source file exceeds `limits.source_bytes`",
        error.RegisteredSourceLimitExceeded => "project sources exceed `limits.registered_source_bytes`",
        error.RevisionLimitExceeded => "migration revisions exceed `limits.revisions`",
        error.QueryLimitExceeded => "project queries exceed `limits.queries`",
        error.TokenLimitExceeded => "source exceeds `limits.tokens_per_source`",
        error.NestingLimitExceeded => "source nesting exceeds `limits.nesting_depth`",
        error.PathEscapesProject => "project input resolves outside the project directory",
        error.SymlinkedDirectory => "symlinked directories are not followed in project roots",
        error.NotRegularFile => "project input is not a regular file",
        error.IncompatibleCodec => "codec does not match the inferred database type",
        error.IncompatibleBackendContract => "backend query contracts are incompatible",
        error.ProjectCheckFailed => "project checking produced one or more diagnostics",
        error.DiagnosticLimitReached => "additional diagnostics were suppressed",
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
        code[0] == 'T' or code[0] == 'G' or std.mem.eql(u8, code, "S010") or std.mem.eql(u8, code, "S011") or
        std.mem.eql(u8, code, "S020") or std.mem.eql(u8, code, "S021") or
        std.mem.eql(u8, code, "S022");
}
