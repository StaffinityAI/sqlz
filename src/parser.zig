const std = @import("std");
const libpg_query = @import("libpg_query");
const diagnostics = @import("sqlz_diagnostics");

pub const ast = libpg_query;

pub const lexer = @import("lexer.zig");
pub const Limits = lexer.Limits;

pub const RewrittenSql = struct {
    sql: []u8,
    names: []const []const u8,
    /// For each byte of `sql`, plus one past its end, the offset in the
    /// original source it came from. A marker maps every byte to the colon
    /// of the parameter it replaced.
    original_offsets: []const usize,

    pub fn deinit(self: *RewrittenSql, allocator: std.mem.Allocator) void {
        allocator.free(self.sql);
        for (self.names) |name| allocator.free(name);
        allocator.free(self.names);
        allocator.free(self.original_offsets);
        self.* = undefined;
    }
};

const MarkerStyle = enum { sqlite, postgres };

pub const SqliteProfile = enum(u8) {
    v3_45,
    v3_46,
    v3_47,
    v3_48,
    v3_49,
    v3_50,
    v3_51,
    v3_52,
    v3_53,

    pub fn fromString(value: []const u8) ?SqliteProfile {
        const values = [_][]const u8{
            "3.45", "3.46", "3.47", "3.48", "3.49",
            "3.50", "3.51", "3.52", "3.53",
        };
        for (values, 0..) |candidate, index| {
            if (std.mem.eql(u8, value, candidate)) return @enumFromInt(index);
        }
        return null;
    }
};

pub const SqliteDialect = struct {
    profile: SqliteProfile = .v3_53,
    limits: Limits = .{},
};

pub const PostgresProfile = enum(u8) {
    v15,
    v16,
    v17,
    v18,

    pub fn fromString(value: []const u8) ?PostgresProfile {
        const values = [_][]const u8{ "15", "16", "17", "18" };
        for (values, 0..) |candidate, index| {
            if (std.mem.eql(u8, value, candidate)) return @enumFromInt(index);
        }
        return null;
    }
};

pub const PostgresDialect = struct {
    profile: PostgresProfile = .v15,
    limits: Limits = .{},
};

/// Rewrites `:name` parameters to SQLite `?N` markers, lexing SQLite syntax.
pub fn rewriteSqlite(allocator: std.mem.Allocator, source: []const u8) !RewrittenSql {
    return rewriteParameters(allocator, source, .sqlite, .sqlite);
}

/// Rewrites `:name` parameters to PostgreSQL `$N` markers, lexing PostgreSQL
/// syntax.
pub fn rewritePostgres(allocator: std.mem.Allocator, source: []const u8) !RewrittenSql {
    return rewriteParameters(allocator, source, .postgres, .postgres);
}

/// Replaces each named parameter with a positional marker numbered in
/// first-use order and copies every other byte, so the output differs from
/// the source only at parameters. A byte order mark becomes spaces, keeping
/// every offset after it unchanged.
fn rewriteParameters(
    allocator: std.mem.Allocator,
    source: []const u8,
    dialect: lexer.Dialect,
    comptime style: MarkerStyle,
) std.mem.Allocator.Error!RewrittenSql {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var offsets: std.ArrayList(usize) = .empty;
    errdefer offsets.deinit(allocator);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var ordinals: std.StringHashMapUnmanaged(usize) = .empty;
    defer ordinals.deinit(allocator);
    try output.ensureTotalCapacity(allocator, source.len);
    try offsets.ensureTotalCapacity(allocator, source.len + 1);

    var copied: usize = 0;
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) {
        try output.appendSlice(allocator, "   ");
        try offsets.appendSlice(allocator, &.{ 0, 1, 2 });
        copied = 3;
    }
    var tokens: lexer.Lexer = .init(source, dialect);
    while (tokens.next()) |token| {
        if (token.kind != .parameter) continue;
        try appendOriginal(allocator, &output, &offsets, source, copied, token.start);
        const name = source[token.start + 1 .. token.end];
        const entry = try ordinals.getOrPut(allocator, name);
        if (!entry.found_existing) {
            try names.append(allocator, try allocator.dupe(u8, name));
            entry.value_ptr.* = names.items.len;
        }
        var marker_buffer: [24]u8 = undefined;
        const marker = std.fmt.bufPrint(&marker_buffer, switch (style) {
            .sqlite => "?{d}",
            .postgres => "${d}",
        }, .{entry.value_ptr.*}) catch unreachable;
        try output.appendSlice(allocator, marker);
        try offsets.appendNTimes(allocator, token.start, marker.len);
        copied = token.end;
    }
    try appendOriginal(allocator, &output, &offsets, source, copied, source.len);
    try offsets.append(allocator, source.len);
    std.debug.assert(offsets.items.len == output.items.len + 1);

    return .{
        .sql = try output.toOwnedSlice(allocator),
        .names = try names.toOwnedSlice(allocator),
        .original_offsets = try offsets.toOwnedSlice(allocator),
    };
}

