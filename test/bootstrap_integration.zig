const std = @import("std");
const pg = @import("pg");
const zqlite = @import("zqlite");
const options = @import("bootstrap_test_options");

const allocator = std.testing.allocator;
const io = std.testing.io;
const postgres_url = "postgresql://sqlz_test:sqlz_test@127.0.0.1:55432/sqlz_test";
const schema = "sqlz_bootstrap_test";

test "public CLI bootstraps realistic SQLite data into PostgreSQL" {
    const uri = try std.Uri.parse(postgres_url);
    var postgres = try pg.Conn.openAndAuthUri(io, allocator, uri);
    defer postgres.deinit();
    try resetSchema(&postgres);
    defer resetSchema(&postgres) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sqlite_path = try tempDatabasePath(&tmp);
    defer allocator.free(sqlite_path);
    try createSourceDatabase(sqlite_path);

    var environment = try std.testing.io_instance.environ.process_environ.createMap(allocator);
    defer environment.deinit();
    try environment.put("DATABASE_URL", postgres_url);

    const run = try std.process.run(allocator, io, .{
        .argv = &.{
            options.zig_exe,
            "build",
            "sqlz",
            "--summary",
            "failures",
            "--",
            "bootstrap",
            "postgres",
            "--project",
            "bootstrap",
            "--from-sqlite",
            sqlite_path,
        },
        .cwd = .{ .path = options.fixture_path },
        .environ_map = &environment,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{
            .raw = .fromSeconds(120),
            .clock = .awake,
        } },
    });
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);
    try expectSuccess(run);

    try validateUsers(&postgres);
    try validateProfiles(&postgres);
    try validateSessions(&postgres);
    try validateSequences(&postgres);
}

fn tempDatabasePath(tmp: *std.testing.TmpDir) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &buffer);
    return std.fs.path.join(allocator, &.{ buffer[0..length], "source.db" });
}

fn createSourceDatabase(path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const source = try zqlite.open(
        path_z,
        zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode,
    );
    defer source.close();

    const script = try std.Io.Dir.cwd().readFileAlloc(
        io,
        options.source_sql_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(script);
    const script_z = try allocator.dupeZ(u8, script);
    defer allocator.free(script_z);
    try source.execNoArgs(script_z);
}

fn expectSuccess(run: std.process.RunResult) !void {
    switch (run.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("bootstrap stdout:\n{s}\nbootstrap stderr:\n{s}\n", .{ run.stdout, run.stderr });
    return error.BootstrapCommandFailed;
}

fn resetSchema(conn: *pg.Conn) !void {
    _ = try conn.exec("DROP SCHEMA IF EXISTS " ++ schema ++ " CASCADE", .{});
}

fn validateUsers(conn: *pg.Conn) !void {
    var result = try conn.query(
        "SELECT id, name, active, score, avatar FROM " ++ schema ++ ".users ORDER BY id",
        .{},
    );
    defer result.deinit();

    const ada = try result.next() orelse return error.MissingAda;
    try std.testing.expectEqual(@as(i64, 3), try ada.get(i64, 0));
    try std.testing.expectEqualStrings("Ada", try ada.get([]const u8, 1));
    try std.testing.expect(try ada.get(bool, 2));
    try std.testing.expectEqual(@as(?f64, 9.5), try ada.get(?f64, 3));
    const avatar = (try ada.get(?[]const u8, 4)) orelse return error.MissingAvatar;
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xff }, avatar);

    const lin = try result.next() orelse return error.MissingLin;
    try std.testing.expectEqual(@as(i64, 8), try lin.get(i64, 0));
    try std.testing.expectEqualStrings("Lin", try lin.get([]const u8, 1));
    try std.testing.expect(!(try lin.get(bool, 2)));
    try std.testing.expectEqual(@as(?f64, null), try lin.get(?f64, 3));
    try std.testing.expectEqual(@as(?[]const u8, null), try lin.get(?[]const u8, 4));
    try std.testing.expect((try result.next()) == null);
}

fn validateProfiles(conn: *pg.Conn) !void {
    var result = try conn.query(
        "SELECT u.id, p.label FROM " ++ schema ++
            ".users u LEFT JOIN " ++ schema ++ ".profiles p ON p.user_id = u.id ORDER BY u.id",
        .{},
    );
    defer result.deinit();

    const ada = try result.next() orelse return error.MissingAdaProfile;
    try std.testing.expectEqual(@as(i64, 3), try ada.get(i64, 0));
    const label = (try ada.get(?[]const u8, 1)) orelse return error.MissingProfileLabel;
    try std.testing.expectEqualStrings("compiler pioneer", label);

    const lin = try result.next() orelse return error.MissingLinProfile;
    try std.testing.expectEqual(@as(i64, 8), try lin.get(i64, 0));
    try std.testing.expectEqual(@as(?[]const u8, null), try lin.get(?[]const u8, 1));
    try std.testing.expect((try result.next()) == null);
}

fn validateSessions(conn: *pg.Conn) !void {
    var result = try conn.query(
        "SELECT s.id, s.user_id, u.name, s.token_hash, s.expires_at, s.revoked " ++
            "FROM " ++ schema ++ ".sessions s JOIN " ++ schema ++
            ".users u ON u.id = s.user_id ORDER BY s.id",
        .{},
    );
    defer result.deinit();

    const ada = try result.next() orelse return error.MissingAdaSession;
    try std.testing.expectEqual(@as(i64, 5), try ada.get(i64, 0));
    try std.testing.expectEqual(@as(i64, 3), try ada.get(i64, 1));
    try std.testing.expectEqualStrings("Ada", try ada.get([]const u8, 2));
    try std.testing.expectEqualStrings("ada-live", try ada.get([]const u8, 3));
    try std.testing.expectEqual(@as(i64, 200), try ada.get(i64, 4));
    try std.testing.expect(!(try ada.get(bool, 5)));

    const lin = try result.next() orelse return error.MissingLinSession;
    try std.testing.expectEqual(@as(i64, 12), try lin.get(i64, 0));
    try std.testing.expectEqual(@as(i64, 8), try lin.get(i64, 1));
    try std.testing.expectEqualStrings("Lin", try lin.get([]const u8, 2));
    try std.testing.expectEqualStrings("lin-revoked", try lin.get([]const u8, 3));
    try std.testing.expectEqual(@as(i64, 300), try lin.get(i64, 4));
    try std.testing.expect(try lin.get(bool, 5));
    try std.testing.expect((try result.next()) == null);
}

fn validateSequences(conn: *pg.Conn) !void {
    var user_result = try conn.query(
        "INSERT INTO " ++ schema ++ ".users(name, active) VALUES ('Next', true) RETURNING id",
        .{},
    );
    defer user_result.deinit();
    const user = try user_result.next() orelse return error.MissingGeneratedUser;
    try std.testing.expectEqual(@as(i64, 9), try user.get(i64, 0));
    try user_result.drain();

    var session_result = try conn.query(
        "INSERT INTO " ++ schema ++
            ".sessions(user_id, token_hash, expires_at, revoked) " ++
            "VALUES (3, 'next-session', 400, false) RETURNING id",
        .{},
    );
    defer session_result.deinit();
    const session = try session_result.next() orelse return error.MissingGeneratedSession;
    try std.testing.expectEqual(@as(i64, 13), try session.get(i64, 0));
    try session_result.drain();
}
