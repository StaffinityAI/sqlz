//! Project-level boundary fixtures: every configured limit is exercised at its
//! boundary and one past it, and every symlink shape that could escape the
//! project or silently drop sources fails closed.
const std = @import("std");
const codegen = @import("sqlz_codegen");
const diagnostics = @import("sqlz_diagnostics");
const sqlz_inputs = @import("sqlz_inputs");

const io = std.testing.io;
const allocator = std.testing.allocator;

/// A minimal SQLite project. Every file the checker reads is written through
/// `write`, so `bytes` is exactly what the registered-source limit sees,
/// apart from `sqlz.ziggy` itself.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    bytes: usize = 0,

    fn init() Fixture {
        return .{ .tmp = std.testing.tmpDir(.{ .iterate = true }) };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| try self.tmp.dir.createDirPath(io, parent);
        try self.tmp.dir.writeFile(io, .{ .sub_path = path, .data = data });
        self.bytes += data.len;
    }

    /// Writes `count` chained revisions, each creating one table.
    fn writeRevisions(self: *Fixture, count: usize) !void {
        for (0..count) |index| {
            var directory_buffer: [64]u8 = undefined;
            const directory = try std.fmt.bufPrint(&directory_buffer, "migrations/{x:0>12}_t{d}", .{ index + 1, index });
            var parents_buffer: [32]u8 = undefined;
            const parents = if (index == 0)
                "[]"
            else
                try std.fmt.bufPrint(&parents_buffer, "[\"{x:0>12}\"]", .{index});
            var manifest_buffer: [512]u8 = undefined;
            const manifest = try std.fmt.bufPrint(&manifest_buffer,
                \\.format_version = 1,
                \\.revision = "{x:0>12}",
                \\.parents = {s},
                \\.description = "create t{d}",
                \\.created_utc = "2026-09-18T12:00:00Z",
                \\.backends = [.sqlite],
                \\.reversible = true,
                \\.transaction = .{{ .sqlite = .always }},
            , .{ index + 1, parents, index });
            var path_buffer: [128]u8 = undefined;
            try self.write(try std.fmt.bufPrint(&path_buffer, "{s}/revision.ziggy", .{directory}), manifest);
            var sql_buffer: [128]u8 = undefined;
            try self.write(
                try std.fmt.bufPrint(&path_buffer, "{s}/common.up.sql", .{directory}),
                try std.fmt.bufPrint(&sql_buffer, "CREATE TABLE t{d} (id INTEGER PRIMARY KEY)", .{index}),
            );
            try self.write(
                try std.fmt.bufPrint(&path_buffer, "{s}/common.down.sql", .{directory}),
                try std.fmt.bufPrint(&sql_buffer, "DROP TABLE t{d}", .{index}),
            );
        }
    }

    fn writeQuery(self: *Fixture, path: []const u8, name: []const u8) !void {
        var buffer: [256]u8 = undefined;
        try self.write(path, try std.fmt.bufPrint(&buffer,
            \\-- sqlz.name: {s}
            \\-- sqlz.backends: sqlite
            \\-- sqlz.cardinality: many
            \\
            \\SELECT id FROM t0
        , .{name}));
    }

    fn writeConfig(self: *Fixture, zig_roots: []const u8, limits: []const u8) !usize {
        var buffer: [1024]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer,
            \\.format_version = 1,
            \\.project_id = "550e8400-e29b-41d4-a716-446655440000",
            \\.migrations = "migrations",
            \\.sql_roots = .{{ .app = "queries" }},
            \\.zig_roots = {s},
            \\.backends = .{{ .sqlite = .{{ .profile = "3.53" }} }},
            \\.limits = .{{ {s}{s} }},
            \\
        , .{ zig_roots, limits, if (limits.len == 0) ".diagnostics = 100" else "" });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "sqlz.ziggy", .data = source });
        return source.len;
    }

    fn writeStandard(self: *Fixture) !void {
        try self.writeRevisions(1);
        try self.writeQuery("queries/a.sql", "a");
    }

    fn generate(self: *Fixture) ![]u8 {
        return codegen.generateProject(allocator, io, self.tmp.dir, "sqlz.ziggy");
    }

    /// Runs the project check expecting exactly one boundary diagnostic.
    fn expectDiagnostic(self: *Fixture, code: []const u8, path: []const u8) !void {
        var list: diagnostics.List = .init(allocator, 100);
        defer list.deinit();
        try std.testing.expectError(error.ProjectCheckFailed, codegen.generateProjectWithCodecsAndDiagnostics(
            allocator,
            io,
            self.tmp.dir,
            "sqlz.ziggy",
            &.{},
            &list,
        ));
        try std.testing.expectEqual(@as(usize, 1), list.slice().len);
        try std.testing.expectEqualStrings(code, list.slice()[0].code);
        try std.testing.expectEqualStrings(path, list.slice()[0].primary.?.path);
    }

    /// Like `expectDiagnostic`, and also checks where in the file it points.
    fn expectDiagnosticAt(self: *Fixture, code: []const u8, path: []const u8, line: usize, column: usize) !void {
        var list: diagnostics.List = .init(allocator, 100);
        defer list.deinit();
        try std.testing.expectError(error.ProjectCheckFailed, codegen.generateProjectWithCodecsAndDiagnostics(
            allocator,
            io,
            self.tmp.dir,
            "sqlz.ziggy",
            &.{},
            &list,
        ));
        try std.testing.expectEqual(@as(usize, 1), list.slice().len);
        const diagnostic = list.slice()[0];
        try std.testing.expectEqualStrings(code, diagnostic.code);
        try std.testing.expectEqualStrings(path, diagnostic.primary.?.path);
        try std.testing.expectEqual(line, diagnostic.primary.?.start.line);
        try std.testing.expectEqual(column, diagnostic.primary.?.start.column);
        try std.testing.expect(diagnostic.primary.?.excerpt != null);
    }

    fn expectGenerates(self: *Fixture) !void {
        const generated = try self.generate();
        allocator.free(generated);
    }
};

