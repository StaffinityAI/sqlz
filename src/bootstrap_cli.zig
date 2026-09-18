const std = @import("std");
const analysis = @import("sqlz_analysis");
const bootstrap = @import("sqlz_bootstrap");
const catalog = @import("sqlz_catalog");
const checker = @import("sqlz_checker");
const config = @import("sqlz_config");
const migrations = @import("sqlz_migrations");
const pg = @import("pg");
const zqlite = @import("zqlite");
const ziggy = @import("ziggy");

const registration_marker = "--sqlz-build-registrations";

const Registration = struct {
    name: []const u8,
    config_path: []const u8,
};

const Options = struct {
    project: ?[]const u8 = null,
    sqlite_path: ?[]const u8 = null,
    postgres_url: ?[]const u8 = null,
    wipe_postgres: bool = false,
    yes: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const marker = findMarker(args) orelse return usage(error.MissingBuildRegistrations);
    const registrations = try parseRegistrations(arena, args[marker + 1 ..]);
    if (marker < 3 or
        !std.mem.eql(u8, args[1], "bootstrap") or
        !std.mem.eql(u8, args[2], "postgres"))
        return usage(error.InvalidCommand);
    const options = try parseOptions(args[3..marker]);
    const registration = try resolveRegistration(registrations, options.project);
    const sqlite_path = options.sqlite_path orelse return usage(error.MissingSqlitePath);
    const postgres_url = options.postgres_url orelse
        init.environ_map.get("DATABASE_URL") orelse return usage(error.MissingPostgresUrl);
    if (options.wipe_postgres and !options.yes) return error.WipeRequiresYes;

    try run(allocator, init.io, registration, sqlite_path, postgres_url, options);
}

fn usage(err: anyerror) @TypeOf(err) {
    std.log.err(
        "usage: zig build sqlz -- bootstrap postgres --from-sqlite PATH [--project NAME] [--postgres-url URL] [--wipe-postgres --yes]",
        .{},
    );
    return err;
}

fn findMarker(args: []const []const u8) ?usize {
    for (args, 0..) |arg, index| if (std.mem.eql(u8, arg, registration_marker)) return index;
    return null;
}

fn parseRegistrations(allocator: std.mem.Allocator, args: []const []const u8) ![]Registration {
    if (args.len % 3 != 0) return error.InvalidBuildRegistration;
    const registrations = try allocator.alloc(Registration, args.len / 3);
    var index: usize = 0;
    while (index < args.len) : (index += 3) {
        if (!std.mem.eql(u8, args[index], "--registration")) return error.InvalidBuildRegistration;
        registrations[index / 3] = .{ .name = args[index + 1], .config_path = args[index + 2] };
    }
    return registrations;
}

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--wipe-postgres")) {
            options.wipe_postgres = true;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            options.yes = true;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--project")) {
            if (index + 1 >= args.len) return error.MissingOptionValue;
            options.project = args[index + 1];
            index += 2;
        } else if (std.mem.eql(u8, arg, "--from-sqlite")) {
            if (index + 1 >= args.len) return error.MissingOptionValue;
            options.sqlite_path = args[index + 1];
            index += 2;
        } else if (std.mem.eql(u8, arg, "--postgres-url")) {
            if (index + 1 >= args.len) return error.MissingOptionValue;
            options.postgres_url = args[index + 1];
            index += 2;
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}

