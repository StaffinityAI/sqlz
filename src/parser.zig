const std = @import("std");
const libpg_query = @import("libpg_query");
const diagnostics = @import("sqlz_diagnostics");

pub const ast = libpg_query;

pub const RewrittenSql = struct {
    sql: []u8,
    names: []const []const u8,
    original_offsets: []const usize,

    pub fn deinit(self: *RewrittenSql, allocator: std.mem.Allocator) void {
        allocator.free(self.sql);
        for (self.names) |name| allocator.free(name);
        allocator.free(self.names);
        allocator.free(self.original_offsets);
        self.* = undefined;
    }
};

const ParameterStyle = enum { sqlite, postgres };

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
};

pub fn rewriteSqlite(allocator: std.mem.Allocator, source: []const u8) !RewrittenSql {
    return rewriteParameters(allocator, source, .sqlite);
}

pub fn rewritePostgres(allocator: std.mem.Allocator, source: []const u8) !RewrittenSql {
    return rewriteParameters(allocator, source, .postgres);
}

fn rewriteParameters(
    allocator: std.mem.Allocator,
    source: []const u8,
    comptime style: ParameterStyle,
) !RewrittenSql {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var offsets: std.ArrayList(usize) = .empty;
    errdefer offsets.deinit(allocator);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    const State = enum {
        normal,
        single,
        double,
        backtick,
        bracket,
        line_comment,
        block_comment,
    };
    var state: State = .normal;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        switch (state) {
            .normal => {
                if (c == '\'') state = .single else if (c == '"') state = .double else if (c == 0x60) state = .backtick else if (c == '[') state = .bracket else if (c == '-' and i + 1 < source.len and source[i + 1] == '-') state = .line_comment else if (c == '/' and i + 1 < source.len and source[i + 1] == '*') state = .block_comment else if (c == ':' and (i == 0 or source[i - 1] != ':') and i + 1 < source.len and isIdentStart(source[i + 1])) {
                    var end = i + 2;
                    while (end < source.len and isIdentContinue(source[end])) : (end += 1) {}
                    const name = source[i + 1 .. end];
                    var ordinal: usize = 0;
                    for (names.items, 1..) |existing, candidate| {
                        if (std.mem.eql(u8, existing, name)) {
                            ordinal = candidate;
                            break;
                        }
                    }
                    if (ordinal == 0) {
                        try names.append(allocator, try allocator.dupe(u8, name));
                        ordinal = names.items.len;
                    }
                    const marker = try std.fmt.allocPrint(allocator, switch (style) {
                        .sqlite => "?{d}",
                        .postgres => "$" ++ "{d}",
                    }, .{ordinal});
                    defer allocator.free(marker);
                    try output.appendSlice(allocator, marker);
                    try offsets.appendNTimes(allocator, i, marker.len);
                    i = end;
                    continue;
                }
            },
            .single => if (c == '\'' and !(i + 1 < source.len and source[i + 1] == '\'')) {
                state = .normal;
            } else if (c == '\'' and i + 1 < source.len and source[i + 1] == '\'') {
                try output.append(allocator, c);
                try offsets.append(allocator, i);
                i += 1;
            },
            .double => {
                if (c == '"') state = .normal;
            },
            .backtick => {
                if (c == 0x60) state = .normal;
            },
            .bracket => {
                if (c == ']') state = .normal;
            },
            .line_comment => {
                if (c == '\n') state = .normal;
            },
            .block_comment => if (c == '*' and i + 1 < source.len and source[i + 1] == '/') {
                try output.append(allocator, c);
                try offsets.append(allocator, i);
                i += 1;
                state = .normal;
            },
        }
        try output.append(allocator, c);
        try offsets.append(allocator, i);
        i += 1;
    }
    try offsets.append(allocator, source.len);

    return .{
        .sql = try output.toOwnedSlice(allocator),
        .names = try names.toOwnedSlice(allocator),
        .original_offsets = try offsets.toOwnedSlice(allocator),
    };
}