fn limitsField(buffer: []u8, name: []const u8, value: usize) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".{s} = {d}", .{ name, value });
}

test "a source of exactly limits.source_bytes is accepted, one more byte is not" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeRevisions(1);
    const limit = 4096;
    const header =
        \\-- sqlz.name: big
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: many
        \\
        \\SELECT id FROM t0
        \\
    ;
    var padded: [limit]u8 = undefined;
    @memcpy(padded[0..header.len], header);
    @memset(padded[header.len .. limit - 1], ' ');
    padded[limit - 1] = '\n';
    try fixture.write("queries/big.sql", &padded);

    var buffer: [64]u8 = undefined;
    _ = try fixture.writeConfig("[]", try limitsField(&buffer, "source_bytes", limit));
    try fixture.expectGenerates();
    _ = try fixture.writeConfig("[]", try limitsField(&buffer, "source_bytes", limit - 1));
    try fixture.expectDiagnostic("S021", "queries/big.sql");
}

test "limits.source_bytes applies to sqlz.ziggy itself" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeStandard();
    // The file's length depends on the spelled limit, so search for the
    // self-consistent value.
    var buffer: [64]u8 = undefined;
    var config_len: usize = 1;
    while (true) {
        const written = try fixture.writeConfig("[]", try limitsField(&buffer, "source_bytes", config_len));
        if (written == config_len) break;
        config_len = written;
    }
    try fixture.expectGenerates();
    _ = try fixture.writeConfig("[]", try limitsField(&buffer, "source_bytes", config_len - 1));
    try fixture.expectDiagnostic("S021", "sqlz.ziggy");
}

test "sqlz.ziggy is read under a fixed bound before its limits are known" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    const oversized = try allocator.alloc(u8, 1024 * 1024 + 1);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "sqlz.ziggy", .data = oversized });
    try std.testing.expectError(error.ConfigurationTooLarge, fixture.generate());
    try std.testing.expectEqualStrings("S021", diagnostics.codeForError(error.ConfigurationTooLarge));
}

test "total bytes of exactly limits.registered_source_bytes are accepted, one more are not" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeStandard();
    // The configuration counts toward the total, and its length depends on
    // the spelled limit, so search for the self-consistent value.
    var buffer: [64]u8 = undefined;
    var total: usize = fixture.bytes;
    while (true) {
        const config_len = try fixture.writeConfig("[]", try limitsField(&buffer, "registered_source_bytes", total));
        if (fixture.bytes + config_len == total) break;
        total = fixture.bytes + config_len;
    }
    try fixture.expectGenerates();
    _ = try fixture.writeConfig("[]", try limitsField(&buffer, "registered_source_bytes", total - 1));
    // SQL roots are read last, so their single query is what crosses the total.
    try fixture.expectDiagnostic("S021", "queries/a.sql");
}

