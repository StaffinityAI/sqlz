const std = @import("std");
const inputs = @import("sqlz_inputs");
const zig_queries = @import("sqlz_zig_queries");

test "discovers direct embedded query declarations in containers" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\const namespace = struct {
        \\    pub const find = sqlz.Query(.{
        \\        .sql =
        \\            \\SELECT id
        \\            \\FROM users WHERE id=:id
        \\        ,
        \\        .backends = .{ .sqlite = true },
        \\        .cardinality = .optional,
        \\        .params = struct { id: i64 },
        \\        .row = struct { id: i64 },
        \\    });
        \\};
    ;
    var discovery = try zig_queries.parse(std.testing.allocator, "src/users.zig", source);
    defer discovery.deinit();
    try std.testing.expectEqual(@as(usize, 1), discovery.sources.len);
    try std.testing.expectEqualStrings("find", discovery.sources[0].name);
    try std.testing.expectEqualStrings("SELECT id\nFROM users WHERE id=:id", discovery.sources[0].sql);
    try std.testing.expect(discovery.sources[0].backends.sqlite);
    try std.testing.expect(discovery.sources[0].sql_source_offsets != null);
    const sql_offset = std.mem.indexOf(u8, discovery.sources[0].sql, "users").?;
    const file_offset = discovery.sources[0].sql_source_offsets.?[sql_offset];
    try std.testing.expectEqualStrings("users", source[file_offset .. file_offset + 5]);
}

test "rejects computed SQL in embedded declarations" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\const statement = "SELECT 1 AS value";
        \\const query = sqlz.Query(.{
        \\    .sql = statement,
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .one,
        \\    .row = struct { value: i64 },
        \\});
    ;
    try std.testing.expectError(
        error.InvalidSqlExpression,
        zig_queries.parse(std.testing.allocator, "src/query.zig", source),
    );
}

test "discovers Zig roots in deterministic path order" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var nested = try tmp.dir.createDirPathOpen(std.testing.io, "nested", .{});
    defer nested.close(std.testing.io);
    const prefix = "const sqlz = @import(\"sqlz\");\nconst ";
    try nested.writeFile(std.testing.io, .{
        .sub_path = "z.zig",
        .data = prefix ++ "zed = sqlz.Query(.{ .sql = \"DELETE FROM users\", .backends = .{ .sqlite = true }, .cardinality = .exec });",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "a.zig",
        .data = prefix ++ "alpha = sqlz.Query(.{ .sql = \"SELECT id FROM users\", .backends = .{ .sqlite = true }, .cardinality = .many, .row = struct { id: i64 } });",
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ignored.txt", .data = "not Zig" });

    var project_inputs = try inputs.Inputs.init(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer project_inputs.deinit();
    var discovery = try zig_queries.discover(
        std.testing.allocator,
        &project_inputs,
        tmp.dir,
    );
    defer discovery.deinit();
    try std.testing.expectEqual(@as(usize, 2), discovery.sources.len);
    try std.testing.expectEqualStrings("alpha", discovery.sources[0].name);
    try std.testing.expectEqualStrings("zed", discovery.sources[1].name);
}

test "captures the declared parameter and row structs" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id, label FROM users WHERE id=:id",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .optional,
        \\    .params = struct { id: i64 },
        \\    .row = struct { id: i64, label: ?[]const u8 },
        \\});
    ;
    var discovery = try zig_queries.parse(std.testing.allocator, "src/users.zig", source);
    defer discovery.deinit();
    const declared = discovery.sources[0].declared;
    try std.testing.expect(declared.embedded);

    const params = declared.params.?;
    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expectEqualStrings("id", params[0].name);
    try std.testing.expectEqualStrings("i64", params[0].type_text);
    try std.testing.expect(!params[0].optional);

    const row = declared.row.?;
    try std.testing.expectEqual(@as(usize, 2), row.len);
    try std.testing.expectEqualStrings("label", row[1].name);
    // The `?` is recorded separately and the spelling is whitespace-normalized.
    try std.testing.expectEqualStrings("[]const u8", row[1].type_text);
    try std.testing.expect(row[1].optional);
}

test "an omitted parameter struct declares no parameters" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\pub const list = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = struct { id: i64 },
        \\});
    ;
    var discovery = try zig_queries.parse(std.testing.allocator, "src/users.zig", source);
    defer discovery.deinit();
    const declared = discovery.sources[0].declared;
    try std.testing.expect(!declared.params_present);
    try std.testing.expectEqual(@as(usize, 0), declared.params.?.len);
    try std.testing.expect(declared.row_present);
}

