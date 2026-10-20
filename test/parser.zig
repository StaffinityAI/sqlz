const std = @import("std");
const parser = @import("sqlz_parser");
const diagnostics = @import("sqlz_diagnostics");

test "named parameters are rewritten once and retain first-use order" {
    var rewritten = try parser.rewriteSqlite(
        std.testing.allocator,
        "SELECT :identity = :identity, :other, ':ignored', \" :also_ignored\" -- :comment\n",
    );
    defer rewritten.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "SELECT ?1 = ?1, ?2, ':ignored', \" :also_ignored\" -- :comment\n",
        rewritten.sql,
    );
    try std.testing.expectEqual(@as(usize, 2), rewritten.names.len);
    try std.testing.expectEqualStrings("identity", rewritten.names[0]);
    try std.testing.expectEqualStrings("other", rewritten.names[1]);
    try std.testing.expectEqual(@as(usize, 7), rewritten.original_offsets[7]);
}

test "libpg_query parses shared SQL after portable parameter rewriting" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "WITH active AS (SELECT id FROM users WHERE tenant_id=:tenant) " ++
            "SELECT id FROM active WHERE id>:after OR :after IS NULL",
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "WITH active AS (SELECT id FROM users WHERE tenant_id=$1) " ++
            "SELECT id FROM active WHERE id>$2 OR $2 IS NULL",
        parsed.rewritten.sql,
    );
    try std.testing.expectEqual(@as(usize, 2), parsed.rewritten.names.len);
    try std.testing.expectEqualStrings("tenant", parsed.rewritten.names[0]);
    try std.testing.expectEqualStrings("after", parsed.rewritten.names[1]);
    try std.testing.expectEqual(@as(usize, 1), parsed.tree.n_stmts);
    const statement = parsed.tree.stmts[0].*.stmt;
    try std.testing.expectEqual(
        @as(c_uint, parser.ast.PG_QUERY__NODE__NODE_SELECT_STMT),
        statement.*.node_case,
    );
}

test "libpg_query covers returning and conflict queries used by SQLite examples" {
    var parsed = try parser.parse(
        std.testing.allocator,
        "INSERT INTO preferences(user_id, theme) VALUES (:user_id, :theme) " ++
            "ON CONFLICT(user_id) DO UPDATE SET theme=excluded.theme " ++
            "RETURNING user_id, theme",
    );
    defer parsed.deinit();

    const statement = parsed.tree.stmts[0].*.stmt;
    try std.testing.expectEqual(
        @as(c_uint, parser.ast.PG_QUERY__NODE__NODE_INSERT_STMT),
        statement.*.node_case,
    );
    try std.testing.expect(statement.*.unnamed_0.insert_stmt.*.on_conflict_clause != null);
    try std.testing.expectEqual(@as(usize, 2), parsed.rewritten.names.len);
}

test "PostgreSQL casts are not mistaken for named parameters" {
    var rewritten = try parser.rewritePostgres(
        std.testing.allocator,
        "SELECT :value::text, ':ignored::cast'",
    );
    defer rewritten.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("SELECT $1::text, ':ignored::cast'", rewritten.sql);
    try std.testing.expectEqual(@as(usize, 1), rewritten.names.len);
    try std.testing.expectEqualStrings("value", rewritten.names[0]);
}

test "PostgreSQL profiles parse supported versions" {
    try std.testing.expectEqual(parser.PostgresProfile.v15, parser.PostgresProfile.fromString("15").?);
    try std.testing.expectEqual(parser.PostgresProfile.v18, parser.PostgresProfile.fromString("18").?);
    try std.testing.expect(parser.PostgresProfile.fromString("14") == null);

    var parsed = try parser.parsePostgresWithDialect(
        std.testing.allocator,
        "SELECT :value::text",
        .{ .profile = .v17 },
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("SELECT $1::text", parsed.rewritten.sql);
}

test "syntax diagnostics map libpg_query positions to the original SQL" {
    const source = "SELECT 1;\nSELECT :identity FROM";
    const result = try parser.parseDetailedSource(std.testing.allocator, "queries/get.sql", source);
    switch (result) {
        .ok => |value| {
            var parsed = value;
            parsed.deinit();
            return error.ExpectedSyntaxError;
        },
        .syntax_error => |value| {
            var diagnostic = value;
            defer diagnostic.deinit();
            try std.testing.expect(diagnostic.message.len > 0);
            try std.testing.expect(diagnostic.original_offset <= source.len);
            try std.testing.expect(diagnostic.rewritten_offset <= source.len);
            try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
            try std.testing.expect(diagnostic.column > 1);
            const structured = diagnostic.structured();
            try std.testing.expectEqualStrings("S010", structured.code);
            try std.testing.expectEqualStrings("queries/get.sql", structured.primary.?.path);
            var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer output.deinit();
            try diagnostics.render(&output.writer, structured, .json);
            try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"line\":2") != null);
        },
    }
}