pub const ParseError = error{ EmptyInput, ParseError, UnsupportedSqliteFeature } || std.mem.Allocator.Error;

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
    message: []const u8,
    path: []const u8,
    original_offset: usize,
    rewritten_offset: usize,
    line: usize,
    column: usize,

    pub fn structured(self: *const Diagnostic) diagnostics.Diagnostic {
        const position: diagnostics.Position = .{
            .offset = self.original_offset,
            .line = self.line,
            .column = self.column,
        };
        return .{
            .severity = .err,
            .code = "S010",
            .message = self.message,
            .primary = .{
                .path = self.path,
                .start = position,
                .end = .{
                    .offset = self.original_offset + 1,
                    .line = self.line,
                    .column = self.column + 1,
                },
            },
            .labels = &.{},
            .notes = &.{"reported by the PostgreSQL grammar after portable parameter rewriting"},
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

pub fn parseDetailed(
    allocator: std.mem.Allocator,
    source: []const u8,
) (error{EmptyInput} || std.mem.Allocator.Error)!DetailedResult {
    return parseDetailedSource(allocator, "<sql>", source);
}

pub fn parseDetailedSource(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
) (error{EmptyInput} || std.mem.Allocator.Error)!DetailedResult {
    if (source.len == 0) return error.EmptyInput;
    var rewritten = try rewritePostgres(allocator, source);
    errdefer rewritten.deinit(allocator);

    const terminated = try allocator.dupeZ(u8, rewritten.sql);
    defer allocator.free(terminated);

    const native = libpg_query.pg_query_parse_protobuf(terminated.ptr);
    defer libpg_query.pg_query_free_protobuf_parse_result(native);
    if (native.@"error") |native_error| {
        const cursor: usize = if (native_error.*.cursorpos <= 0)
            0
        else
            @min(@as(usize, @intCast(native_error.*.cursorpos - 1)), rewritten.sql.len);
        const message = try allocator.dupe(u8, std.mem.span(native_error.*.message));
        const original_offset = rewritten.original_offsets[cursor];
        const position = sourcePosition(source, original_offset);
        rewritten.deinit(allocator);
        return .{ .syntax_error = .{
            .allocator = allocator,
            .message = message,
            .path = path,
            .original_offset = original_offset,
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

fn sourcePosition(source: []const u8, offset: usize) struct { line: usize, column: usize } {
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..@min(offset, source.len)]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!ParseResult {
    return switch (try parseDetailed(allocator, source)) {
        .ok => |result| result,
        .syntax_error => |value| {
            var diagnostic = value;
            diagnostic.deinit();
            return error.ParseError;
        },
    };
}

pub fn parsePostgresWithDialect(
    allocator: std.mem.Allocator,
    source: []const u8,
    dialect: PostgresDialect,
) ParseError!ParseResult {
    _ = dialect;
    return parse(allocator, source);
}

pub fn parseSqlite(allocator: std.mem.Allocator, source: []const u8) ParseError!ParseResult {
    return parseSqliteWithDialect(allocator, source, .{});
}

pub fn parseSqliteWithDialect(
    allocator: std.mem.Allocator,
    source: []const u8,
    dialect: SqliteDialect,
) ParseError!ParseResult {
    const normalized = try normalizeSqlite(allocator, source, dialect);
    defer allocator.free(normalized);
    var parsed = try parse(allocator, normalized);
    errdefer parsed.deinit();
    try validateSqliteTree(parsed.tree);
    return parsed;
}

fn validateSqliteTree(tree: *const libpg_query.PgQuery__ParseResult) error{UnsupportedSqliteFeature}!void {
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

fn normalizeSqlite(
    allocator: std.mem.Allocator,
    source: []const u8,
    dialect: SqliteDialect,
) (error{UnsupportedSqliteFeature} || std.mem.Allocator.Error)![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const State = enum { normal, single, double, backtick, bracket, line_comment, block_comment };
    var state: State = .normal;
    var index: usize = 0;
    while (index < source.len) {
        const c = source[index];
        if (state == .normal and c == ':' and index + 1 < source.len and source[index + 1] == ':')
            return error.UnsupportedSqliteFeature;
        if (state == .normal and c == '_' and index > 0 and index + 1 < source.len and
            std.ascii.isDigit(source[index - 1]) and std.ascii.isDigit(source[index + 1]))
        {
            if (@intFromEnum(dialect.profile) < @intFromEnum(SqliteProfile.v3_46))
                return error.UnsupportedSqliteFeature;
            // libpg_query does not recognize SQLite's separator. A digit keeps
            // the token numeric and preserves every source offset; runtime SQL
            // remains the original text.
            try output.append(allocator, '0');
            index += 1;
            continue;
        }
        if (state == .normal and isIdentStart(c)) {
            var end = index + 1;
            while (end < source.len and isIdentContinue(source[end])) : (end += 1) {}
            const word = source[index..end];
            if (std.ascii.eqlIgnoreCase(word, "ILIKE") or
                (std.ascii.eqlIgnoreCase(word, "SIMILAR") and keywordAfter(source, end, "TO") != null))
                return error.UnsupportedSqliteFeature;
            if (std.ascii.eqlIgnoreCase(word, "AUTOINCREMENT") or
                (std.ascii.eqlIgnoreCase(word, "STRICT") and isTrailingTableOption(source, index, end)))
            {
                try appendMasked(&output, allocator, source[index..end]);
                index = end;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(word, "WITHOUT")) {
                if (keywordAfter(source, end, "ROWID")) |rowid_end| {
                    try appendMasked(&output, allocator, source[index..rowid_end]);
                    index = rowid_end;
                    continue;
                }
            }
            try output.appendSlice(allocator, word);
            index = end;
            if (std.ascii.eqlIgnoreCase(word, "INSERT")) {
                if (keywordAfter(source, end, "OR")) |or_end| {
                    if (keywordAfter(source, or_end, "IGNORE")) |ignore_end| {
                        try appendMasked(&output, allocator, source[end..ignore_end]);
                        index = ignore_end;
                    }
                }
            }
            continue;
        }
        switch (state) {
            .normal => {
                if (c == '\'') state = .single else if (c == '"') state = .double else if (c == '`') state = .backtick else if (c == '[') state = .bracket else if (c == '-' and index + 1 < source.len and source[index + 1] == '-') state = .line_comment else if (c == '/' and index + 1 < source.len and source[index + 1] == '*') state = .block_comment;
            },
            .single => if (c == '\'' and !(index + 1 < source.len and source[index + 1] == '\'')) {
                state = .normal;
            } else if (c == '\'' and index + 1 < source.len and source[index + 1] == '\'') {
                try output.append(allocator, c);
                index += 1;
            },
            .double => if (c == '"') {
                state = .normal;
            },
            .backtick => if (c == '`') {
                state = .normal;
            },
            .bracket => if (c == ']') {
                state = .normal;
            },
            .line_comment => if (c == '\n') {
                state = .normal;
            },
            .block_comment => if (c == '*' and index + 1 < source.len and source[index + 1] == '/') {
                try output.append(allocator, c);
                index += 1;
                state = .normal;
            },
        }
        try output.append(allocator, source[index]);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
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

fn appendMasked(output: *std.ArrayList(u8), allocator: std.mem.Allocator, source: []const u8) !void {
    for (source) |c| try output.append(allocator, if (c == '\n' or c == '\r') c else ' ');
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}
