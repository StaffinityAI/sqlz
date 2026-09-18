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
    const sqlite = @hasField(BackendOptions, "sqlite") and options.backends.sqlite;
    const postgres = @hasField(BackendOptions, "postgres") and options.backends.postgres;
    if (!sqlite and !postgres) @compileError("sqlz.Query requires at least one backend");

    const Params = if (@hasField(Options, "params")) options.params else struct {};
    const parameter_names = if (@hasField(Options, "parameter_names")) options.parameter_names else .{};
    const cardinality: Cardinality = options.cardinality;
    return switch (cardinality) {
        .exec => ExecQuery(options.sql, Params, parameter_names),
        .one => blk: {
            if (!@hasField(Options, "row")) @compileError("row-returning queries require .row");
            break :blk OneQuery(options.sql, Params, options.row, parameter_names);
        },
        .optional => blk: {
            if (!@hasField(Options, "row")) @compileError("row-returning queries require .row");
            break :blk OptionalQuery(options.sql, Params, options.row, parameter_names);
        },
        .many => blk: {
            if (!@hasField(Options, "row")) @compileError("row-returning queries require .row");
            break :blk ManyQuery(options.sql, Params, options.row, parameter_names);
        },
    };
}

fn ExecQuery(comptime sql_text: anytype, comptime Params: type, comptime names: anytype) type {
    return struct {
        pub const params = Params;
        pub const cardinality: Cardinality = .exec;
        pub const sql = sql_text;
        pub const parameter_names = names;

        pub fn execute(executor: anytype, args: Params) @TypeOf(executor.execute(selectedSql(sql_text, @TypeOf(executor)), args)) {
            return executor.execute(selectedSql(sql_text, @TypeOf(executor)), args);
        }
    };
}

fn OneQuery(comptime sql_text: anytype, comptime Params: type, comptime Row: type, comptime names: anytype) type {
    return struct {
        pub const params = Params;
        pub const row_type = Row;
        pub const cardinality: Cardinality = .one;
        pub const sql = sql_text;
        pub const parameter_names = names;

        pub fn fetchOne(executor: anytype, args: Params) @TypeOf(executor.fetchOne(Row, selectedSql(sql_text, @TypeOf(executor)), args)) {
            return executor.fetchOne(Row, selectedSql(sql_text, @TypeOf(executor)), args);
        }
    };
}

fn OptionalQuery(comptime sql_text: anytype, comptime Params: type, comptime Row: type, comptime names: anytype) type {
    return struct {
        pub const params = Params;
        pub const row_type = Row;
        pub const cardinality: Cardinality = .optional;
        pub const sql = sql_text;
        pub const parameter_names = names;

        pub fn fetchOptional(executor: anytype, args: Params) @TypeOf(executor.fetchOptional(Row, selectedSql(sql_text, @TypeOf(executor)), args)) {
            return executor.fetchOptional(Row, selectedSql(sql_text, @TypeOf(executor)), args);
        }
    };
}

fn ManyQuery(comptime sql_text: anytype, comptime Params: type, comptime Row: type, comptime names: anytype) type {
    return struct {
        pub const params = Params;
        pub const row_type = Row;
        pub const cardinality: Cardinality = .many;
        pub const sql = sql_text;
        pub const parameter_names = names;

        pub fn fetch(executor: anytype, args: Params) @TypeOf(executor.fetch(Row, selectedSql(sql_text, @TypeOf(executor)), args)) {
            return executor.fetch(Row, selectedSql(sql_text, @TypeOf(executor)), args);
        }
    };
}

fn selectedSql(comptime sql: anytype, comptime Executor: type) []const u8 {
    if (@TypeOf(sql) == []const u8) return sql;
    switch (@typeInfo(@TypeOf(sql))) {
        .pointer => |pointer| if (pointer.size == .one and @typeInfo(pointer.child) == .array and
            @typeInfo(pointer.child).array.child == u8) return sql,
        else => {},
    }
    const T = switch (@typeInfo(Executor)) {
        .pointer => |pointer| pointer.child,
        else => Executor,
    };
    if (!@hasDecl(T, "backend"))
        @compileError("sqlz executor must declare pub const backend");
    return switch (T.backend) {
        .sqlite => if (@hasField(@TypeOf(sql), "sqlite")) sql.sqlite else @compileError("query has no SQLite SQL variant"),
        .postgres => if (@hasField(@TypeOf(sql), "postgres")) sql.postgres else @compileError("query has no PostgreSQL SQL variant"),
    };
}

/// How an application enum is stored in the database. An enum declares
/// `pub const sqlz_storage = .text;` to opt into name storage; the default is
/// the integer tag, which is what SQLite's INTEGER affinity holds.
pub const Storage = enum { integer, text };

pub fn enumStorage(comptime E: type) Storage {
    if (!@hasDecl(E, "sqlz_storage")) return .integer;
    const declared: Storage = E.sqlz_storage;
    return declared;
}