test "reads codec maps and resolves a row struct named in the same file" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\const Account = struct { id: i64, tier: Tier };
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id, tier FROM accounts WHERE tier=:tier",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .param_codecs = .{ .tier = "tier" },
        \\    .column_codecs = .{ .tier = "tier" },
        \\    .params = struct { tier: Tier },
        \\    .row = Account,
        \\});
    ;
    var discovery = try zig_queries.parse(std.testing.allocator, "src/accounts.zig", source);
    defer discovery.deinit();
    const source_one = discovery.sources[0];
    try std.testing.expectEqualStrings("tier", source_one.param_codecs[0].name);
    try std.testing.expectEqualStrings("tier", source_one.param_codecs[0].codec);
    try std.testing.expectEqualStrings("tier", source_one.column_codecs[0].name);

    const row = source_one.declared.row.?;
    try std.testing.expectEqual(@as(usize, 2), row.len);
    try std.testing.expectEqualStrings("Tier", row[1].type_text);
}

test "a declared type the parser cannot read stays unread" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\const types = @import("types");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = types.User,
        \\});
    ;
    var discovery = try zig_queries.parse(std.testing.allocator, "src/users.zig", source);
    defer discovery.deinit();
    const declared = discovery.sources[0].declared;
    try std.testing.expect(declared.row_present);
    try std.testing.expect(declared.row == null);
}

test "rejects a tuple row struct" {
    const source: [:0]const u8 =
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM users",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = struct { i64 },
        \\});
    ;
    try std.testing.expectError(
        error.InvalidDeclaredType,
        zig_queries.parse(std.testing.allocator, "src/users.zig", source),
    );
}

test "an embedded query name repeats freely across files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const source = "const sqlz = @import(\"sqlz\");\n" ++
        "pub const find = sqlz.Query(.{ .sql = \"DELETE FROM users\", .backends = .{ .sqlite = true }, .cardinality = .exec });";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = source });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.zig", .data = source });

    var project_inputs = try inputs.Inputs.init(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer project_inputs.deinit();
    var discovery = try zig_queries.discover(
        std.testing.allocator,
        &project_inputs,
        tmp.dir,
    );
    defer discovery.deinit();
    try std.testing.expectEqual(@as(usize, 2), discovery.sources.len);
}

test "a byte order mark keeps embedded SQL offsets in the file" {
    const source: [:0]const u8 = "\xEF\xBB\xBFconst sqlz = @import(\"sqlz\");\r\n" ++
        "pub const find = sqlz.Query(.{ .sql = \"SELECT 'é', id FROM users\", .backends = .{ .sqlite = true }, .cardinality = .many });\r\n";
    var discovery = try zig_queries.parse(std.testing.allocator, "src/users.zig", source);
    defer discovery.deinit();
    const found = discovery.sources[0];
    const sql_offset = std.mem.indexOf(u8, found.sql, "users").?;
    const file_offset = found.sql_source_offsets.?[sql_offset];
    try std.testing.expectEqualStrings("users", source[file_offset .. file_offset + 5]);
    try std.testing.expectEqualStrings(source, found.source_text.?);
}

test "tokens_per_source bounds a Zig source at its boundary" {
    const source: [:0]const u8 = "const a = 1;";
    // `const`, `a`, `=`, `1`, `;`
    try std.testing.expectEqual(@as(?zig_queries.Violation, null), zig_queries.checkLimits(source, .{ .tokens = 5 }));
    const violation = zig_queries.checkLimits(source, .{ .tokens = 4 }).?;
    try std.testing.expectEqual(error.TokenLimitExceeded, violation.err);
    try std.testing.expectEqualStrings(";", source[violation.start..violation.end]);
    try std.testing.expectError(error.TokenLimitExceeded, zig_queries.parseWithLimits(std.testing.allocator, "a.zig", source, .{ .tokens = 4 }));
}

