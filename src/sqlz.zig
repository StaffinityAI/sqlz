const std = @import("std");
const zqlite = @import("zqlite");
const libpg_query = @import("libpg_query");

pub const Backends = struct {
    sqlite: bool = false,
    postgres: bool = false,
};

pub const Cardinality = enum { exec, one, optional, many };

pub const ExecResult = struct {
    rows_affected: ?u64,
};

pub const ErrorClass = enum {
    constraint,
    unavailable,
    timeout,
    cancelled,
    protocol,
    invalid_data,
    other,
};

pub const Error = struct {
    allocator: ?std.mem.Allocator = null,
    class: ErrorClass,
    backend: enum { sqlite },
    operation: Operation,
    code: ?i32 = null,
    message: []const u8,

    pub fn deinit(self: *const Error) void {
        if (self.allocator) |allocator| allocator.free(self.message);
    }
};

pub const Operation = enum { execute, fetch, iterate, transaction, connect };

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: Error,
    };
}

pub const Blob = zqlite.Blob;
pub const blob = zqlite.blob;

pub fn Query(comptime options: anytype) type {
    const Options = @TypeOf(options);
    if (!@hasField(Options, "sql")) @compileError("sqlz.Query requires .sql");
    if (!@hasField(Options, "backends")) @compileError("sqlz.Query requires .backends");
    if (!@hasField(Options, "cardinality")) @compileError("sqlz.Query requires .cardinality");
    const BackendOptions = @TypeOf(options.backends);
    if (@hasField(BackendOptions, "postgres") and options.backends.postgres) @compileError("PostgreSQL is not implemented in this sqlz slice");
    if (!@hasField(BackendOptions, "sqlite") or !options.backends.sqlite) @compileError("sqlz.Query must select SQLite in this sqlz slice");

    const Params = if (@hasField(Options, "params")) options.params else struct {};
    const cardinality: Cardinality = options.cardinality;
    return switch (cardinality) {
        .exec => ExecQuery(options.sql, Params),
        .one => blk: {
            if (!@hasField(Options, "row")) @compileError("row-returning queries require .row");
            break :blk OneQuery(options.sql, Params, options.row);
        },
        .optional => blk: {
            if (!@hasField(Options, "row")) @compileError("row-returning queries require .row");
            break :blk OptionalQuery(options.sql, Params, options.row);
        },
        .many => blk: {
            if (!@hasField(Options, "row")) @compileError("row-returning queries require .row");
            break :blk ManyQuery(options.sql, Params, options.row);
        },
    };
}

fn ExecQuery(comptime sql: []const u8, comptime Params: type) type {
    return struct {
        pub const params = Params;
        pub const cardinality: Cardinality = .exec;

        pub fn execute(executor: anytype, args: Params) Result(ExecResult) {
            return executor.execute(sql, args);
        }
    };
}

fn OneQuery(comptime sql: []const u8, comptime Params: type, comptime Row: type) type {
    return struct {
        pub const params = Params;
        pub const row_type = Row;
        pub const cardinality: Cardinality = .one;

        pub fn fetchOne(executor: anytype, args: Params) Result(sqlite.Single(Row)) {
            return executor.fetchOne(Row, sql, args);
        }
    };
}

fn OptionalQuery(comptime sql: []const u8, comptime Params: type, comptime Row: type) type {
    return struct {
        pub const params = Params;
        pub const row_type = Row;
        pub const cardinality: Cardinality = .optional;

        pub fn fetchOptional(executor: anytype, args: Params) Result(?sqlite.Single(Row)) {
            return executor.fetchOptional(Row, sql, args);
        }
    };
}

fn ManyQuery(comptime sql: []const u8, comptime Params: type, comptime Row: type) type {
    return struct {
        pub const params = Params;
        pub const row_type = Row;
        pub const cardinality: Cardinality = .many;

        pub fn fetch(executor: anytype, args: Params) Result(sqlite.Rows(Row)) {
            return executor.fetch(Row, sql, args);
        }
    };
}