fn appendOriginal(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    offsets: *std.ArrayList(usize),
    source: []const u8,
    start: usize,
    end: usize,
) std.mem.Allocator.Error!void {
    std.debug.assert(start <= end and end <= source.len);
    try output.appendSlice(allocator, source[start..end]);
    for (start..end) |offset| try offsets.append(allocator, offset);
}

pub const ParseError = error{
    EmptyInput,
    ParseError,
    UnsupportedSqliteFeature,
    TokenLimitExceeded,
    NestingLimitExceeded,
} || std.mem.Allocator.Error;

pub const ParseResult = struct {
    rewritten: RewrittenSql,
    tree: *libpg_query.PgQuery__ParseResult,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParseResult) void {
        libpg_query.pg_query__parse_result__free_unpacked(self.tree, null);
        self.rewritten.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const Diagnostic = struct {
    allocator: std.mem.Allocator,
    /// S010 for a grammar error, S021 for a token or nesting limit.
    code: []const u8 = "S010",
    message: []const u8,
    path: []const u8,
    original_offset: usize,
    original_end: usize,
    rewritten_offset: usize,
    line: usize,
    column: usize,

    pub fn structured(self: *const Diagnostic) diagnostics.Diagnostic {
        const position: diagnostics.Position = .{
            .offset = self.original_offset,
            .line = self.line,
            .column = self.column,
        };
        const width = @max(self.original_end, self.original_offset + 1) - self.original_offset;
        return .{
            .severity = .err,
            .code = self.code,
            .message = self.message,
            .primary = .{
                .path = self.path,
                .start = position,
                .end = .{
                    .offset = self.original_offset + width,
                    .line = self.line,
                    .column = self.column + width,
                },
            },
            .labels = &.{},
            .notes = if (std.mem.eql(u8, self.code, "S010"))
                &.{"reported by the PostgreSQL grammar after portable parameter rewriting"}
            else
                &.{},
        };
    }

    pub fn deinit(self: *Diagnostic) void {
        self.allocator.free(self.message);
        self.* = undefined;
    }
};

pub const DetailedResult = union(enum) {
    ok: ParseResult,
    syntax_error: Diagnostic,
};

pub const DetailedError = error{EmptyInput} || std.mem.Allocator.Error;

pub fn parseDetailed(
    allocator: std.mem.Allocator,
    source: []const u8,
) DetailedError!DetailedResult {
    return parseDetailedSource(allocator, "<sql>", source);
}

pub fn parseDetailedSource(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
) DetailedError!DetailedResult {
    return parseDetailedWithLimits(allocator, path, source, .{});
}

/// Parses PostgreSQL SQL and reports a grammar error, or a token or nesting
/// limit crossed before the grammar ran, as a diagnostic in the original
/// source.
pub fn parseDetailedWithLimits(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    limits: Limits,
) DetailedError!DetailedResult {
    return parseLexed(allocator, path, source, .postgres, limits);
}

fn parseLexed(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    dialect: lexer.Dialect,
    limits: Limits,
) DetailedError!DetailedResult {
    if (source.len == 0) return error.EmptyInput;
    // libpg_query reads a C string, so a NUL byte would hide everything after
    // it from the check while a driver might still send it.
    if (std.mem.indexOfScalar(u8, source, 0)) |offset| {
        const position = diagnostics.positionAt(source, offset);
        return .{ .syntax_error = .{
            .allocator = allocator,
            .message = try allocator.dupe(u8, "SQL contains a NUL byte"),
            .path = path,
            .original_offset = offset,
            .original_end = offset + 1,
            .rewritten_offset = 0,
            .line = position.line,
            .column = position.column,
        } };
    }
    // Nothing reaches libpg_query until the source is known to be small and
    // shallow enough for it, since its tree serializer recurses once per
    // level and a long operator chain would overflow any stack.
    if (lexer.checkLimits(source, dialect, limits)) |violation| {
        const position = diagnostics.positionAt(source, violation.start);
        return .{ .syntax_error = .{
            .allocator = allocator,
            .code = "S021",
            .message = try allocator.dupe(u8, diagnostics.messageForError(violation.err())),
            .path = path,
            .original_offset = violation.start,
            .original_end = violation.end,
            .rewritten_offset = 0,
            .line = position.line,
            .column = position.column,
        } };
    }
    var rewritten = try rewriteParameters(allocator, source, dialect, .postgres);
    errdefer rewritten.deinit(allocator);

    const terminated = try allocator.dupeZ(u8, rewritten.sql);
    defer allocator.free(terminated);
    const native = libpg_query.pg_query_parse_protobuf(terminated.ptr);
    defer libpg_query.pg_query_free_protobuf_parse_result(native);
    if (native.@"error") |native_error| {
        // PostgreSQL reports a 1-based character position, not a byte offset.
        const cursor: usize = if (native_error.*.cursorpos <= 0)
            0
        else
            byteOffsetOfScalar(rewritten.sql, @intCast(native_error.*.cursorpos - 1));
        const message = try allocator.dupe(u8, std.mem.span(native_error.*.message));
        const original_offset = rewritten.original_offsets[cursor];
        const position = diagnostics.positionAt(source, original_offset);
        rewritten.deinit(allocator);
        return .{ .syntax_error = .{
            .allocator = allocator,
            .message = message,
            .path = path,
            .original_offset = original_offset,
            .original_end = original_offset + 1,
            .rewritten_offset = cursor,
            .line = position.line,
            .column = position.column,
        } };
    }
    const tree = libpg_query.pg_query__parse_result__unpack(
        null,
        native.parse_tree.len,
        @ptrCast(native.parse_tree.data),
    );
    if (tree == null) return error.OutOfMemory;
    return .{ .ok = .{
        .rewritten = rewritten,
        .tree = tree,
        .allocator = allocator,
    } };
}

/// The byte offset of the `index`th Unicode scalar value in `text`, clamped
/// to its length.
fn byteOffsetOfScalar(text: []const u8, index: usize) usize {
    var seen: usize = 0;
    for (text, 0..) |byte, offset| {
        if (byte & 0xC0 == 0x80) continue;
        if (seen == index) return offset;
        seen += 1;
    }
    return text.len;
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!ParseResult {
    return parseWithLimits(allocator, source, .postgres, .{});
}

fn parseWithLimits(
    allocator: std.mem.Allocator,
    source: []const u8,
    dialect: lexer.Dialect,
    limits: Limits,
) ParseError!ParseResult {
    return switch (try parseLexed(allocator, "<sql>", source, dialect, limits)) {
        .ok => |result| result,
        .syntax_error => |value| {
            var diagnostic = value;
            defer diagnostic.deinit();
            if (std.mem.eql(u8, diagnostic.code, "S021")) {
                const violation = lexer.checkLimits(source, dialect, limits).?;
                return violation.err();
            }
            return error.ParseError;
        },
    };
}

pub fn parsePostgresWithDialect(
    allocator: std.mem.Allocator,
    source: []const u8,
    dialect: PostgresDialect,
) ParseError!ParseResult {
    return parseWithLimits(allocator, source, .postgres, dialect.limits);
}

pub fn parseSqlite(allocator: std.mem.Allocator, source: []const u8) ParseError!ParseResult {
    return parseSqliteWithDialect(allocator, source, .{});
}

/// Checks limits against the SQLite text itself, then hands the normalized
/// text to the shared grammar. Normalization rejects every form the two
/// dialects would lex differently, so the SQLite lexer's view of the source
/// is the one the grammar parses.
pub fn parseSqliteWithDialect(
    allocator: std.mem.Allocator,
    source: []const u8,
    dialect: SqliteDialect,
) ParseError!ParseResult {
    if (lexer.checkLimits(source, .sqlite, dialect.limits)) |violation| return violation.err();
    const normalized = try normalizeSqlite(allocator, source, dialect);
    defer allocator.free(normalized);
    var parsed = try parseWithLimits(allocator, normalized, .sqlite, dialect.limits);
    errdefer parsed.deinit();
    try validateSqliteTree(parsed.tree);
    return parsed;
}

fn validateSqliteTree(tree: *const libpg_query.PgQuery__ParseResult) error{UnsupportedSqliteFeature}!void {
    // An empty statement list, such as `;` alone, has no array at all.
    if (tree.n_stmts == 0) return;
    for (tree.stmts[0..tree.n_stmts]) |raw| {
        if (raw == null or raw.*.stmt == null) continue;
        try validateSqliteNode(raw.*.stmt);
    }
}

fn validateSqliteNode(node: [*c]libpg_query.PgQuery__Node) error{UnsupportedSqliteFeature}!void {
    if (node == null) return;
    switch (node.*.node_case) {
        libpg_query.PG_QUERY__NODE__NODE_SELECT_STMT => try validateSqliteSelect(node.*.unnamed_0.select_stmt),
        libpg_query.PG_QUERY__NODE__NODE_INSERT_STMT => {
            const statement = node.*.unnamed_0.insert_stmt;
            if (statement == null) return;
            if (statement.*.override != libpg_query.PG_QUERY__OVERRIDING_KIND__OVERRIDING_KIND_UNDEFINED and
                statement.*.override != libpg_query.PG_QUERY__OVERRIDING_KIND__OVERRIDING_NOT_SET)
                return error.UnsupportedSqliteFeature;
            try validateSqliteNode(statement.*.select_stmt);
            try validateSqliteWith(statement.*.with_clause);
        },
        libpg_query.PG_QUERY__NODE__NODE_UPDATE_STMT => {
            const statement = node.*.unnamed_0.update_stmt;
            if (statement != null) try validateSqliteWith(statement.*.with_clause);
        },
        libpg_query.PG_QUERY__NODE__NODE_DELETE_STMT => {
            const statement = node.*.unnamed_0.delete_stmt;
            if (statement == null) return;
            if (statement.*.n_using_clause != 0) return error.UnsupportedSqliteFeature;
            try validateSqliteWith(statement.*.with_clause);
        },
        libpg_query.PG_QUERY__NODE__NODE_VIEW_STMT => {
            const statement = node.*.unnamed_0.view_stmt;
            if (statement != null) try validateSqliteNode(statement.*.query);
        },
        else => {},
    }
}

fn validateSqliteSelect(
    statement: [*c]libpg_query.PgQuery__SelectStmt,
) error{UnsupportedSqliteFeature}!void {
    if (statement == null) return;
    if (statement.*.into_clause != null or statement.*.n_locking_clause != 0 or
        statement.*.group_distinct != 0)
        return error.UnsupportedSqliteFeature;
    if (statement.*.n_distinct_clause != 0) {
        for (statement.*.distinct_clause[0..statement.*.n_distinct_clause]) |item| {
            if (item != null and item.*.node_case != libpg_query.PG_QUERY__NODE__NODE__NOT_SET)
                return error.UnsupportedSqliteFeature;
        }
    }
    try validateSqliteWith(statement.*.with_clause);
    if (statement.*.larg != null) try validateSqliteSelect(statement.*.larg);
    if (statement.*.rarg != null) try validateSqliteSelect(statement.*.rarg);
}

fn validateSqliteWith(
    clause: [*c]libpg_query.PgQuery__WithClause,
) error{UnsupportedSqliteFeature}!void {
    if (clause == null) return;
    if (clause.*.n_ctes == 0) return;
    for (clause.*.ctes[0..clause.*.n_ctes]) |node| {
        if (node == null or node.*.node_case != libpg_query.PG_QUERY__NODE__NODE_COMMON_TABLE_EXPR)
            continue;
        const cte = node.*.unnamed_0.common_table_expr;
        if (cte == null) continue;
        if (cte.*.search_clause != null or cte.*.cycle_clause != null)
            return error.UnsupportedSqliteFeature;
        try validateSqliteNode(cte.*.ctequery);
    }
}

/// Masks SQLite-only syntax the shared grammar does not know, byte for byte,
/// so every offset into the result is an offset into `source`. Forms that are
/// valid in both dialects but lex differently — a dollar quote, an `E'...'`
/// string, a nested block comment — are rejected rather than guessed at.
fn normalizeSqlite(
    allocator: std.mem.Allocator,
    source: []const u8,
    dialect: SqliteDialect,
) (error{UnsupportedSqliteFeature} || std.mem.Allocator.Error)![]u8 {
    const output = try allocator.dupe(u8, source);
    errdefer allocator.free(output);
    var tokens: lexer.Lexer = .init(source, .sqlite);
    var previous: ?lexer.Token = null;
    while (tokens.next()) |token| : (previous = token) {
        const text = token.text(source);
        switch (token.kind) {
            .operator => if (std.mem.eql(u8, text, "::")) return error.UnsupportedSqliteFeature,
            .block_comment => if (std.mem.indexOf(u8, text[2..], "/*") != null)
                return error.UnsupportedSqliteFeature,
            // `$name` is a SQLite parameter but opens a dollar quote, or is an
            // error, in PostgreSQL.
            .placeholder => if (text[0] == '$') return error.UnsupportedSqliteFeature,
            .punctuation => if (text[0] == '$') return error.UnsupportedSqliteFeature,
            .string => if (previous) |before| {
                if (before.kind == .identifier and before.end == token.start and
                    std.ascii.eqlIgnoreCase(before.text(source), "E"))
                    return error.UnsupportedSqliteFeature;
            },
            .number => if (std.mem.indexOfScalar(u8, text, '_')) |_| {
                if (@intFromEnum(dialect.profile) < @intFromEnum(SqliteProfile.v3_46))
                    return error.UnsupportedSqliteFeature;
                // libpg_query does not recognize SQLite's separator. A digit
                // keeps the token numeric and preserves every source offset;
                // runtime SQL remains the original text.
                for (token.start..token.end) |index| {
                    if (source[index] == '_' and index > token.start and
                        std.ascii.isDigit(source[index - 1]) and index + 1 < token.end and
                        std.ascii.isDigit(source[index + 1])) output[index] = '0';
                }
            },
            .identifier => {
                if (std.ascii.eqlIgnoreCase(text, "ILIKE") or
                    (std.ascii.eqlIgnoreCase(text, "SIMILAR") and keywordAfter(source, token.end, "TO") != null))
                    return error.UnsupportedSqliteFeature;
                if (std.ascii.eqlIgnoreCase(text, "AUTOINCREMENT") or
                    (std.ascii.eqlIgnoreCase(text, "STRICT") and isTrailingTableOption(source, token.start, token.end)))
                {
                    mask(output, token.start, token.end);
                } else if (std.ascii.eqlIgnoreCase(text, "WITHOUT")) {
                    if (keywordAfter(source, token.end, "ROWID")) |rowid_end| mask(output, token.start, rowid_end);
                } else if (std.ascii.eqlIgnoreCase(text, "INSERT")) {
                    if (keywordAfter(source, token.end, "OR")) |or_end| {
                        if (keywordAfter(source, or_end, "IGNORE")) |ignore_end| mask(output, token.end, ignore_end);
                    }
                }
            },
            else => {},
        }
    }
    std.debug.assert(output.len == source.len);
    return output;
}

fn mask(output: []u8, start: usize, end: usize) void {
    for (output[start..end]) |*c| {
        if (c.* != '\n' and c.* != '\r') c.* = ' ';
    }
}

fn keywordAfter(source: []const u8, start: usize, keyword: []const u8) ?usize {
    var index = start;
    while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
    if (index >= source.len or !isIdentStart(source[index])) return null;
    var end = index + 1;
    while (end < source.len and isIdentContinue(source[end])) : (end += 1) {}
    return if (std.ascii.eqlIgnoreCase(source[index..end], keyword)) end else null;
}

fn isTrailingTableOption(source: []const u8, start: usize, end: usize) bool {
    var before = start;
    while (before > 0 and std.ascii.isWhitespace(source[before - 1])) : (before -= 1) {}
    if (before == 0 or (source[before - 1] != ')' and source[before - 1] != ',')) return false;
    var after = end;
    while (after < source.len and std.ascii.isWhitespace(source[after])) : (after += 1) {}
    return after == source.len or source[after] == ',' or source[after] == ';';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}