test "SQLite normalization accepts real-world conflict and table options" {
    var insert = try parser.parseSqlite(
        std.testing.allocator,
        "INSERT OR IGNORE INTO memberships(user_id) VALUES (:user_id)",
    );
    defer insert.deinit();
    try std.testing.expectEqual(
        @as(c_uint, parser.ast.PG_QUERY__NODE__NODE_INSERT_STMT),
        insert.tree.stmts[0].*.stmt.*.node_case,
    );
    try std.testing.expectEqualStrings("user_id", insert.rewritten.names[0]);

    var ddl = try parser.parseSqlite(
        std.testing.allocator,
        "CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT) STRICT;" ++
            "CREATE TABLE memberships (user_id INTEGER, role_id INTEGER, " ++
            "PRIMARY KEY (user_id, role_id)) WITHOUT ROWID",
    );
    defer ddl.deinit();
    try std.testing.expectEqual(@as(usize, 2), ddl.tree.n_stmts);

    var identifier = try parser.parseSqlite(std.testing.allocator, "SELECT strict FROM settings");
    defer identifier.deinit();
    try std.testing.expectEqual(@as(usize, 1), identifier.tree.n_stmts);
}

test "SQLite numeric separators are gated by the selected profile" {
    try std.testing.expectError(
        error.UnsupportedSqliteFeature,
        parser.parseSqliteWithDialect(
            std.testing.allocator,
            "SELECT 1_000 AS total",
            .{ .profile = .v3_45 },
        ),
    );

    var parsed = try parser.parseSqliteWithDialect(
        std.testing.allocator,
        "SELECT 1_000 AS total, '2_000' AS label -- 3_000\n",
        .{ .profile = .v3_46 },
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "SELECT 10000 AS total, '2_000' AS label -- 3_000\n",
        parsed.rewritten.sql,
    );
}

test "SQLite validation rejects PostgreSQL-only query clauses" {
    const unsupported = [_][]const u8{
        "SELECT id INTO archived_users FROM users",
        "SELECT id FROM users FOR UPDATE",
        "SELECT DISTINCT ON (name) name FROM users",
        "SELECT name::text FROM users",
        "SELECT name ILIKE 'a%' AS matches FROM users",
        "SELECT name SIMILAR TO 'a%' AS matches FROM users",
        "INSERT INTO users(id) OVERRIDING SYSTEM VALUE VALUES (1)",
        "DELETE FROM users USING archived_users WHERE users.id = archived_users.id",
    };
    for (unsupported) |source| {
        try std.testing.expectError(
            error.UnsupportedSqliteFeature,
            parser.parseSqlite(std.testing.allocator, source),
        );
    }

    var distinct = try parser.parseSqlite(
        std.testing.allocator,
        "SELECT DISTINCT name FROM users",
    );
    defer distinct.deinit();

    var quoted = try parser.parseSqlite(
        std.testing.allocator,
        "SELECT \"ilike\", 'value::text' FROM users",
    );
    defer quoted.deinit();
}

const lexer = parser.lexer;

/// Renders the token stream as `kind:text` pairs, one per line.
fn tokenDump(source: []const u8, dialect: lexer.Dialect) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer output.deinit();
    var tokens: lexer.Lexer = .init(source, dialect);
    while (tokens.next()) |token| try output.writer.print("{t}:{s}\n", .{ token.kind, token.text(source) });
    return output.toOwnedSlice();
}

fn expectTokens(source: []const u8, dialect: lexer.Dialect, expected: []const u8) !void {
    const dump = try tokenDump(source, dialect);
    defer std.testing.allocator.free(dump);
    try std.testing.expectEqualStrings(expected, dump);
}