test "exactly limits.revisions revisions are accepted, one more is not" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeRevisions(3);
    try fixture.writeQuery("queries/a.sql", "a");
    var buffer: [64]u8 = undefined;
    _ = try fixture.writeConfig("[]", try limitsField(&buffer, "revisions", 3));
    try fixture.expectGenerates();
    _ = try fixture.writeConfig("[]", try limitsField(&buffer, "revisions", 2));
    try fixture.expectDiagnostic("S021", "migrations");
}

test "named and embedded queries share limits.queries" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeRevisions(1);
    try fixture.writeQuery("queries/a.sql", "a");
    try fixture.writeQuery("queries/b.sql", "b");
    try fixture.write("src/embedded.zig",
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM t0",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = struct { id: i64 },
        \\});
    );
    var buffer: [64]u8 = undefined;
    _ = try fixture.writeConfig("[\"src\"]", try limitsField(&buffer, "queries", 3));
    try fixture.expectGenerates();
    _ = try fixture.writeConfig("[\"src\"]", try limitsField(&buffer, "queries", 2));
    try fixture.expectDiagnostic("S021", "queries/b.sql");
    _ = try fixture.writeConfig("[\"src\"]", try limitsField(&buffer, "queries", 1));
    try fixture.expectDiagnostic("S021", "queries/a.sql");
}

test "a symlinked query file inside the project is read" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeRevisions(1);
    try fixture.writeQuery("shared/a.sql", "a");
    try fixture.tmp.dir.createDirPath(io, "queries");
    try fixture.tmp.dir.symLink(io, "../shared/a.sql", "queries/a.sql", .{});
    _ = try fixture.writeConfig("[]", "");
    const generated = try fixture.generate();
    defer allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const a = sqlz.Query(") != null);
}

test "a symlinked query file outside the project fails closed" {
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(io, .{ .sub_path = "secret.sql", .data = "SELECT 1" });
    const target = try outside.dir.realPathFileAlloc(io, "secret.sql", allocator);
    defer allocator.free(target);

    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeStandard();
    try fixture.tmp.dir.symLink(io, target, "queries/escape.sql", .{});
    _ = try fixture.writeConfig("[]", "");
    try fixture.expectDiagnostic("S022", "queries/escape.sql");
    try std.testing.expectError(error.PathEscapesProject, fixture.generate());
}

test "a relative symlink climbing out of the project fails closed" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeStandard();
    // `queries/../..` is the temporary directory's parent, which exists but
    // lies outside the project.
    try fixture.tmp.dir.symLink(io, "../..", "queries/up", .{ .is_directory = true });
    _ = try fixture.writeConfig("[]", "");
    try fixture.expectDiagnostic("S022", "queries/up");
}

test "a symlinked directory inside a root is never followed" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeStandard();
    try fixture.writeQuery("shared/b.sql", "b");
    try fixture.tmp.dir.symLink(io, "../shared", "queries/linked", .{ .is_directory = true });
    _ = try fixture.writeConfig("[]", "");
    try fixture.expectDiagnostic("S022", "queries/linked");
    try std.testing.expectError(error.SymlinkedDirectory, fixture.generate());
}

test "a configured root that resolves outside the project fails closed" {
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    const target = try outside.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(target);

    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeRevisions(1);
    try fixture.tmp.dir.symLink(io, target, "queries", .{ .is_directory = true });
    _ = try fixture.writeConfig("[]", "");
    try fixture.expectDiagnostic("S022", "queries");
}

test "a configured root may be a symlink inside the project" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeRevisions(1);
    try fixture.writeQuery("real_queries/a.sql", "a");
    try fixture.tmp.dir.symLink(io, "real_queries", "queries", .{ .is_directory = true });
    _ = try fixture.writeConfig("[]", "");
    try fixture.expectGenerates();
}

test "a symlinked revision manifest outside the project fails closed" {
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(io, .{ .sub_path = "revision.ziggy", .data = "" });
    const target = try outside.dir.realPathFileAlloc(io, "revision.ziggy", allocator);
    defer allocator.free(target);

    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeQuery("queries/a.sql", "a");
    try fixture.tmp.dir.createDirPath(io, "migrations/000000000001_t0");
    try fixture.tmp.dir.symLink(io, target, "migrations/000000000001_t0/revision.ziggy", .{});
    _ = try fixture.writeConfig("[]", "");
    try fixture.expectDiagnostic("S022", "migrations/000000000001_t0/revision.ziggy");
}