fn resolveRegistration(registrations: []const Registration, requested: ?[]const u8) !Registration {
    if (requested) |name| {
        for (registrations) |registration|
            if (std.mem.eql(u8, registration.name, name)) return registration;
        return error.UnknownProject;
    }
    if (registrations.len == 0) return error.MissingProject;
    if (registrations.len != 1) return error.AmbiguousProject;
    return registrations[0];
}

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    registration: Registration,
    sqlite_path: []const u8,
    postgres_url: []const u8,
    options: Options,
) !void {
    const project_path = std.fs.path.dirname(registration.config_path) orelse ".";
    const config_name = std.fs.path.basename(registration.config_path);
    var project_dir = try std.Io.Dir.cwd().openDir(io, project_path, .{ .iterate = true });
    defer project_dir.close(io);

    const raw_config = try project_dir.readFileAlloc(io, config_name, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(raw_config);
    const config_source = try allocator.dupeZ(u8, raw_config);
    defer allocator.free(config_source);
    var meta: ziggy.Deserializer.Meta = .init;
    var loaded = try config.parse(allocator, config_source, &meta);
    defer loaded.deinit();
    const project = loaded.config();
    if (project.backends.sqlite == null or project.backends.postgres == null)
        return error.BootstrapRequiresBothBackends;
    if (project.backends.postgres.?.search_path.len != 1 or
        std.mem.eql(u8, project.backends.postgres.?.search_path[0], "public"))
        return error.DedicatedPostgresSchemaRequired;
    const destination_schema = project.backends.postgres.?.search_path[0];
    const source_limit = std.math.cast(usize, project.limits.source_bytes) orelse return error.InvalidLimit;

    var migration_dir = try project_dir.openDir(io, project.migrations, .{ .iterate = true });
    defer migration_dir.close(io);
    var discovery = try migrations.discover(allocator, io, migration_dir, source_limit);
    defer discovery.deinit();
    for (discovery.revisions) |revision| {
        const manifest = revision.manifest.manifest();
        if (migrations.targetsBackend(manifest, .postgres) and manifest.transaction.postgres == .never)
            return error.NonTransactionalMigrationUnsupported;
    }

    const sqlite_dialect: checker.SqliteDialect = .{
        .profile = checker.SqliteProfile.fromString(project.backends.sqlite.?.profile) orelse unreachable,
    };
    const postgres_dialect: checker.PostgresDialect = .{
        .profile = checker.PostgresProfile.fromString(project.backends.postgres.?.profile) orelse unreachable,
    };
    var sqlite_catalog = try checker.replayDiscoveredSqliteWithDialect(allocator, &discovery, sqlite_dialect);
    defer sqlite_catalog.deinit();
    var postgres_catalog = try checker.replayDiscoveredPostgresWithOptions(allocator, &discovery, .{
        .dialect = postgres_dialect,
        .search_path = project.backends.postgres.?.search_path,
    });
    defer postgres_catalog.deinit();
    var transfer = try bootstrap.plan(allocator, &sqlite_catalog, &postgres_catalog, destination_schema);
    defer transfer.deinit();

    const sqlite_path_z = try allocator.dupeZ(u8, sqlite_path);
    defer allocator.free(sqlite_path_z);
    const source = try zqlite.open(sqlite_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
    defer source.close();
    try source.transaction();
    errdefer source.rollback();
    try validateSqliteSchema(allocator, source, &transfer);

    const uri = try std.Uri.parse(postgres_url);
    var destination = try pg.Conn.openAndAuthUri(io, allocator, uri);
    defer destination.deinit();

    try acquireLock(&destination, project.project_id);
    defer releaseLock(&destination, project.project_id) catch {};
    const populated = try schemaPopulated(&destination, destination_schema);
    if (populated and !options.wipe_postgres) return error.NonEmptyPostgresDestination;

    try destination.begin();
    errdefer destination.rollback() catch {};
    if (options.wipe_postgres) {
        std.log.warn("wiping managed PostgreSQL schema {s}", .{destination_schema});
        const drop_sql = try schemaStatement(allocator, "DROP SCHEMA IF EXISTS ", destination_schema, " CASCADE");
        defer allocator.free(drop_sql);
        _ = try destination.exec(drop_sql, .{});
    }
    const create_sql = try schemaStatement(allocator, "CREATE SCHEMA IF NOT EXISTS ", destination_schema, "");
    defer allocator.free(create_sql);
    _ = try destination.exec(create_sql, .{});
    const search_path_sql = try schemaStatement(allocator, "SET LOCAL search_path TO ", destination_schema, "");
    defer allocator.free(search_path_sql);
    _ = try destination.exec(search_path_sql, .{});
    try applyPostgresMigrations(allocator, &destination, &discovery);

    for (transfer.tables) |table| {
        const copied = try transferTable(allocator, source, &destination, table);
        try restoreSequences(allocator, &destination, table);
        const destination_count = try tableRowCount(allocator, &destination, table);
        if (destination_count != copied) return error.RowCountMismatch;
    }
    try source.commit();
    try destination.commit();
    std.log.info("bootstrapped project {s} from {s}", .{ registration.name, sqlite_path });
}

fn validateSqliteSchema(
    allocator: std.mem.Allocator,
    source: zqlite.Conn,
    transfer: *const bootstrap.TransferPlan,
) !void {
    var live_tables = try source.prepare(
        "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    defer live_tables.deinit();
    var live_count: usize = 0;
    while (try live_tables.step()) : (live_count += 1) {
        const name = live_tables.text(0);
        var found = false;
        for (transfer.tables) |table| {
            if (std.mem.eql(u8, name, table.source_name)) {
                found = true;
                break;
            }
        }
        if (!found) return error.SqliteSchemaMismatch;
    }
    if (live_count != transfer.tables.len) return error.SqliteSchemaMismatch;

    for (transfer.tables) |table| {
        const sql = try pragmaTableInfo(allocator, table.source_name);
        defer allocator.free(sql);
        var stmt = try source.prepare(sql);
        defer stmt.deinit();
        var index: usize = 0;
        while (try stmt.step()) : (index += 1) {
            if (index >= table.columns.len) return error.SqliteSchemaMismatch;
            const expected = table.columns[index];
            const primary_key = stmt.int(5) != 0;
            const nullable = stmt.int(3) == 0 and !primary_key;
            if (!std.mem.eql(u8, stmt.text(1), expected.source_name) or
                analysis.scalarType(stmt.text(2)) != analysis.scalarType(expected.source_type) or
                nullable != expected.source_nullable or
                primary_key != expected.source_primary_key)
                return error.SqliteSchemaMismatch;
        }
        if (index != table.columns.len) return error.SqliteSchemaMismatch;
    }
}

fn schemaPopulated(conn: *pg.Conn, schema: []const u8) !bool {
    const sql =
        "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_class c " ++
        "JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace " ++
        "WHERE n.nspname = $1 AND c.relkind IN ('r','p','v','m','S','f'))";
    var result = try conn.query(sql, .{schema});
    defer result.deinit();
    const row = try result.next() orelse return error.InvalidPostgresResponse;
    const exists = try row.get(bool, 0);
    try result.drain();
    return exists;
}

fn acquireLock(conn: *pg.Conn, project_id: []const u8) !void {
    _ = try conn.exec("SELECT pg_advisory_lock(hashtextextended($1, 0))", .{project_id});
}

fn releaseLock(conn: *pg.Conn, project_id: []const u8) !void {
    _ = try conn.exec("SELECT pg_advisory_unlock(hashtextextended($1, 0))", .{project_id});
}

fn applyPostgresMigrations(
    allocator: std.mem.Allocator,
    conn: *pg.Conn,
    discovery: *const migrations.Discovery,
) !void {
    const graph = try allocator.alloc(migrations.Revision, discovery.revisions.len);
    defer allocator.free(graph);
    for (discovery.revisions, graph) |revision, *node| {
        const manifest = revision.manifest.manifest();
        node.* = .{ .id = manifest.revision, .parents = manifest.parents };
    }
    var order = try migrations.validateAndOrder(allocator, graph);
    defer order.deinit();
    for (order.indices) |index| {
        const revision = &discovery.revisions[index];
        const manifest = revision.manifest.manifest();
        if (!migrations.targetsBackend(manifest, .postgres)) continue;
        if (revision.common_up.len != 0) _ = try conn.exec(revision.common_up, .{});
        if (revision.postgres_up.len != 0) _ = try conn.exec(revision.postgres_up, .{});
    }
}

fn transferTable(
    allocator: std.mem.Allocator,
    source: zqlite.Conn,
    destination: *pg.Conn,
    table: bootstrap.TablePlan,
) !usize {
    const select_sql = try selectStatement(allocator, table);
    defer allocator.free(select_sql);
    const insert_sql = try insertStatement(allocator, table);
    defer allocator.free(insert_sql);
    var rows = try source.prepare(select_sql);
    defer rows.deinit();
    var row_index: usize = 0;
    while (try rows.step()) : (row_index += 1) {
        var stmt = destination.prepare(insert_sql) catch |err| {
            std.log.err("failed to prepare insert for {s}.{s}", .{ table.destination_schema, table.destination_name });
            return err;
        };
        errdefer stmt.deinit();
        for (table.columns, 0..) |column, index| bindValue(&stmt, rows, index, column) catch |err| {
            std.log.err("failed to bind row {d}, column {s} for {s}.{s}", .{
                row_index,
                column.destination_name,
                table.destination_schema,
                table.destination_name,
            });
            return err;
        };
        var result = stmt.execute() catch |err| {
            std.log.err("failed to execute row {d} for {s}.{s}", .{
                row_index,
                table.destination_schema,
                table.destination_name,
            });
            return err;
        };
        defer result.deinit();
        result.drain() catch |err| {
            std.log.err("failed to drain row {d} result for {s}.{s}", .{
                row_index,
                table.destination_schema,
                table.destination_name,
            });
            return err;
        };
    }
    std.log.info("copied {d} rows into {s}.{s}", .{ row_index, table.destination_schema, table.destination_name });
    return row_index;
}

fn restoreSequences(allocator: std.mem.Allocator, conn: *pg.Conn, table: bootstrap.TablePlan) !void {
    const qualified = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ table.destination_schema, table.destination_name });
    defer allocator.free(qualified);
    for (table.columns) |column| {
        if (!column.primary_key or column.conversion != .integer) continue;
        var sequence_result = try conn.query("SELECT pg_get_serial_sequence($1, $2)", .{ qualified, column.destination_name });
        const sequence_row = try sequence_result.next() orelse {
            sequence_result.deinit();
            return error.InvalidPostgresResponse;
        };
        const borrowed_sequence = try sequence_row.get(?[]const u8, 0);
        const sequence = if (borrowed_sequence) |value| try allocator.dupe(u8, value) else null;
        try sequence_result.drain();
        sequence_result.deinit();
        defer if (sequence) |value| allocator.free(value);
        if (sequence == null) continue;

        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(allocator);
        try sql.appendSlice(allocator, "SELECT setval($1::regclass, COALESCE(MAX(");
        try appendQuoted(&sql, allocator, column.destination_name);
        try sql.appendSlice(allocator, "), 1), MAX(");
        try appendQuoted(&sql, allocator, column.destination_name);
        try sql.appendSlice(allocator, ") IS NOT NULL) FROM ");
        try appendQuoted(&sql, allocator, table.destination_schema);
        try sql.append(allocator, '.');
        try appendQuoted(&sql, allocator, table.destination_name);
        _ = try conn.exec(sql.items, .{sequence.?});
    }
}

fn tableRowCount(allocator: std.mem.Allocator, conn: *pg.Conn, table: bootstrap.TablePlan) !usize {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "SELECT COUNT(*) FROM ");
    try appendQuoted(&sql, allocator, table.destination_schema);
    try sql.append(allocator, '.');
    try appendQuoted(&sql, allocator, table.destination_name);
    var result = try conn.query(sql.items, .{});
    defer result.deinit();
    const row = try result.next() orelse return error.InvalidPostgresResponse;
    const count = try row.get(i64, 0);
    try result.drain();
    return std.math.cast(usize, count) orelse error.RowCountOverflow;
}