test "the lexer recognizes every PostgreSQL quote and comment form" {
    try expectTokens("SELECT 'it''s :a', E'it\\'s :b', $$ :c $$, $fn$ :d $x$ $fn$, \"col :e\", U&'x' " ++
        "-- :f\n/* :g /* :h */ :i */ arr[:j], :k::int, x$y, $1", .postgres,
        \\identifier:SELECT
        \\string:'it''s :a'
        \\punctuation:,
        \\string:E'it\'s :b'
        \\punctuation:,
        \\string:$$ :c $$
        \\punctuation:,
        \\string:$fn$ :d $x$ $fn$
        \\punctuation:,
        \\quoted_identifier:"col :e"
        \\punctuation:,
        \\identifier:U
        \\operator:&
        \\string:'x'
        \\line_comment:-- :f
        \\block_comment:/* :g /* :h */ :i */
        \\identifier:arr
        \\punctuation:[
        \\parameter::j
        \\punctuation:]
        \\punctuation:,
        \\parameter::k
        \\operator:::
        \\identifier:int
        \\punctuation:,
        \\identifier:x$y
        \\punctuation:,
        \\placeholder:$1
        \\
    );
}

test "the lexer recognizes every SQLite quote and comment form" {
    try expectTokens("SELECT [col :a], `col :b`, \"col :c\", 'x''y :d', X'00', ?, ?2, $v, @w /* :e /* */ :f -- :g", .sqlite,
        \\identifier:SELECT
        \\quoted_identifier:[col :a]
        \\punctuation:,
        \\quoted_identifier:`col :b`
        \\punctuation:,
        \\quoted_identifier:"col :c"
        \\punctuation:,
        \\string:'x''y :d'
        \\punctuation:,
        \\identifier:X
        \\string:'00'
        \\punctuation:,
        \\placeholder:?
        \\punctuation:,
        \\placeholder:?2
        \\punctuation:,
        \\placeholder:$v
        \\punctuation:,
        \\placeholder:@w
        \\block_comment:/* :e /* */
        \\parameter::f
        \\line_comment:-- :g
        \\
    );
}

test "the lexer runs unterminated forms to the end instead of failing" {
    try expectTokens("SELECT 'open :a", .postgres, "identifier:SELECT\nstring:'open :a\n");
    try expectTokens("SELECT $$ :a", .postgres, "identifier:SELECT\nstring:$$ :a\n");
    try expectTokens("SELECT /* /* */ :a", .postgres, "identifier:SELECT\nblock_comment:/* /* */ :a\n");
    try expectTokens("SELECT E'\\", .postgres, "identifier:SELECT\nstring:E'\\\n");
    try expectTokens("[x", .sqlite, "quoted_identifier:[x\n");
    try expectTokens("\xEF\xBB\xBF:a", .postgres, "parameter::a\n");
}

test "numbers, operators, and multibyte identifiers lex as single tokens" {
    try expectTokens("SELECT 1_000.5e-3, .5, 0x1F, a<>b, x->>'k', naïve, ab--c\n", .postgres,
        \\identifier:SELECT
        \\number:1_000.5e-3
        \\punctuation:,
        \\number:.5
        \\punctuation:,
        \\number:0x1F
        \\punctuation:,
        \\identifier:a
        \\operator:<>
        \\identifier:b
        \\punctuation:,
        \\identifier:x
        \\operator:->>
        \\string:'k'
        \\punctuation:,
        \\identifier:naïve
        \\punctuation:,
        \\identifier:ab
        \\line_comment:--c
        \\
    );
}

test "parameters inside dollar quotes, escape strings, and nested comments are not rewritten" {
    const source = "SELECT $q$ :a $q$, E'\\' :b', /* /* */ :c */ :d, ARRAY[:e]";
    var rewritten = try parser.rewritePostgres(std.testing.allocator, source);
    defer rewritten.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "SELECT $q$ :a $q$, E'\\' :b', /* /* */ :c */ $1, ARRAY[$2]",
        rewritten.sql,
    );
    try std.testing.expectEqual(@as(usize, 2), rewritten.names.len);
    try std.testing.expectEqualStrings("d", rewritten.names[0]);
    try std.testing.expectEqualStrings("e", rewritten.names[1]);
    var parsed = try parser.parse(std.testing.allocator, source);
    defer parsed.deinit();
}