test "a symlinked revision directory is never followed" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeStandard();
    try fixture.tmp.dir.symLink(io, "000000000001_t0", "migrations/000000000002_copy", .{ .is_directory = true });
    _ = try fixture.writeConfig("[]", "");
    try fixture.expectDiagnostic("S022", "migrations/000000000002_copy");
}

test "the generated module carries runtime settings from sqlz.ziggy" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeStandard();
    try fixture.tmp.dir.writeFile(io, .{
        .sub_path = "sqlz.ziggy",
        .data =
        \\.format_version = 1,
        \\.project_id = "550e8400-e29b-41d4-a716-446655440000",
        \\.migrations = "migrations",
        \\.sql_roots = .{ .app = "queries" },
        \\.zig_roots = [],
        \\.backends = .{ .sqlite = .{ .profile = "3.50" } },
        \\.migration_lock_timeout_ms = 1234,
        \\.allow_untested_version = true,
        ,
    });
    const generated = try fixture.generate();
    defer allocator.free(generated);
    const expected =
        \\pub const sqlz_project = struct {
        \\    pub const id = "550e8400-e29b-41d4-a716-446655440000";
        \\    pub const sqlite_profile: ?[]const u8 = "3.50";
        \\    pub const postgres_profile: ?u16 = null;
        \\    pub const allow_untested_version = true;
        \\    pub const migration_lock_timeout_ms: u32 = 1234;
        \\};
    ;
    try std.testing.expect(std.mem.indexOf(u8, generated, expected) != null);
}

test "inputs reports the first boundary path and keeps it" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var project_inputs = try sqlz_inputs.Inputs.init(allocator, io, tmp.dir, .{ .source_bytes = 4 });
    defer project_inputs.deinit();
    try project_inputs.register("small", 4);
    try std.testing.expectError(error.SourceTooLarge, project_inputs.register("first", 5));
    try std.testing.expectError(error.SourceTooLarge, project_inputs.register("second", 5));
    try std.testing.expectEqualStrings("first", project_inputs.failure_path.?);
}

test "symlinks that are never read may point anywhere" {
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "outside" });
    const target = try outside.dir.realPathFileAlloc(io, "notes.txt", allocator);
    defer allocator.free(target);

    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeStandard();
    try fixture.tmp.dir.symLink(io, target, "queries/notes.txt", .{});
    try fixture.tmp.dir.symLink(io, "missing.txt", "queries/dangling.txt", .{});
    try fixture.tmp.dir.symLink(io, target, "migrations/README", .{});
    _ = try fixture.writeConfig("[]", "");
    try fixture.expectGenerates();
}

test "a dangling symlinked query file fails instead of being skipped" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeStandard();
    try fixture.tmp.dir.symLink(io, "missing.sql", "queries/gone.sql", .{});
    _ = try fixture.writeConfig("[]", "");
    try std.testing.expectError(error.FileNotFound, fixture.generate());
}

test "boundary errors are checked-source failures" {
    for ([_]anyerror{
        error.ConfigurationTooLarge,
        error.SourceTooLarge,
        error.RegisteredSourceLimitExceeded,
        error.RevisionLimitExceeded,
        error.QueryLimitExceeded,
        error.PathEscapesProject,
        error.SymlinkedDirectory,
        error.NotRegularFile,
        error.TokenLimitExceeded,
        error.NestingLimitExceeded,
        error.InvalidUtf8,
    }) |err| try std.testing.expectEqual(@as(u8, 1), diagnostics.exitCode(err));
}

test "a source path that is not a regular file fails instead of blocking" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeQuery("queries/a.sql", "a");
    // A directory where `revision.ziggy` belongs is a non-regular input that
    // every platform can create; FIFOs take the same path.
    try fixture.tmp.dir.createDirPath(io, "migrations/000000000001_t0/revision.ziggy");
    _ = try fixture.writeConfig("[]", "");
    try fixture.expectDiagnostic("S022", "migrations/000000000001_t0/revision.ziggy");
}