pub const sqlite = struct {
    pub const Conn = struct {
        allocator: std.mem.Allocator,
        conn: zqlite.Conn,
        owned: bool = true,

        pub fn deinit(self: *Conn) void {
            if (self.owned) self.conn.close();
            self.* = undefined;
        }

        pub fn raw(self: *Conn) zqlite.Conn {
            return self.conn;
        }

        pub fn begin(self: *Conn) Result(Transaction) {
            self.conn.transaction() catch |cause| return .{ .err = makeError(self.allocator, self.conn, .transaction, cause) };
            return .{ .ok = .{ .connection = self } };
        }

        pub fn execute(self: *Conn, sql: []const u8, args: anytype) Result(ExecResult) {
            self.conn.exec(sql, args) catch |cause| return .{ .err = makeError(self.allocator, self.conn, .execute, cause) };
            return .{ .ok = .{ .rows_affected = @intCast(self.conn.changes()) } };
        }

        pub fn fetchOne(self: *Conn, comptime Row: type, sql: []const u8, args: anytype) Result(Single(Row)) {
            const native = self.conn.row(sql, args) catch |cause| return .{ .err = makeError(self.allocator, self.conn, .fetch, cause) };
            const row = native orelse return .{ .err = staticError(.invalid_data, .fetch, "query expected one row but returned none") };
            return .{ .ok = Single(Row).init(row) };
        }

        pub fn fetchOptional(self: *Conn, comptime Row: type, sql: []const u8, args: anytype) Result(?Single(Row)) {
            const native = self.conn.row(sql, args) catch |cause| return .{ .err = makeError(self.allocator, self.conn, .fetch, cause) };
            const row = native orelse return .{ .ok = null };
            return .{ .ok = Single(Row).init(row) };
        }

        pub fn fetch(self: *Conn, comptime Row: type, sql: []const u8, args: anytype) Result(Rows(Row)) {
            const native = self.conn.rows(sql, args) catch |cause| return .{ .err = makeError(self.allocator, self.conn, .fetch, cause) };
            return .{ .ok = .{ .allocator = self.allocator, .conn = self.conn, .native = native } };
        }
    };

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Conn {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const conn = try zqlite.open(path_z.ptr, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn Single(comptime Row: type) type {
        return struct {
            native: zqlite.Row,
            value: Row,

            fn init(native: zqlite.Row) @This() {
                return .{ .native = native, .value = decodeRow(Row, native) };
            }

            pub fn row(self: *@This()) Row {
                return self.value;
            }

            pub fn deinit(self: *@This()) void {
                self.native.deinit();
                self.* = undefined;
            }

            pub fn toOwned(self: *@This(), allocator: std.mem.Allocator) Result(Owned(Row)) {
                const value = cloneRow(allocator, self.value) catch return .{ .err = staticError(.other, .fetch, "unable to allocate owned row") };
                return .{ .ok = .{ .allocator = allocator, .value = value } };
            }
        };
    }

    pub fn Owned(comptime Row: type) type {
        return struct {
            allocator: std.mem.Allocator,
            value: Row,

            pub fn row(self: *@This()) Row {
                return self.value;
            }

            pub fn deinit(self: *@This()) void {
                deinitOwnedRow(self.allocator, &self.value);
                self.* = undefined;
            }
        };
    }

    pub fn Rows(comptime Row: type) type {
        return struct {
            allocator: std.mem.Allocator,
            conn: zqlite.Conn,
            native: zqlite.Rows,
            finished: bool = false,

            pub fn next(self: *@This()) Result(?Row) {
                if (self.finished) return .{ .ok = null };
                if (self.native.next()) |native_row| return .{ .ok = decodeRow(Row, native_row) };
                self.finished = true;
                if (self.native.err) |cause| return .{ .err = makeError(self.allocator, self.conn, .iterate, cause) };
                return .{ .ok = null };
            }

            pub fn drain(self: *@This()) Result(void) {
                while (true) switch (self.next()) {
                    .ok => |row| if (row == null) return .{ .ok = {} },
                    .err => |err| return .{ .err = err },
                };
            }

            pub fn deinit(self: *@This()) void {
                self.native.deinit();
                self.* = undefined;
            }
        };
    }

    pub const Transaction = struct {
        connection: *Conn,
        active: bool = true,

        pub fn execute(self: *Transaction, sql: []const u8, args: anytype) Result(ExecResult) {
            return self.connection.execute(sql, args);
        }

        pub fn fetchOne(self: *Transaction, comptime Row: type, sql: []const u8, args: anytype) Result(Single(Row)) {
            return self.connection.fetchOne(Row, sql, args);
        }

        pub fn fetchOptional(self: *Transaction, comptime Row: type, sql: []const u8, args: anytype) Result(?Single(Row)) {
            return self.connection.fetchOptional(Row, sql, args);
        }

        pub fn fetch(self: *Transaction, comptime Row: type, sql: []const u8, args: anytype) Result(Rows(Row)) {
            return self.connection.fetch(Row, sql, args);
        }

        pub fn raw(self: *Transaction) zqlite.Conn {
            return self.connection.conn;
        }

        pub fn commit(self: *Transaction) Result(void) {
            if (!self.active) return .{ .err = staticError(.invalid_data, .transaction, "transaction is no longer active") };
            self.connection.conn.commit() catch |cause| return .{ .err = makeError(self.connection.allocator, self.connection.conn, .transaction, cause) };
            self.active = false;
            return .{ .ok = {} };
        }

        pub fn rollback(self: *Transaction) Result(void) {
            if (!self.active) return .{ .err = staticError(.invalid_data, .transaction, "transaction is no longer active") };
            self.connection.conn.rollback();
            self.active = false;
            return .{ .ok = {} };
        }

        pub fn deinit(self: *Transaction) void {
            if (self.active) self.connection.conn.rollback();
            self.* = undefined;
        }
    };

    fn decodeRow(comptime Row: type, native: zqlite.Row) Row {
        var value: Row = undefined;
        inline for (@typeInfo(Row).@"struct".fields, 0..) |field, index| {
            @field(value, field.name) = native.get(field.type, index);
        }
        return value;
    }
};

fn staticError(class: ErrorClass, operation: Operation, message: []const u8) Error {
    return .{ .class = class, .backend = .sqlite, .operation = operation, .message = message };
}

fn makeError(allocator: std.mem.Allocator, conn: zqlite.Conn, operation: Operation, cause: anyerror) Error {
    const message = allocator.dupe(u8, std.mem.span(conn.lastError())) catch return staticError(classify(cause), operation, @errorName(cause));
    return .{
        .allocator = allocator,
        .class = classify(cause),
        .backend = .sqlite,
        .operation = operation,
        .message = message,
    };
}

fn classify(cause: anyerror) ErrorClass {
    return switch (cause) {
        error.Constraint,
        error.ConstraintCheck,
        error.ConstraintForeignKey,
        error.ConstraintNotNull,
        error.ConstraintPrimaryKey,
        error.ConstraintUnique,
        => .constraint,
        error.Busy, error.BusyTimeout, error.Locked => .unavailable,
        error.Interrupt => .cancelled,
        error.Protocol => .protocol,
        error.Mismatch, error.ConstraintDatatype => .invalid_data,
        else => .other,
    };
}

pub const RewrittenSql = struct {
    sql: []u8,
    names: []const []const u8,

    pub fn deinit(self: *RewrittenSql, allocator: std.mem.Allocator) void {
        allocator.free(self.sql);
        for (self.names) |name| allocator.free(name);
        allocator.free(self.names);
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

fn rewriteParameters(allocator: std.mem.Allocator, source: []const u8, comptime style: ParameterStyle) !RewrittenSql {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    const State = enum { normal, single, double, backtick, bracket, line_comment, block_comment };
    var state: State = .normal;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        switch (state) {
            .normal => {
                if (c == '\'') state = .single else if (c == '"') state = .double else if (c == '`') state = .backtick else if (c == '[') state = .bracket else if (c == '-' and i + 1 < source.len and source[i + 1] == '-') state = .line_comment else if (c == '/' and i + 1 < source.len and source[i + 1] == '*') state = .block_comment else if (c == ':' and (i == 0 or source[i - 1] != ':') and i + 1 < source.len and isIdentStart(source[i + 1])) {
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
                        .postgres => "${d}",
                    }, .{ordinal});
                    defer allocator.free(marker);
                    try output.appendSlice(allocator, marker);
                    i = end;
                    continue;
                }
            },
            .single => if (c == '\'' and !(i + 1 < source.len and source[i + 1] == '\'')) {
                state = .normal;
            } else if (c == '\'' and i + 1 < source.len and source[i + 1] == '\'') {
                try output.append(allocator, c);
                i += 1;
            },
            .double => {
                if (c == '"') state = .normal;
            },
            .backtick => {
                if (c == '`') state = .normal;
            },
            .bracket => {
                if (c == ']') state = .normal;
            },
            .line_comment => {
                if (c == '\n') state = .normal;
            },
            .block_comment => if (c == '*' and i + 1 < source.len and source[i + 1] == '/') {
                try output.append(allocator, c);
                i += 1;
                state = .normal;
            },
        }
        try output.append(allocator, c);
        i += 1;
    }

    return .{ .sql = try output.toOwnedSlice(allocator), .names = try names.toOwnedSlice(allocator) };
}

/// The shared SQL parser boundary used by the offline checker. libpg_query owns
/// the grammar; sqlz only performs its portable named-parameter rewrite first.
/// SQLite-only grammar is intentionally handled by the SQLite validation layer.
pub const parser = struct {
    pub const ParseError = error{ EmptyInput, ParseError } || std.mem.Allocator.Error;

    pub const ParseResult = struct {
        rewritten: RewrittenSql,
        ast_json: []const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *ParseResult) void {
            self.allocator.free(self.ast_json);
            self.rewritten.deinit(self.allocator);
            self.* = undefined;
        }
    };

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!ParseResult {
        if (source.len == 0) return error.EmptyInput;
        var rewritten = try rewritePostgres(allocator, source);
        errdefer rewritten.deinit(allocator);

        // libpg_query's C API requires a NUL terminator. Preserve that invariant
        // explicitly for generated SQL.
        const terminated = try allocator.dupeZ(u8, rewritten.sql);
        defer allocator.free(terminated);

        const native = libpg_query.pg_query_parse(terminated.ptr);
        defer libpg_query.pg_query_free_parse_result(native);
        if (native.@"error" != null) return error.ParseError;
        const ast_json = try allocator.dupe(u8, std.mem.span(native.parse_tree));
        return .{
            .rewritten = rewritten,
            .ast_json = ast_json,
            .allocator = allocator,
        };
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

pub fn cloneRow(allocator: std.mem.Allocator, value: anytype) !@TypeOf(value) {
    return cloneValue(allocator, @TypeOf(value), value);
}

fn cloneValue(allocator: std.mem.Allocator, comptime T: type, value: T) !T {
    if (T == []const u8) return try allocator.dupe(u8, value);
    return switch (@typeInfo(T)) {
        .optional => |optional| if (value) |inner| try cloneValue(allocator, optional.child, inner) else null,
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.fields) |field| @field(result, field.name) = try cloneValue(allocator, field.type, @field(value, field.name));
            break :blk result;
        },
        else => value,
    };
}

pub fn deinitOwnedRow(allocator: std.mem.Allocator, value: anytype) void {
    deinitValue(allocator, @TypeOf(value.*), value.*);
}

fn deinitValue(allocator: std.mem.Allocator, comptime T: type, value: T) void {
    if (T == []const u8) {
        allocator.free(value);
        return;
    }
    switch (@typeInfo(T)) {
        .optional => |optional| if (value) |inner| deinitValue(allocator, optional.child, inner),
        .@"struct" => |info| inline for (info.fields) |field| deinitValue(allocator, field.type, @field(value, field.name)),
        else => {},
    }
}