test "SQLite brackets quote identifiers, PostgreSQL brackets subscript" {
    var sqlite = try parser.rewriteSqlite(std.testing.allocator, "SELECT [:a], :b");
    defer sqlite.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("SELECT [:a], ?1", sqlite.sql);
    var postgres = try parser.rewritePostgres(std.testing.allocator, "SELECT tags[:a], :b");
    defer postgres.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("SELECT tags[$1], $2", postgres.sql);
}

test "rewritten positions map back to the original bytes" {
    const source = "\xEF\xBB\xBFSELECT 'é' AS x,\r\n\t:long_name, :b\r\n  WHERE :long_name";
    var rewritten = try parser.rewritePostgres(std.testing.allocator, source);
    defer rewritten.deinit(std.testing.allocator);
    // The byte order mark becomes spaces so later offsets do not move.
    try std.testing.expectEqualStrings("   SELECT 'é' AS x,\r\n\t$1, $2\r\n  WHERE $1", rewritten.sql);
    try std.testing.expectEqual(rewritten.sql.len + 1, rewritten.original_offsets.len);
    const first = std.mem.indexOf(u8, rewritten.sql, "$1").?;
    const second = std.mem.lastIndexOf(u8, rewritten.sql, "$1").?;
    try std.testing.expectEqual(std.mem.indexOf(u8, source, ":long_name").?, rewritten.original_offsets[first]);
    try std.testing.expectEqual(std.mem.lastIndexOf(u8, source, ":long_name").?, rewritten.original_offsets[second]);
    try std.testing.expectEqual(source.len, rewritten.original_offsets[rewritten.sql.len]);
    // Bytes after a marker map to their own original bytes.
    const comma = first + 2;
    try std.testing.expectEqual(@as(u8, ','), source[rewritten.original_offsets[comma]]);
}

test "syntax errors after multibyte text and CRLF report scalar columns" {
    const source = "SELECT 'é',\r\n  'ü' FROM";
    switch (try parser.parseDetailedSource(std.testing.allocator, "q.sql", source)) {
        .ok => |value| {
            var parsed = value;
            parsed.deinit();
            return error.ExpectedSyntaxError;
        },
        .syntax_error => |value| {
            var diagnostic = value;
            defer diagnostic.deinit();
            try std.testing.expectEqualStrings("S010", diagnostic.code);
            try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
            try std.testing.expectEqual(@as(usize, 11), diagnostic.column);
            try std.testing.expectEqual(source.len, diagnostic.original_offset);
        },
    }
}

test "a NUL byte fails the parse instead of truncating it" {
    switch (try parser.parseDetailedSource(std.testing.allocator, "q.sql", "SELECT 1\x00; DROP TABLE users")) {
        .ok => |value| {
            var parsed = value;
            parsed.deinit();
            return error.ExpectedSyntaxError;
        },
        .syntax_error => |value| {
            var diagnostic = value;
            defer diagnostic.deinit();
            try std.testing.expectEqual(@as(usize, 8), diagnostic.original_offset);
            try std.testing.expectEqual(@as(usize, 9), diagnostic.column);
        },
    }
}

test "SQLite rejects forms the two dialects lex differently" {
    const divergent = [_][]const u8{
        "SELECT $$ x $$",
        "SELECT $tag",
        "SELECT E'x'",
        "SELECT 1 /* outer /* inner */ */",
    };
    for (divergent) |source| try std.testing.expectError(
        error.UnsupportedSqliteFeature,
        parser.parseSqlite(std.testing.allocator, source),
    );
    // A column named `e` followed by a separate string is fine.
    var spaced = try parser.parseSqlite(std.testing.allocator, "SELECT e, 'x' FROM t");
    defer spaced.deinit();
}

fn tokenCount(source: []const u8, dialect: lexer.Dialect) u64 {
    var tokens: lexer.Lexer = .init(source, dialect);
    var count: u64 = 0;
    while (tokens.next()) |token| {
        if (token.kind != .line_comment and token.kind != .block_comment) count += 1;
    }
    return count;
}