fn bindValue(stmt: *pg.Stmt, row: zqlite.Stmt, index: usize, column: bootstrap.ColumnPlan) !void {
    switch (row.columnType(index)) {
        .null => {
            if (!column.nullable) return error.UnexpectedNull;
            try stmt.bind(null);
        },
        .int => {
            const value = row.int(index);
            switch (column.conversion) {
                .integer => try stmt.bind(value),
                .real => try stmt.bind(@as(f64, @floatFromInt(value))),
                .boolean => {
                    if (value != 0 and value != 1) return error.InvalidBoolean;
                    try stmt.bind(value == 1);
                },
                else => return error.IncompatibleStorageClass,
            }
        },
        .float => {
            if (column.conversion != .real) return error.IncompatibleStorageClass;
            try stmt.bind(row.float(index));
        },
        .text => {
            if (column.conversion != .text) return error.IncompatibleStorageClass;
            try stmt.bind(row.text(index));
        },
        .blob => {
            if (column.conversion != .blob) return error.IncompatibleStorageClass;
            try stmt.bind(row.blob(index));
        },
        .unknown => return error.UnsupportedSQLiteStorageClass,
    }
}

fn selectStatement(allocator: std.mem.Allocator, table: bootstrap.TablePlan) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "SELECT ");
    for (table.columns, 0..) |column, index| {
        if (index != 0) try output.appendSlice(allocator, ", ");
        try appendQuoted(&output, allocator, column.source_name);
    }
    try output.appendSlice(allocator, " FROM ");
    try appendQuoted(&output, allocator, table.source_name);
    return output.toOwnedSlice(allocator);
}

