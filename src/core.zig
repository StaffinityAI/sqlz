const std = @import("std");

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

pub const Backend = enum { sqlite, postgres };
pub const Operation = enum { execute, fetch, iterate, transaction, connect };

pub const Error = struct {
    allocator: ?std.mem.Allocator = null,
    class: ErrorClass,
    backend: Backend,
    operation: Operation,
    code: ?i32 = null,
    message: []const u8,

    pub fn deinit(self: *const Error) void {
        if (self.allocator) |allocator| allocator.free(self.message);
    }
};

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: Error,
    };
}

pub fn Query(comptime options: anytype) type {
    const Options = @TypeOf(options);
    if (!@hasField(Options, "sql")) @compileError("sqlz.Query requires .sql");
    if (!@hasField(Options, "backends")) @compileError("sqlz.Query requires .backends");
    if (!@hasField(Options, "cardinality")) @compileError("sqlz.Query requires .cardinality");
    const BackendOptions = @TypeOf(options.backends);
    if (@hasField(BackendOptions, "postgres") and options.backends.postgres)
        @compileError("PostgreSQL execution is not implemented in this sqlz slice");
    if (!@hasField(BackendOptions, "sqlite") or !options.backends.sqlite)
        @compileError("sqlz.Query must select SQLite in this sqlz slice");

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

        pub fn execute(executor: anytype, args: Params) @TypeOf(executor.execute(sql, args)) {
            return executor.execute(sql, args);
        }
    };
}

fn OneQuery(comptime sql: []const u8, comptime Params: type, comptime Row: type) type {
    return struct {
        pub const params = Params;
        pub const row_type = Row;
        pub const cardinality: Cardinality = .one;

        pub fn fetchOne(executor: anytype, args: Params) @TypeOf(executor.fetchOne(Row, sql, args)) {
            return executor.fetchOne(Row, sql, args);
        }
    };
}

fn OptionalQuery(comptime sql: []const u8, comptime Params: type, comptime Row: type) type {
    return struct {
        pub const params = Params;
        pub const row_type = Row;
        pub const cardinality: Cardinality = .optional;

        pub fn fetchOptional(executor: anytype, args: Params) @TypeOf(executor.fetchOptional(Row, sql, args)) {
            return executor.fetchOptional(Row, sql, args);
        }
    };
}

fn ManyQuery(comptime sql: []const u8, comptime Params: type, comptime Row: type) type {
    return struct {
        pub const params = Params;
        pub const row_type = Row;
        pub const cardinality: Cardinality = .many;

        pub fn fetch(executor: anytype, args: Params) @TypeOf(executor.fetch(Row, sql, args)) {
            return executor.fetch(Row, sql, args);
        }
    };
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
            inline for (info.fields) |field|
                @field(result, field.name) = try cloneValue(allocator, field.type, @field(value, field.name));
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
        .@"struct" => |info| inline for (info.fields) |field|
            deinitValue(allocator, field.type, @field(value, field.name)),
        else => {},
    }
}