test "tokens_per_source accepts its boundary and rejects one more token" {
    const source = "SELECT a, b -- comments are not tokens\nFROM t /* nor this */";
    try std.testing.expectEqual(@as(u64, 6), tokenCount(source, .postgres));
    try std.testing.expectEqual(@as(?lexer.Violation, null), lexer.checkLimits(source, .postgres, .{ .tokens = 6 }));
    const violation = lexer.checkLimits(source, .postgres, .{ .tokens = 5 }).?;
    try std.testing.expectEqual(.tokens, violation.limit);
    try std.testing.expectEqualStrings("t", source[violation.start..violation.end]);

    var parsed = try parser.parsePostgresWithDialect(std.testing.allocator, source, .{ .limits = .{ .tokens = 6 } });
    parsed.deinit();
    try std.testing.expectError(
        error.TokenLimitExceeded,
        parser.parsePostgresWithDialect(std.testing.allocator, source, .{ .limits = .{ .tokens = 5 } }),
    );
    try std.testing.expectError(
        error.TokenLimitExceeded,
        parser.parseSqliteWithDialect(std.testing.allocator, source, .{ .limits = .{ .tokens = 5 } }),
    );
}

test "nesting_depth accepts its boundary and rejects one more level" {
    const cases = [_]struct { []const u8, u32, []const u8 }{
        // Brackets, operators, and both together.
        .{ "SELECT ((((1))))", 4, "(" },
        .{ "SELECT 1+1+1+1", 3, "+" },
        .{ "SELECT f(1+(2*3))", 4, "*" },
        // A CASE is a level of its own.
        .{ "SELECT CASE WHEN a THEN CASE WHEN b THEN 1 END END", 2, "CASE" },
        // Set operations nest the statement.
        .{ "SELECT 1 UNION SELECT 2 UNION SELECT 3", 2, "UNION" },
        // NOT chains nest; flattened AND chains do not grow.
        .{ "SELECT NOT NOT NOT x", 3, "NOT" },
    };
    for (cases) |case| {
        const source, const depth, const crossing = case;
        try std.testing.expectEqual(@as(?lexer.Violation, null), lexer.checkLimits(source, .postgres, .{ .nesting = depth }));
        const violation = lexer.checkLimits(source, .postgres, .{ .nesting = depth - 1 }) orelse {
            std.debug.print("expected `{s}` to exceed nesting {d}\n", .{ source, depth - 1 });
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(.nesting, violation.limit);
        try std.testing.expectEqualStrings(crossing, source[violation.start..violation.end]);
    }
    // Lists and flattened boolean chains stay shallow however long they are.
    try std.testing.expectEqual(
        @as(?lexer.Violation, null),
        lexer.checkLimits("SELECT a = 1 AND b = 2 AND c = 3 AND d = 4, 1, 2, 3 FROM t WHERE x IN (1, 2, 3)", .postgres, .{ .nesting = 3 }),
    );
}

fn repeated(prefix: []const u8, unit: []const u8, count: usize, suffix: []const u8, tail: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(std.testing.allocator);
    try output.appendSlice(std.testing.allocator, prefix);
    for (0..count) |_| try output.appendSlice(std.testing.allocator, unit);
    try output.appendSlice(std.testing.allocator, suffix);
    for (0..count) |_| try output.appendSlice(std.testing.allocator, tail);
    return output.toOwnedSlice(std.testing.allocator);
}

test "deep nesting fails closed before it reaches libpg_query" {
    const shapes = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
        .{ "SELECT ", "(", "1", ")" },
        .{ "SELECT 1", "+1", "", "" },
        .{ "SELECT ", "- ", "1", "" },
        .{ "SELECT ", "NOT ", "true", "" },
        .{ "SELECT ", "CASE WHEN true THEN ", "1", " END" },
        .{ "SELECT 1", " UNION SELECT 1", "", "" },
        .{ "SELECT 1", "::int", "", "" },
    };
    for (shapes) |shape| {
        const prefix, const unit, const suffix, const tail = shape;
        const source = try repeated(prefix, unit, 100_000, suffix, tail);
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.NestingLimitExceeded, parser.parse(std.testing.allocator, source));
        try std.testing.expectError(error.NestingLimitExceeded, parser.parseSqlite(std.testing.allocator, source));
    }
}