test "nesting_depth bounds a Zig source at its boundary" {
    const cases = [_]struct { [:0]const u8, u32, []const u8 }{
        .{ "const a = ((1));", 2, "(" },
        .{ "const a = !!!b;", 3, "!" },
        .{ "const a = if (x) 1 else if (y) 2 else if (z) 3 else 4;", 3, "(" },
        .{ "fn f() void { { {} } }", 3, "{" },
    };
    for (cases) |case| {
        const source, const depth, const crossing = case;
        try std.testing.expectEqual(@as(?zig_queries.Violation, null), zig_queries.checkLimits(source, .{ .nesting = depth }));
        const violation = zig_queries.checkLimits(source, .{ .nesting = depth - 1 }) orelse {
            std.debug.print("expected `{s}` to exceed nesting {d}\n", .{ source, depth - 1 });
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(error.NestingLimitExceeded, violation.err);
        try std.testing.expectEqualStrings(crossing, source[violation.start..violation.end]);
    }
    // Separate statements, and an `if` nested inside a branch, do not extend
    // an `else if` chain; the chain itself still counts.
    try std.testing.expectEqual(@as(?zig_queries.Violation, null), zig_queries.checkLimits(
        "fn f() void { if (a) {} else if (b) {} if (c) {} else if (d) {} }",
        .{ .nesting = 3 },
    ));
    try std.testing.expect(zig_queries.checkLimits(
        "fn f() void { if (a) { if (x) {} } else if (b) { if (y) {} } else if (c) {} }",
        .{ .nesting = 3 },
    ) != null);
}

test "deep Zig nesting fails closed before the Zig parser runs" {
    const allocator = std.testing.allocator;
    const units = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "(", "1", ")" },
        .{ "!", "a", "" },
        .{ "-", "a", "" },
        .{ "&", "a", "" },
        .{ "try ", "a", "" },
        .{ "if (a) 1 else ", "2", "" },
    };
    for (units) |unit| {
        const open, const middle, const close = unit;
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(allocator);
        try source.appendSlice(allocator, "const x = ");
        for (0..100_000) |_| try source.appendSlice(allocator, open);
        try source.appendSlice(allocator, middle);
        for (0..100_000) |_| try source.appendSlice(allocator, close);
        try source.appendSlice(allocator, ";");
        const terminated = try allocator.dupeZ(u8, source.items);
        defer allocator.free(terminated);
        try std.testing.expectError(error.NestingLimitExceeded, zig_queries.parse(allocator, "deep.zig", terminated));
    }
}

/// Discovery on any bytes either finds declarations or fails with an error;
/// it never panics, and a found declaration's offsets stay inside the file.
fn checkZigProperties(bytes: []const u8) !void {
    const allocator = std.testing.allocator;
    const source = try allocator.dupeZ(u8, bytes);
    defer allocator.free(source);
    var discovery = zig_queries.parseWithLimits(allocator, "fuzz.zig", source, .{ .nesting = 64, .tokens = 4096 }) catch return;
    defer discovery.deinit();
    for (discovery.sources) |found| {
        const offsets = found.sql_source_offsets.?;
        try std.testing.expectEqual(found.sql.len + 1, offsets.len);
        for (offsets) |offset| try std.testing.expect(offset <= source.len);
    }
}

const zig_corpus = [_][]const u8{
    "const sqlz = @import(\"sqlz\");\npub const q = sqlz.Query(.{ .sql = \"SELECT \\x41 :id\", .backends = .{ .sqlite = true }, .cardinality = .one, .params = struct { id: i64 }, .row = struct { a: ?i64 } });",
    "pub const q = sqlz.Query(.{ .sql = \\\\SELECT 1\n\\\\FROM t\n, .backends = .{ .postgres = true }, .cardinality = .many });",
    "pub const q = sqlz.Query(.{ .sql = \"unterminated",
    "pub const q = sqlz.Query(.{ .sql = 1, .backends = 2 });",
    "\xEF\xBB\xBFconst a = 1;",
    "((((((((((((",
};

test "Zig discovery properties hold for the seed corpus and arbitrary bytes" {
    for (zig_corpus) |source| try checkZigProperties(source);
    var prng: std.Random.DefaultPrng = .init(0x219);
    const random = prng.random();
    var buffer: [256]u8 = undefined;
    for (0..1_000) |_| {
        // Mutate a corpus entry so most inputs still look like declarations.
        const seed = zig_corpus[random.uintLessThan(usize, zig_corpus.len)];
        const length = @min(seed.len, buffer.len);
        @memcpy(buffer[0..length], seed[0..length]);
        for (0..random.uintLessThan(usize, 8)) |_| {
            if (length == 0) break;
            buffer[random.uintLessThan(usize, length)] = random.int(u8);
        }
        try checkZigProperties(buffer[0..length]);
    }
}

fn fuzzZig(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [1024]u8 = undefined;
    const length = smith.slice(&buffer);
    try checkZigProperties(buffer[0..length]);
}

test "fuzz Zig declarations" {
    try std.testing.fuzz({}, fuzzZig, .{ .corpus = &zig_corpus });
}
