//! The shared SQL lexer. It splits source bytes into tokens with exact byte
//! spans for both dialects, which is all sqlz needs before `libpg_query` sees
//! the text: named parameters to rewrite, string and comment contexts where a
//! colon is never a parameter, and a bound on how much and how deeply nested
//! SQL reaches the parser. Whether a word is a keyword in a position is the
//! parser's business.
const std = @import("std");

pub const Dialect = enum { sqlite, postgres };

pub const Kind = enum {
    identifier,
    /// `"name"` in both dialects, plus `` `name` `` and `[name]` in SQLite.
    quoted_identifier,
    /// `'text'`, PostgreSQL `E'text'` and `$tag$text$tag$`.
    string,
    number,
    /// A sqlz named parameter, `:name`.
    parameter,
    /// A native placeholder: `$1` in PostgreSQL, `?`, `?1`, `$name`, or
    /// `@name` in SQLite.
    placeholder,
    operator,
    /// `(`, `)`, `[`, `]`, `,`, `;`, `.`, and a lone `:`.
    punctuation,
    line_comment,
    block_comment,
};

pub const Token = struct {
    kind: Kind,
    start: usize,
    end: usize,

    pub fn text(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// Lexing never fails: an unterminated string, identifier, or comment runs to
/// the end of the source and leaves the error to the parser, which reports it
/// with a position. Every byte belongs to exactly one token or to whitespace,
/// and tokens are produced in source order.
pub const Lexer = struct {
    source: []const u8,
    dialect: Dialect,
    index: usize,

    pub fn init(source: []const u8, dialect: Dialect) Lexer {
        // A byte order mark is not SQL; it is skipped like whitespace.
        const start: usize = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) 3 else 0;
        return .{ .source = source, .dialect = dialect, .index = start };
    }

    pub fn next(self: *Lexer) ?Token {
        const source = self.source;
        while (self.index < source.len and isSpace(source[self.index])) self.index += 1;
        if (self.index >= source.len) return null;
        const start = self.index;
        const kind = self.scan();
        std.debug.assert(self.index > start and self.index <= source.len);
        return .{ .kind = kind, .start = start, .end = self.index };
    }

    fn scan(self: *Lexer) Kind {
        const source = self.source;
        const c = source[self.index];
        const next_byte: u8 = if (self.index + 1 < source.len) source[self.index + 1] else 0;
        switch (c) {
            '\'' => {
                self.index = quotedEnd(source, self.index, '\'', false);
                return .string;
            },
            '"' => {
                self.index = quotedEnd(source, self.index, '"', false);
                return .quoted_identifier;
            },
            '`' => if (self.dialect == .sqlite) {
                self.index = quotedEnd(source, self.index, '`', false);
                return .quoted_identifier;
            },
            '[' => if (self.dialect == .sqlite) {
                self.index = std.mem.indexOfScalarPos(u8, source, self.index + 1, ']') orelse source.len;
                if (self.index < source.len) self.index += 1;
                return .quoted_identifier;
            },
            '-' => if (next_byte == '-') {
                self.index = std.mem.indexOfScalarPos(u8, source, self.index, '\n') orelse source.len;
                return .line_comment;
            },
            '/' => if (next_byte == '*') {
                self.index = self.blockCommentEnd(self.index);
                return .block_comment;
            },
            ':' => {
                if (next_byte == ':') {
                    self.index += 2;
                    return .operator;
                }
                if (isAsciiIdentStart(next_byte)) {
                    self.index += 2;
                    while (self.index < source.len and isAsciiIdentContinue(source[self.index])) self.index += 1;
                    return .parameter;
                }
                self.index += 1;
                return .punctuation;
            },
            '$' => {
                if (std.ascii.isDigit(next_byte)) {
                    self.index += 1;
                    while (self.index < source.len and std.ascii.isDigit(source[self.index])) self.index += 1;
                    return .placeholder;
                }
                if (self.dialect == .postgres) {
                    if (dollarTagEnd(source, self.index)) |tag_end| {
                        const tag = source[self.index..tag_end];
                        const close = std.mem.indexOfPos(u8, source, tag_end, tag);
                        self.index = if (close) |position| position + tag.len else source.len;
                        return .string;
                    }
                } else if (isIdentStart(next_byte)) {
                    self.index += 1;
                    self.index = identifierEnd(source, self.index);
                    return .placeholder;
                }
            },
            '?' => if (self.dialect == .sqlite) {
                self.index += 1;
                while (self.index < source.len and std.ascii.isDigit(source[self.index])) self.index += 1;
                return .placeholder;
            },
            '@' => if (self.dialect == .sqlite and isIdentStart(next_byte)) {
                self.index = identifierEnd(source, self.index + 1);
                return .placeholder;
            },
            '(', ')', ']', ',', ';' => {
                self.index += 1;
                return .punctuation;
            },
            '.' => if (!std.ascii.isDigit(next_byte)) {
                self.index += 1;
                return .punctuation;
            },
            else => {},
        }
        if (c == '[') {
            self.index += 1;
            return .punctuation;
        }
        if (std.ascii.isDigit(c) or c == '.') {
            self.index = numberEnd(source, self.index);
            return .number;
        }
        if (isIdentStart(c)) {
            const end = identifierEnd(source, self.index);
            // `E'...'` is one PostgreSQL escape-string token, in which a
            // backslash escapes the quote that follows it.
            if (self.dialect == .postgres and end == self.index + 1 and
                (c == 'E' or c == 'e') and end < source.len and source[end] == '\'')
            {
                self.index = quotedEnd(source, end, '\'', true);
                return .string;
            }
            self.index = end;
            return .identifier;
        }
        if (isOperatorChar(c)) {
            self.index += 1;
            // An operator stops where a comment starts, as in PostgreSQL.
            while (self.index < source.len and isOperatorChar(source[self.index]) and
                !startsComment(source, self.index)) self.index += 1;
            return .operator;
        }
        // Anything else is a single-byte token the parser will reject; a
        // multibyte character stays whole.
        self.index += std.unicode.utf8ByteSequenceLength(c) catch 1;
        self.index = @min(self.index, source.len);
        return .punctuation;
    }

    fn blockCommentEnd(self: *const Lexer, start: usize) usize {
        const source = self.source;
        std.debug.assert(source[start] == '/' and source[start + 1] == '*');
        // PostgreSQL comments nest; SQLite's end at the first `*/`.
        var depth: usize = 1;
        var index = start + 2;
        while (index + 1 < source.len) {
            if (source[index] == '*' and source[index + 1] == '/') {
                depth -= 1;
                index += 2;
                if (depth == 0) return index;
            } else if (self.dialect == .postgres and source[index] == '/' and source[index + 1] == '*') {
                depth += 1;
                index += 2;
            } else {
                index += 1;
            }
        }
        return source.len;
    }
};

/// Where a quoted token that opens at `start` with `quote` ends. A doubled
/// quote is an escaped quote; with `backslash`, so is `\` before any byte.
fn quotedEnd(source: []const u8, start: usize, quote: u8, backslash: bool) usize {
    std.debug.assert(source[start] == quote);
    var index = start + 1;
    while (index < source.len) {
        const c = source[index];
        if (backslash and c == '\\') {
            index = @min(index + 2, source.len);
        } else if (c == quote) {
            if (index + 1 < source.len and source[index + 1] == quote) {
                index += 2;
            } else {
                return index + 1;
            }
        } else {
            index += 1;
        }
    }
    return source.len;
}

/// The end of a `$tag$` or `$$` opener at `start`, or null when the `$` does
/// not open a dollar quote.
fn dollarTagEnd(source: []const u8, start: usize) ?usize {
    std.debug.assert(source[start] == '$');
    var index = start + 1;
    if (index < source.len and source[index] == '$') return index + 1;
    if (index >= source.len or !isIdentStart(source[index])) return null;
    while (index < source.len) : (index += 1) {
        const c = source[index];
        if (!isIdentStart(c) and !std.ascii.isDigit(c)) break;
    }
    if (index < source.len and source[index] == '$') return index + 1;
    return null;
}

fn identifierEnd(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len and (isIdentStart(source[index]) or
        std.ascii.isDigit(source[index]) or source[index] == '$')) index += 1;
    std.debug.assert(index >= start);
    return index;
}