fn insertStatement(allocator: std.mem.Allocator, table: bootstrap.TablePlan) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "INSERT INTO ");
    try appendQuoted(&output, allocator, table.destination_schema);
    try output.append(allocator, '.');
    try appendQuoted(&output, allocator, table.destination_name);
    try output.appendSlice(allocator, " (");
    for (table.columns, 0..) |column, index| {
        if (index != 0) try output.appendSlice(allocator, ", ");
        try appendQuoted(&output, allocator, column.destination_name);
    }
    try output.appendSlice(allocator, ") VALUES (");
    for (table.columns, 0..) |_, index| {
        if (index != 0) try output.appendSlice(allocator, ", ");
        try output.print(allocator, "${d}", .{index + 1});
    }
    try output.append(allocator, ')');
    return output.toOwnedSlice(allocator);
}

fn pragmaTableInfo(allocator: std.mem.Allocator, table: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "PRAGMA table_info(");
    try appendQuoted(&output, allocator, table);
    try output.append(allocator, ')');
    return output.toOwnedSlice(allocator);
}

fn schemaStatement(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    schema: []const u8,
    suffix: []const u8,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, prefix);
    try appendQuoted(&output, allocator, schema);
    try output.appendSlice(allocator, suffix);
    return output.toOwnedSlice(allocator);
}

fn appendQuoted(output: *std.ArrayList(u8), allocator: std.mem.Allocator, identifier: []const u8) !void {
    try output.append(allocator, '"');
    for (identifier) |byte| {
        if (byte == '"') try output.append(allocator, '"');
        try output.append(allocator, byte);
    }
    try output.append(allocator, '"');
}