test "the largest accepted nesting parses without exhausting the stack" {
    const limits: parser.Limits = .{ .nesting = lexer.max_nesting_depth };
    const shapes = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
        .{ "SELECT ", "(", "1", ")" },
        .{ "SELECT 1", "+1", "", "" },
        .{ "SELECT ", "NOT ", "true", "" },
    };
    for (shapes) |shape| {
        const prefix, const unit, const suffix, const tail = shape;
        const source = try repeated(prefix, unit, lexer.max_nesting_depth - 1, suffix, tail);
        defer std.testing.allocator.free(source);
        var parsed = try parser.parsePostgresWithDialect(std.testing.allocator, source, .{ .limits = limits });
        parsed.deinit();
    }
}

test "a limit crossing becomes an S021 diagnostic at the crossing token" {
    const source = "SELECT\n  (((1)))";
    switch (try parser.parseDetailedWithLimits(std.testing.allocator, "q.sql", source, .{ .nesting = 2 })) {
        .ok => |value| {
            var parsed = value;
            parsed.deinit();
            return error.ExpectedLimitError;
        },
        .syntax_error => |value| {
            var diagnostic = value;
            defer diagnostic.deinit();
            try std.testing.expectEqualStrings("S021", diagnostic.code);
            try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
            try std.testing.expectEqual(@as(usize, 5), diagnostic.column);
            try std.testing.expectEqualStrings("S021", diagnostic.structured().code);
        },
    }
}

/// Properties every input must satisfy: the lexer partitions the source into
/// ordered tokens and whitespace, the rewrite changes only parameters and maps
/// every output byte back to the byte it came from, limits are exact, and
/// parsing never crashes.
fn checkSqlProperties(source: []const u8) !void {
    const allocator = std.testing.allocator;
    for ([_]lexer.Dialect{ .sqlite, .postgres }) |dialect| {
        var tokens: lexer.Lexer = .init(source, dialect);
        // A leading byte order mark is skipped like whitespace.
        var previous_end: usize = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) 3 else 0;
        var count: u64 = 0;
        var parameters: usize = 0;
        while (tokens.next()) |token| {
            try std.testing.expect(token.start >= previous_end and token.end > token.start and token.end <= source.len);
            for (source[previous_end..token.start]) |byte| try std.testing.expect(std.ascii.isWhitespace(byte));
            previous_end = token.end;
            if (token.kind == .parameter) parameters += 1;
            if (token.kind != .line_comment and token.kind != .block_comment) count += 1;
        }
        for (source[previous_end..]) |byte| try std.testing.expect(std.ascii.isWhitespace(byte));

        // SQLite text is also held to the limits as PostgreSQL lexes it.
        const limit_count = switch (dialect) {
            .postgres => count,
            .sqlite => @max(count, tokenCount(source, .postgres)),
        };
        if (limit_count > 0) {
            // Exactly that many tokens fit; any failure at that limit is nesting.
            if (lexer.checkLimits(source, dialect, .{ .tokens = limit_count, .nesting = lexer.max_nesting_depth })) |violation|
                try std.testing.expectEqual(.nesting, violation.limit);
            if (limit_count > 1) {
                const violation = lexer.checkLimits(source, dialect, .{ .tokens = limit_count - 1, .nesting = lexer.max_nesting_depth });
                try std.testing.expect(violation != null);
            }
        }

        var rewritten = switch (dialect) {
            .sqlite => try parser.rewriteSqlite(allocator, source),
            .postgres => try parser.rewritePostgres(allocator, source),
        };
        defer rewritten.deinit(allocator);
        const offsets = rewritten.original_offsets;
        try std.testing.expectEqual(rewritten.sql.len + 1, offsets.len);
        try std.testing.expectEqual(source.len, offsets[offsets.len - 1]);
        var markers: usize = 0;
        for (rewritten.sql, 0..) |byte, index| {
            const original = offsets[index];
            try std.testing.expect(original < source.len);
            if (index > 0) try std.testing.expect(offsets[index - 1] <= original);
            if (byte == source[original]) continue;
            if (original < 3 and byte == ' ') continue;
            // A marker byte maps to the colon of the parameter it replaced.
            try std.testing.expectEqual(@as(u8, ':'), source[original]);
            if (index == 0 or offsets[index - 1] != original) markers += 1;
        }
        // Every parameter is a marker, though a marker may also equal a byte.
        try std.testing.expect(markers <= parameters);
        for (rewritten.names, 0..) |name, index| {
            for (rewritten.names[0..index]) |other| try std.testing.expect(!std.mem.eql(u8, name, other));
        }
    }

    const limits: parser.Limits = .{ .tokens = 4096, .nesting = 64 };
    if (parser.parsePostgresWithDialect(allocator, source, .{ .limits = limits })) |value| {
        var parsed = value;
        parsed.deinit();
    } else |_| {}
    if (parser.parseSqliteWithDialect(allocator, source, .{ .limits = limits })) |value| {
        var parsed = value;
        parsed.deinit();
    } else |_| {}
    if (source.len > 0) switch (try parser.parseDetailedWithLimits(allocator, "q.sql", source, limits)) {
        .ok => |value| {
            var parsed = value;
            parsed.deinit();
        },
        .syntax_error => |value| {
            var diagnostic = value;
            try std.testing.expect(diagnostic.original_offset <= source.len);
            diagnostic.deinit();
        },
    };
}