test "malformed UTF-8 fails with its exact position" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeRevisions(1);
    try fixture.write("queries/a.sql", "-- sqlz.name: a\n-- sqlz.backends: sqlite\n" ++
        "-- sqlz.cardinality: many\n\nSELECT 'é' AS a, '\xFF' AS b FROM t0");
    _ = try fixture.writeConfig("[]", "");
    // Reported at the byte, counted in characters: `é` is one column.
    try fixture.expectDiagnosticAt("S011", "queries/a.sql", 5, 19);
}

test "malformed UTF-8 in a revision manifest or Zig root fails closed" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeStandard();
    try fixture.write("src/bad.zig", "const a = \"\xC3\";\n");
    _ = try fixture.writeConfig("[\"src\"]", "");
    try fixture.expectDiagnosticAt("S011", "src/bad.zig", 1, 12);
}

test "a source with a byte order mark and CRLF line endings checks cleanly" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeRevisions(1);
    try fixture.write("queries/a.sql", "\xEF\xBB\xBF-- sqlz.name: a\r\n-- sqlz.backends: sqlite\r\n-- sqlz.cardinality: many\r\n\r\nSELECT id\r\nFROM t0\r\n");
    _ = try fixture.writeConfig("[]", "");
    try fixture.expectGenerates();
}

/// A query of exactly 12 tokens nested 4 levels deep, deeper and longer than
/// the fixture's migrations.
fn writeLimitQuery(fixture: *Fixture) !void {
    try fixture.writeRevisions(1);
    try fixture.write("queries/big.sql",
        \\-- sqlz.name: big
        \\-- sqlz.backends: sqlite
        \\-- sqlz.cardinality: many
        \\
        \\SELECT ((((id)))) FROM t0
        \\WHERE id = 1
    );
}

test "a query of exactly limits.tokens_per_source tokens is accepted, one more is not" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try writeLimitQuery(&fixture);
    // SELECT ( ( ( ( id ) ) ) ) FROM t0 WHERE id = 1: 16 tokens.
    var buffer: [64]u8 = undefined;
    _ = try fixture.writeConfig("[]", try limitsField(&buffer, "tokens_per_source", 16));
    try fixture.expectGenerates();
    _ = try fixture.writeConfig("[]", try limitsField(&buffer, "tokens_per_source", 15));
    try fixture.expectDiagnosticAt("S021", "big.sql", 6, 12);
}

test "a query nested exactly limits.nesting_depth deep is accepted, one deeper is not" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try writeLimitQuery(&fixture);
    var buffer: [64]u8 = undefined;
    _ = try fixture.writeConfig("[]", try limitsField(&buffer, "nesting_depth", 4));
    try fixture.expectGenerates();
    _ = try fixture.writeConfig("[]", try limitsField(&buffer, "nesting_depth", 3));
    try fixture.expectDiagnosticAt("S021", "big.sql", 5, 11);
}

test "migration SQL is held to the token and nesting limits" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeRevisions(1);
    try fixture.writeQuery("queries/a.sql", "a");
    // CREATE TABLE t0 ( id INTEGER PRIMARY KEY ): 9 tokens, one level.
    var buffer: [64]u8 = undefined;
    _ = try fixture.writeConfig("[]", try limitsField(&buffer, "tokens_per_source", 9));
    try fixture.expectGenerates();
    _ = try fixture.writeConfig("[]", try limitsField(&buffer, "tokens_per_source", 8));
    try fixture.expectDiagnosticAt("S021", "000000000001_t0/common.up.sql", 1, 40);
}

test "a Zig root is held to the token and nesting limits" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.writeRevisions(1);
    try fixture.write("src/embedded.zig",
        \\const sqlz = @import("sqlz");
        \\pub const find = sqlz.Query(.{
        \\    .sql = "SELECT id FROM t0",
        \\    .backends = .{ .sqlite = true },
        \\    .cardinality = .many,
        \\    .row = struct { id: i64 },
        \\});
    );
    try fixture.write("queries/.keep.sql", "");
    var buffer: [64]u8 = undefined;
    // Three levels: `sqlz.Query(`, its `.{`, and the `.{` or `struct {`
    // inside it.
    _ = try fixture.writeConfig("[\"src\"]", try limitsField(&buffer, "nesting_depth", 3));
    try fixture.expectGenerates();
    _ = try fixture.writeConfig("[\"src\"]", try limitsField(&buffer, "nesting_depth", 2));
    try fixture.expectDiagnosticAt("S021", "src/embedded.zig", 4, 18);
}