fn numberEnd(source: []const u8, start: usize) usize {
    var index = start;
    if (source[index] == '0' and index + 1 < source.len and
        std.mem.indexOfScalar(u8, "xXoObB", source[index + 1]) != null)
    {
        index += 2;
        while (index < source.len and (std.ascii.isAlphanumeric(source[index]) or source[index] == '_')) index += 1;
        return index;
    }
    while (index < source.len) {
        const c = source[index];
        if (std.ascii.isDigit(c) or c == '_' or c == '.') {
            index += 1;
        } else if ((c == 'e' or c == 'E') and index + 1 < source.len and
            (std.ascii.isDigit(source[index + 1]) or
                ((source[index + 1] == '+' or source[index + 1] == '-') and
                    index + 2 < source.len and std.ascii.isDigit(source[index + 2]))))
        {
            index += 2;
        } else {
            break;
        }
    }
    std.debug.assert(index > start);
    return index;
}

fn startsComment(source: []const u8, index: usize) bool {
    if (index + 1 >= source.len) return false;
    return (source[index] == '-' and source[index + 1] == '-') or
        (source[index] == '/' and source[index + 1] == '*');
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn isOperatorChar(c: u8) bool {
    return std.mem.indexOfScalar(u8, "+-*/<>=~!@#%^&|`?", c) != null;
}

/// Identifiers may hold any non-ASCII character in both dialects.
pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

/// Parameter names become Zig field names, so they stay ASCII.
pub fn isAsciiIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

pub fn isAsciiIdentContinue(c: u8) bool {
    return isAsciiIdentStart(c) or std.ascii.isDigit(c);
}

pub const Limits = struct {
    tokens: u64 = 1_000_000,
    nesting: u32 = 256,
};

pub const Violation = struct {
    limit: enum { tokens, nesting },
    /// The token that crossed the limit.
    start: usize,
    end: usize,

    pub fn err(self: Violation) error{ TokenLimitExceeded, NestingLimitExceeded } {
        return switch (self.limit) {
            .tokens => error.TokenLimitExceeded,
            .nesting => error.NestingLimitExceeded,
        };
    }
};

/// Checks `source` against the token and nesting limits and returns the first
/// token that crosses one. Comments are not tokens.
///
/// Nesting approximates the depth of the tree the parser will build, because
/// that depth, not bracket depth alone, is what the parser and every tree
/// walker after it recurse on. Each open bracket and `CASE` is a level. Inside
/// a level, every operator or operator keyword in one list element nests the
/// next operand one level deeper, so `1+1+1` is three levels deep, while
/// `AND`/`OR` chains, which the parser flattens, cost one. Set operations and
/// joins nest the whole statement and accumulate until the next `;`.
///
/// SQLite text is checked twice: as SQLite lexes it, and as PostgreSQL does,
/// because the shared grammar parses it with PostgreSQL's lexer. A backtick or
/// bracket that SQLite reads as one quoted identifier could otherwise hide an
/// arbitrarily deep expression from the check.
pub fn checkLimits(source: []const u8, dialect: Dialect, limits: Limits) ?Violation {
    return switch (dialect) {
        .postgres => checkLexed(source, .postgres, limits),
        .sqlite => checkLexed(source, .sqlite, limits) orelse checkLexed(source, .postgres, limits),
    };
}

fn checkLexed(source: []const u8, dialect: Dialect, limits: Limits) ?Violation {
    std.debug.assert(limits.tokens > 0 and limits.nesting > 0);
    std.debug.assert(limits.nesting <= max_nesting_depth);
    var lexer: Lexer = .init(source, dialect);
    var tokens: u64 = 0;
    var nesting: Nesting = .{ .limit = limits.nesting };
    while (lexer.next()) |token| {
        if (token.kind == .line_comment or token.kind == .block_comment) continue;
        tokens += 1;
        if (tokens > limits.tokens) return .{ .limit = .tokens, .start = token.start, .end = token.end };
        if (!nesting.accept(token, source)) return .{ .limit = .nesting, .start = token.start, .end = token.end };
    }
    return null;
}

/// The nesting estimate for `checkLimits`. Its level stack holds no more than
/// `limit` entries, since crossing the limit ends the check, so it lives in a
/// fixed buffer sized for the largest limit sqlz accepts.
const Nesting = struct {
    pub const max_limit: u32 = 1024;

    const Level = struct {
        kind: enum { bracket, case },
        /// Depth of the enclosing level's tokens, restored on close.
        operators: u32,
        chain: u32,
        base: u32,
    };

    limit: u32,
    levels: [max_limit]Level = undefined,
    count: u32 = 0,
    /// Depth contributed by enclosing levels.
    base: u32 = 0,
    operators: u32 = 0,
    chain: u32 = 0,

    fn depth(self: *const Nesting) u64 {
        return @as(u64, self.base) + self.operators + self.chain;
    }

    fn accept(self: *Nesting, token: Token, source: []const u8) bool {
        std.debug.assert(self.count <= self.limit);
        const text = token.text(source);
        switch (token.kind) {
            .punctuation => {
                if (text.len != 1) return true;
                switch (text[0]) {
                    '(', '[' => return self.open(.bracket),
                    ')', ']' => self.close(.bracket),
                    ',' => self.operators = 0,
                    ';' => {
                        self.operators = 0;
                        self.chain = 0;
                    },
                    else => {},
                }
            },
            .operator => {
                // `::` and other symbol operators all nest their operands.
                self.operators += 1;
            },
            .identifier => {
                if (keyword(text, &.{"CASE"})) return self.open(.case);
                if (keyword(text, &.{"END"})) {
                    self.close(.case);
                } else if (keyword(text, &.{ "AND", "OR" })) {
                    self.operators = 1;
                } else if (keyword(text, &.{ "UNION", "INTERSECT", "EXCEPT", "JOIN" })) {
                    self.chain += 1;
                } else if (keyword(text, &.{
                    "NOT",     "IS",      "ISNULL", "NOTNULL", "LIKE",     "ILIKE",
                    "SIMILAR", "BETWEEN", "IN",     "COLLATE", "AT",       "OVERLAPS",
                    "ESCAPE",  "GLOB",    "REGEXP", "MATCH",   "OPERATOR",
                })) {
                    self.operators += 1;
                } else if (keyword(text, &.{
                    "SELECT",    "FROM",   "WHERE",  "GROUP", "HAVING", "ORDER",
                    "LIMIT",     "OFFSET", "VALUES", "SET",   "ON",     "USING",
                    "WHEN",      "THEN",   "ELSE",   "INTO",  "AS",     "WINDOW",
                    "RETURNING", "BY",     "DO",     "WITH",
                })) {
                    self.operators = 0;
                }
            },
            else => {},
        }
        return self.depth() <= self.limit;
    }

    fn open(self: *Nesting, kind: @FieldType(Level, "kind")) bool {
        const depth_before = self.depth();
        if (depth_before + 1 > self.limit) return false;
        std.debug.assert(self.count < self.limit);
        self.levels[self.count] = .{
            .kind = kind,
            .operators = self.operators,
            .chain = self.chain,
            .base = self.base,
        };
        self.count += 1;
        self.base = @intCast(depth_before + 1);
        self.operators = 0;
        self.chain = 0;
        return true;
    }

    fn close(self: *Nesting, kind: @FieldType(Level, "kind")) void {
        // A stray closer is the parser's error to report, not a level.
        if (self.count == 0 or self.levels[self.count - 1].kind != kind) return;
        self.count -= 1;
        const level = self.levels[self.count];
        self.base = level.base;
        self.operators = level.operators;
        self.chain = level.chain;
    }
};

pub const max_nesting_depth = Nesting.max_limit;

fn keyword(text: []const u8, comptime words: []const []const u8) bool {
    inline for (words) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return true;
    }
    return false;
}