const sql_corpus = [_][]const u8{
    "SELECT :a, ':b', \":c\", $$ :d $$, E'\\' :e', /* /* */ :f */ -- :g\n:h",
    "SELECT [x], `y`, ?1, $v, @w FROM t WHERE a::int = :id",
    "\xEF\xBB\xBFSELECT 'é'\r\n\t:p",
    "SELECT $q$ unterminated",
    "SELECT /* unterminated",
    "SELECT ((((((((",
    "))))]]]] END END",
    ":::a :: : :1 $ $$",
    "SELECT 1\x00 :a",
    "\xFF\xFE :a \xC3",
    "",
};

test "SQL properties hold for the seed corpus" {
    for (sql_corpus) |source| try checkSqlProperties(source);
}

test "SQL properties hold for generated SQL" {
    // Fragments chosen so random concatenation exercises every lexer state
    // boundary: quotes and comments that open or close mid-token.
    const fragments = [_][]const u8{
        "SELECT ",      ":a",   ":b1",  "::",    ":",       "'", "''", "\"", "$$", "$t$", "$1", "E'", "\\", "/*",
        "*/",           "--",   "\n",   "\r\n",  "\t",      "[", "]",  "`",  "(",  ")",   "+",  "-",  ",",  ";",
        "CASE ",        " END", "NOT ", " AND ", " UNION ",
        "é",
        "\xEF\xBB\xBF", "x",    "1_0",  ".5e3",  "?",       "@",
    };
    var prng: std.Random.DefaultPrng = .init(0x5eed_5917);
    const random = prng.random();
    var buffer: [256]u8 = undefined;
    for (0..2_000) |_| {
        var length: usize = 0;
        const pieces = random.uintLessThan(usize, 24);
        for (0..pieces) |_| {
            const fragment = fragments[random.uintLessThan(usize, fragments.len)];
            if (length + fragment.len > buffer.len) break;
            @memcpy(buffer[length..][0..fragment.len], fragment);
            length += fragment.len;
        }
        try checkSqlProperties(buffer[0..length]);
    }
}

test "SQL properties hold for arbitrary bytes" {
    var prng: std.Random.DefaultPrng = .init(0xb17e5);
    const random = prng.random();
    var buffer: [128]u8 = undefined;
    for (0..2_000) |_| {
        const length = random.uintLessThan(usize, buffer.len);
        random.bytes(buffer[0..length]);
        try checkSqlProperties(buffer[0..length]);
    }
}

fn fuzzSql(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [1024]u8 = undefined;
    const length = smith.slice(&buffer);
    try checkSqlProperties(buffer[0..length]);
}

test "fuzz SQL bytes through the lexer, rewrite, and parser" {
    try std.testing.fuzz({}, fuzzSql, .{ .corpus = &sql_corpus });
}

test "SQLite quoting the PostgreSQL lexer ignores cannot hide nesting" {
    for ([_][]const u8{ "SELECT ` 1", "SELECT [ 1" }) |prefix| {
        const source = try repeated(prefix, "+1", 300_000, "", "");
        defer std.testing.allocator.free(source);
        try std.testing.expect(lexer.checkLimits(source, .sqlite, .{}) != null);
        try std.testing.expectError(error.NestingLimitExceeded, parser.parseSqlite(std.testing.allocator, source));
    }
}