/// The parameter struct a backend driver actually receives: application enums
/// are lowered to their stored representation, every other field is passed
/// through unchanged. Field names and tuple-ness survive, because drivers bind
/// named structs by parameter name and tuples by position.
pub fn BoundArgs(comptime Args: type) type {
    const info = @typeInfo(Args);
    if (info != .@"struct") return Args;
    const fields = info.@"struct".fields;
    var names: [fields.len][:0]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var lowered = false;
    for (fields, &names, &types) |field, *name, *Bound| {
        Bound.* = BoundType(field.type);
        if (Bound.* != field.type) lowered = true;
        name.* = field.name;
    }
    if (!lowered) return Args;
    const frozen_names = names;
    const frozen_types = types;
    if (info.@"struct".is_tuple) return @Tuple(&frozen_types);
    return @Struct(.auto, null, &frozen_names, &frozen_types, &@splat(.{}));
}

pub fn bindArgs(args: anytype) BoundArgs(@TypeOf(args)) {
    const Args = @TypeOf(args);
    const Bound = BoundArgs(Args);
    if (Bound == Args) return args;
    var bound: Bound = undefined;
    inline for (@typeInfo(Args).@"struct".fields) |field|
        @field(bound, field.name) = bindValue(field.type, @field(args, field.name));
    return bound;
}

fn BoundType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"enum" => switch (enumStorage(T)) {
            .integer => i64,
            .text => []const u8,
        },
        .optional => |optional| blk: {
            const Bound = BoundType(optional.child);
            break :blk if (Bound == optional.child) T else ?Bound;
        },
        else => T,
    };
}

fn bindValue(comptime T: type, value: T) BoundType(T) {
    return switch (@typeInfo(T)) {
        .@"enum" => switch (comptime enumStorage(T)) {
            .integer => @intCast(@intFromEnum(value)),
            .text => @tagName(value),
        },
        .optional => |optional| if (value) |inner| bindValue(optional.child, inner) else null,
        else => value,
    };
}

/// Convenience for call sites that only need to know whether an operation
/// worked: it releases the error payload and reports `error.SqlzFailed`.
/// Anything that acts on the class, code, or message must switch on the
/// `Result` itself instead — that is where the diagnosis lives.
pub fn unwrap(result: anytype) error{SqlzFailed}!@TypeOf(result.ok) {
    return switch (result) {
        .ok => |value| value,
        .err => |*err| {
            var owned = err.*;
            owned.deinit();
            return error.SqlzFailed;
        },
    };
}

pub fn cloneRow(allocator: std.mem.Allocator, value: anytype) !@TypeOf(value) {
    return cloneValue(allocator, @TypeOf(value), value);
}

fn cloneValue(allocator: std.mem.Allocator, comptime T: type, value: T) !T {
    if (comptime byteSlice(T)) |pointer| {
        if (comptime pointer.sentinel()) |terminator| {
            const copy = try allocator.allocSentinel(u8, value.len, terminator);
            @memcpy(copy, value);
            return copy;
        }
        return try allocator.dupe(u8, value);
    }
    return switch (@typeInfo(T)) {
        .optional => |optional| if (value) |inner| try cloneValue(allocator, optional.child, inner) else null,
        .pointer => |pointer| if (pointer.size == .slice) blk: {
            const Mutable = []pointer.child;
            const copy: Mutable = try allocator.alloc(pointer.child, value.len);
            var initialized: usize = 0;
            errdefer {
                for (copy[0..initialized]) |item| deinitValue(allocator, pointer.child, item);
                allocator.free(copy);
            }
            for (value, copy) |item, *destination| {
                destination.* = try cloneValue(allocator, pointer.child, item);
                initialized += 1;
            }
            break :blk copy;
        } else value,
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.fields, 0..) |field, index| {
                // A later field failing to allocate must not strand the fields
                // already copied, so unwind exactly the prefix that succeeded.
                errdefer inline for (info.fields[0..index]) |copied|
                    deinitValue(allocator, copied.type, @field(result, copied.name));
                @field(result, field.name) = try cloneValue(allocator, field.type, @field(value, field.name));
            }
            break :blk result;
        },
        else => value,
    };
}

/// Describes `T` when it is a slice of bytes, including sentinel-terminated
/// spellings such as `[:0]const u8` that SQLite can decode into a row.
fn byteSlice(comptime T: type) ?std.builtin.Type.Pointer {
    const info = @typeInfo(T);
    if (info != .pointer) return null;
    const pointer = info.pointer;
    if (pointer.size != .slice or pointer.child != u8) return null;
    return pointer;
}

pub fn deinitOwnedRow(allocator: std.mem.Allocator, value: anytype) void {
    deinitValue(allocator, @TypeOf(value.*), value.*);
}

fn deinitValue(allocator: std.mem.Allocator, comptime T: type, value: T) void {
    if (comptime byteSlice(T) != null) {
        allocator.free(value);
        return;
    }
    switch (@typeInfo(T)) {
        .optional => |optional| if (value) |inner| deinitValue(allocator, optional.child, inner),
        .pointer => |pointer| if (pointer.size == .slice) {
            for (value) |item| deinitValue(allocator, pointer.child, item);
            allocator.free(value);
        },
        .@"struct" => |info| inline for (info.fields) |field|
            deinitValue(allocator, field.type, @field(value, field.name)),
        else => {},
    }
}
