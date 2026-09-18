const std = @import("std");
const pg = @import("pg");
const sqlz = @import("sqlz");

test "PostgreSQL adapter exposes the executor contract" {
    try std.testing.expectEqual(sqlz.Backend.postgres, sqlz.postgres.Conn.backend);
    try std.testing.expectEqual(sqlz.Backend.postgres, sqlz.postgres.Transaction.backend);
    try std.testing.expectEqual(sqlz.Backend.postgres, sqlz.postgres.Pool.backend);
    try std.testing.expect(@hasDecl(sqlz.postgres.Conn, "execute"));
    try std.testing.expect(@hasDecl(sqlz.postgres.Conn, "fetchOne"));
    try std.testing.expect(@hasDecl(sqlz.postgres.Conn, "fetchOptional"));
    try std.testing.expect(@hasDecl(sqlz.postgres.Conn, "fetch"));
    try std.testing.expect(@hasDecl(sqlz.postgres.Rows(struct { id: i64 }), "drain"));
}

test "PostgreSQL connection options wrap the pinned driver" {
    const options: sqlz.postgres.OpenOptions = .{
        .connect = .{ .host = "localhost", .port = 5432 },
        .auth = .{ .username = "postgres", .database = "postgres" },
    };
    try std.testing.expectEqualStrings("localhost", options.connect.host.?);
    try std.testing.expectEqual(@as(u16, 5432), options.connect.port.?);
    try std.testing.expect(@TypeOf(options.connect) == pg.Conn.Opts);
}

test "PostgreSQL generic executor paths compile" {
    const Role = enum(i32) { member, admin };
    const TextRole = enum {
        member,
        admin,
        pub const sqlz_storage: sqlz.Storage = .text;
    };
    const Row = struct {
        id: i64,
        active: bool,
        name: []const u8,
        role: Role,
        text_role: ?TextRole,
    };
    if (false) {
        var conn: sqlz.postgres.Conn = undefined;
        _ = conn.execute("update users set active=$1 where id=$2", .{ .active = true, .id = @as(i64, 1) });
        _ = conn.fetchOne(Row, "select id, active, name, role, text_role from users where id=$1", .{ .id = @as(i64, 1) });
        _ = conn.fetchOptional(Row, "select id, active, name, role, text_role from users where id=$1", .{ .id = @as(i64, 1) });
        _ = conn.fetch(Row, "select id, active, name, role, text_role from users where role=$1 and text_role=$2", .{
            .role = Role.admin,
            .text_role = @as(?TextRole, .member),
        });
        _ = conn.begin(.{});

        var pool: sqlz.postgres.Pool = undefined;
        _ = pool.acquire();
        _ = pool.execute("update users set active=$1", .{ .active = true });
        _ = pool.executeScript("create temporary table users_copy(id bigint)");
        _ = pool.fetchOne(Row, "select id, active, name, role, text_role from users", .{});
        _ = pool.fetchOptional(Row, "select id, active, name, role, text_role from users", .{});
        _ = pool.fetch(Row, "select id, active, name, role, text_role from users", .{});
        _ = pool.stats();

        var single: sqlz.postgres.Single(Row) = undefined;
        _ = single.toOwned(std.testing.allocator);
        var rows: sqlz.postgres.Rows(Row) = undefined;
        _ = rows.next();
        _ = rows.nextOwned(std.testing.allocator);
        _ = rows.collectOwned(std.testing.allocator);
        _ = rows.drain();
        var transaction: sqlz.postgres.Transaction = undefined;
        _ = transaction.commit();
        _ = transaction.rollback();
    }
}
