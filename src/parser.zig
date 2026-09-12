const std = @import("std");
const libpg_query = @import("libpg_query");

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

pub const ParseError = error{ EmptyInput, ParseError } || std.mem.Allocator.Error;

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
    original_offset: usize,
    rewritten_offset: usize,

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
        rewritten.deinit(allocator);
        return .{ .syntax_error = .{
            .allocator = allocator,
            .message = message,
            .original_offset = original_offset,
            .rewritten_offset = cursor,
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

pub fn parseSqlite(allocator: std.mem.Allocator, source: []const u8) ParseError!ParseResult {
    const normalized = try normalizeSqlite(allocator, source);
    defer allocator.free(normalized);
    return parse(allocator, normalized);
}

fn normalizeSqlite(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const State = enum { normal, single, double, backtick, bracket, line_comment, block_comment };
    var state: State = .normal;
    var index: usize = 0;
    while (index < source.len) {
        const c = source[index];
        if (state == .normal and isIdentStart(c)) {
            var end = index + 1;
            while (end < source.len and isIdentContinue(source[end])) : (end += 1) {}
            const word = source[index..end];
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
