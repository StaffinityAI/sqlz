const std = @import("std");
const pg = @import("pg");
const core = @import("sqlz_core");

pub const Backends = core.Backends;
pub const Cardinality = core.Cardinality;
pub const ExecResult = core.ExecResult;
pub const ErrorClass = core.ErrorClass;
pub const Backend = core.Backend;
pub const Error = core.Error;
pub const Operation = core.Operation;
pub const Result = core.Result;
pub const Query = core.Query;
pub const unwrap = core.unwrap;
pub const cloneRow = core.cloneRow;
pub const deinitOwnedRow = core.deinitOwnedRow;
pub const Storage = core.Storage;

pub fn assertCodec(comptime T: type) void {
    if (@typeInfo(T) != .@"enum") @compileError(
        "sqlz codec '" ++ @typeName(T) ++
            "' is not supported yet: only Zig enums are derived in this slice",
    );
}

pub const postgres = struct {
    pub const OpenOptions = struct {
        connect: pg.Conn.Opts = .{},
        auth: pg.Conn.AuthOpts = .{},
    };

    pub const Ownership = enum { owned, borrowed, pooled };

    pub const Conn = struct {
        pub const backend: Backend = .postgres;

        allocator: std.mem.Allocator,
        io: std.Io,
        conn: *pg.Conn,
        ownership: Ownership,
        row_allocator: ?std.mem.Allocator = null,
        row_free: bool = true,

        pub fn deinit(self: *Conn) void {
            switch (self.ownership) {
                .owned => {
                    self.conn.deinit();
                    self.allocator.destroy(self.conn);
                },
                .borrowed => {},
                .pooled => self.conn.release(),
            }
            self.* = undefined;
        }

        pub fn raw(self: *Conn) *pg.Conn {
            return self.conn;
        }

        pub fn ownedScope(self: *Conn, allocator: std.mem.Allocator, options: ScopeOptions) OwnedScope {
            const scope: OwnedScope = .{
                .connection = self,
                .previous_allocator = self.row_allocator,
                .previous_free = self.row_free,
            };
            self.row_allocator = allocator;
            self.row_free = options.free_rows;
            return scope;
        }

        pub fn begin(self: *Conn, _: BeginOptions) Result(Transaction) {
            self.conn.begin() catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .transaction, cause) };
            return .{ .ok = .{ .connection = self } };
        }

        pub fn execute(self: *Conn, sql: []const u8, args: anytype) Result(ExecResult) {
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const bound = positionalArgs(arena.allocator(), args) catch
                return .{ .err = staticError(.other, .execute, "unable to lower PostgreSQL parameters") };
            const affected = self.conn.exec(sql, bound) catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .execute, cause) };
            return .{ .ok = .{ .rows_affected = if (affected) |value| @intCast(value) else null } };
        }

        pub fn executeScript(self: *Conn, sql: []const u8) Result(void) {
            _ = self.conn.exec(sql, .{}) catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .execute, cause) };
            return .{ .ok = {} };
        }

        pub fn fetchOne(self: *Conn, comptime Row: type, sql: []const u8, args: anytype) Result(Single(Row)) {
            var bind_arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer bind_arena.deinit();
            const bound = positionalArgs(bind_arena.allocator(), args) catch
                return .{ .err = staticError(.other, .fetch, "unable to lower PostgreSQL parameters") };
            const native = self.conn.row(sql, bound) catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .fetch, cause) };
            var row = native orelse return .{ .err = staticError(.invalid_data, .fetch, "query expected one row but returned none") };
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            const value = decodeRow(Row, &row, arena.allocator()) catch |cause| {
                arena.deinit();
                deinitQueryRow(&row);
                return .{ .err = decodeError(cause) };
            };
            return .{ .ok = .{
                .native = row,
                .arena = arena,
                .value = value,
                .row_allocator = self.row_allocator,
                .row_free = self.row_free,
            } };
        }

        pub fn fetchOptional(self: *Conn, comptime Row: type, sql: []const u8, args: anytype) Result(?Single(Row)) {
            var bind_arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer bind_arena.deinit();
            const bound = positionalArgs(bind_arena.allocator(), args) catch
                return .{ .err = staticError(.other, .fetch, "unable to lower PostgreSQL parameters") };
            const native = self.conn.row(sql, bound) catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .fetch, cause) };
            var row = native orelse return .{ .ok = null };
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            const value = decodeRow(Row, &row, arena.allocator()) catch |cause| {
                arena.deinit();
                deinitQueryRow(&row);
                return .{ .err = decodeError(cause) };
            };
            return .{ .ok = .{
                .native = row,
                .arena = arena,
                .value = value,
                .row_allocator = self.row_allocator,
                .row_free = self.row_free,
            } };
        }

        pub fn fetch(self: *Conn, comptime Row: type, sql: []const u8, args: anytype) Result(Rows(Row)) {
            var bind_arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer bind_arena.deinit();
            const bound = positionalArgs(bind_arena.allocator(), args) catch
                return .{ .err = staticError(.other, .fetch, "unable to lower PostgreSQL parameters") };
            const native = self.conn.query(sql, bound) catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .fetch, cause) };
            return .{ .ok = .{
                .allocator = self.allocator,
                .connection = self.conn,
                .native = native,
                .arena = .init(self.allocator),
                .row_allocator = self.row_allocator,
                .row_free = self.row_free,
            } };
        }
    };

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: OpenOptions,
    ) !Conn {
        const native = try allocator.create(pg.Conn);
        errdefer allocator.destroy(native);
        native.* = try pg.Conn.openAndAuth(io, allocator, options.connect, options.auth);
        return .{
            .allocator = allocator,
            .io = io,
            .conn = native,
            .ownership = .owned,
        };
    }

    pub fn borrow(allocator: std.mem.Allocator, io: std.Io, native: *pg.Conn) Conn {
        return .{
            .allocator = allocator,
            .io = io,
            .conn = native,
            .ownership = .borrowed,
        };
    }

    pub const PoolOptions = pg.Pool.Opts;

    pub const Pool = struct {
        pub const backend: Backend = .postgres;

        allocator: std.mem.Allocator,
        io: std.Io,
        pool: *pg.Pool,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            options: PoolOptions,
        ) !Pool {
            return .{
                .allocator = allocator,
                .io = io,
                .pool = try pg.Pool.init(io, allocator, options),
            };
        }

        pub fn deinit(self: *Pool) void {
            self.pool.deinit();
            self.* = undefined;
        }

        pub fn acquire(self: *Pool) !Conn {
            return .{
                .allocator = self.allocator,
                .io = self.io,
                .conn = try self.pool.acquire(),
                .ownership = .pooled,
            };
        }

        pub fn execute(self: *Pool, sql: []const u8, args: anytype) Result(ExecResult) {
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const bound = positionalArgs(arena.allocator(), args) catch
                return .{ .err = staticError(.other, .execute, "unable to lower PostgreSQL parameters") };
            const affected = self.pool.exec(sql, bound) catch |cause|
                return .{ .err = poolError(.execute, cause) };
            return .{ .ok = .{ .rows_affected = if (affected) |value| @intCast(value) else null } };
        }

        pub fn executeScript(self: *Pool, sql: []const u8) Result(void) {
            _ = self.pool.exec(sql, .{}) catch |cause|
                return .{ .err = poolError(.execute, cause) };
            return .{ .ok = {} };
        }

        pub fn fetchOne(self: *Pool, comptime Row: type, sql: []const u8, args: anytype) Result(Single(Row)) {
            var bind_arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer bind_arena.deinit();
            const bound = positionalArgs(bind_arena.allocator(), args) catch
                return .{ .err = staticError(.other, .fetch, "unable to lower PostgreSQL parameters") };
            const native = self.pool.row(sql, bound) catch |cause|
                return .{ .err = poolError(.fetch, cause) };
            var row = native orelse return .{ .err = staticError(.invalid_data, .fetch, "query expected one row but returned none") };
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            const value = decodeRow(Row, &row, arena.allocator()) catch |cause| {
                arena.deinit();
                deinitQueryRow(&row);
                return .{ .err = decodeError(cause) };
            };
            return .{ .ok = .{
                .native = row,
                .arena = arena,
                .value = value,
                .row_allocator = null,
                .row_free = true,
            } };
        }

        pub fn fetchOptional(self: *Pool, comptime Row: type, sql: []const u8, args: anytype) Result(?Single(Row)) {
            var bind_arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer bind_arena.deinit();
            const bound = positionalArgs(bind_arena.allocator(), args) catch
                return .{ .err = staticError(.other, .fetch, "unable to lower PostgreSQL parameters") };
            const native = self.pool.row(sql, bound) catch |cause|
                return .{ .err = poolError(.fetch, cause) };
            var row = native orelse return .{ .ok = null };
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            const value = decodeRow(Row, &row, arena.allocator()) catch |cause| {
                arena.deinit();
                deinitQueryRow(&row);
                return .{ .err = decodeError(cause) };
            };
            return .{ .ok = .{
                .native = row,
                .arena = arena,
                .value = value,
                .row_allocator = null,
                .row_free = true,
            } };
        }

        pub fn fetch(self: *Pool, comptime Row: type, sql: []const u8, args: anytype) Result(Rows(Row)) {
            var bind_arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer bind_arena.deinit();
            const bound = positionalArgs(bind_arena.allocator(), args) catch
                return .{ .err = staticError(.other, .fetch, "unable to lower PostgreSQL parameters") };
            const native = self.pool.query(sql, bound) catch |cause|
                return .{ .err = poolError(.fetch, cause) };
            return .{ .ok = .{
                .allocator = self.allocator,
                .connection = null,
                .native = native,
                .arena = .init(self.allocator),
                .row_allocator = null,
                .row_free = true,
            } };
        }

        pub fn raw(self: *Pool) *pg.Pool {
            return self.pool;
        }

        pub fn stats(self: *Pool) pg.Pool.Stats {
            return self.pool.stats();
        }
    };

    pub const ScopeOptions = struct { free_rows: bool = true };

    pub const OwnedScope = struct {
        connection: *Conn,
        previous_allocator: ?std.mem.Allocator,
        previous_free: bool,

        pub fn deinit(self: *OwnedScope) void {
            self.connection.row_allocator = self.previous_allocator;
            self.connection.row_free = self.previous_free;
            self.* = undefined;
        }
    };

    pub const BeginOptions = struct {};

    pub const Transaction = struct {
        pub const backend: Backend = .postgres;

        connection: *Conn,
        active: bool = true,

        pub fn execute(self: *Transaction, sql: []const u8, args: anytype) Result(ExecResult) {
            return self.connection.execute(sql, args);
        }

        pub fn executeScript(self: *Transaction, sql: []const u8) Result(void) {
            return self.connection.executeScript(sql);
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

        pub fn commit(self: *Transaction) Result(void) {
            if (!self.active) return .{ .err = staticError(.invalid_data, .transaction, "transaction is no longer active") };
            self.connection.conn.commit() catch |cause|
                return .{ .err = makeError(self.connection.allocator, self.connection.conn, .transaction, cause) };
            self.active = false;
            return .{ .ok = {} };
        }

        pub fn rollback(self: *Transaction) Result(void) {
            if (!self.active) return .{ .err = staticError(.invalid_data, .transaction, "transaction is no longer active") };
            self.connection.conn.rollback() catch |cause|
                return .{ .err = makeError(self.connection.allocator, self.connection.conn, .transaction, cause) };
            self.active = false;
            return .{ .ok = {} };
        }

        pub fn deinit(self: *Transaction) void {
            if (self.active) self.connection.conn.rollback() catch {};
            self.* = undefined;
        }

        pub fn raw(self: *Transaction) *pg.Conn {
            return self.connection.conn;
        }

        pub fn io(self: *Transaction) std.Io {
            return self.connection.io;
        }
    };

    pub fn Single(comptime Row: type) type {
        return struct {
            native: pg.QueryRow,
            arena: std.heap.ArenaAllocator,
            value: Row,
            row_allocator: ?std.mem.Allocator,
            row_free: bool,

            pub fn row(self: *@This()) Row {
                return self.value;
            }

            pub fn toOwned(self: *@This(), allocator: ?std.mem.Allocator) Result(Owned(Row)) {
                const target = ownedTarget(allocator, self.row_allocator, self.row_free) orelse
                    return .{ .err = missingOwnedAllocator() };
                const value = cloneRow(target.allocator, self.value) catch
                    return .{ .err = ownedAllocationFailed() };
                return .{ .ok = .{
                    .allocator = if (target.free) target.allocator else null,
                    .value = value,
                } };
            }

            pub fn deinit(self: *@This()) void {
                deinitQueryRow(&self.native);
                self.arena.deinit();
                self.* = undefined;
            }
        };
    }

    pub fn Owned(comptime Row: type) type {
        return struct {
            allocator: ?std.mem.Allocator,
            value: Row,

            pub fn row(self: *@This()) Row {
                return self.value;
            }

            pub fn deinit(self: *@This()) void {
                if (self.allocator) |allocator| deinitOwnedRow(allocator, &self.value);
                self.* = undefined;
            }
        };
    }

    pub fn OwnedRows(comptime Row: type) type {
        return struct {
            allocator: std.mem.Allocator,
            free_rows: bool,
            items: []Row,

            pub fn deinit(self: *@This()) void {
                if (self.free_rows) {
                    for (self.items) |*item| deinitOwnedRow(self.allocator, item);
                    self.allocator.free(self.items);
                }
                self.* = undefined;
            }
        };
    }

    pub fn Rows(comptime Row: type) type {
        return struct {
            allocator: std.mem.Allocator,
            connection: ?*pg.Conn,
            native: *pg.Result,
            arena: std.heap.ArenaAllocator,
            finished: bool = false,
            row_allocator: ?std.mem.Allocator,
            row_free: bool,

            pub fn next(self: *@This()) Result(?Row) {
                if (self.finished) return .{ .ok = null };
                const native_row = self.native.next() catch |cause|
                    return .{ .err = if (self.connection) |connection|
                        makeError(self.allocator, connection, .iterate, cause)
                    else
                        poolError(.iterate, cause) };
                const row = native_row orelse {
                    self.finished = true;
                    return .{ .ok = null };
                };
                _ = self.arena.reset(.retain_capacity);
                const value = decodePgRow(Row, &row, self.arena.allocator()) catch |cause|
                    return .{ .err = decodeError(cause) };
                return .{ .ok = value };
            }

            pub fn nextOwned(self: *@This(), allocator: ?std.mem.Allocator) Result(?Owned(Row)) {
                const target = ownedTarget(allocator, self.row_allocator, self.row_free) orelse
                    return .{ .err = missingOwnedAllocator() };
                switch (self.next()) {
                    .err => |err| return .{ .err = err },
                    .ok => |maybe_row| {
                        const row = maybe_row orelse return .{ .ok = null };
                        const value = cloneRow(target.allocator, row) catch
                            return .{ .err = ownedAllocationFailed() };
                        return .{ .ok = .{
                            .allocator = if (target.free) target.allocator else null,
                            .value = value,
                        } };
                    },
                }
            }

            pub fn collectOwned(self: *@This(), allocator: ?std.mem.Allocator) Result(OwnedRows(Row)) {
                const target = ownedTarget(allocator, self.row_allocator, self.row_free) orelse
                    return .{ .err = missingOwnedAllocator() };
                var items: std.ArrayList(Row) = .empty;
                while (true) switch (self.next()) {
                    .err => |err| {
                        releaseCollected(&items, target);
                        return .{ .err = err };
                    },
                    .ok => |maybe_row| {
                        const row = maybe_row orelse break;
                        var value = cloneRow(target.allocator, row) catch {
                            releaseCollected(&items, target);
                            return .{ .err = ownedAllocationFailed() };
                        };
                        items.append(target.allocator, value) catch {
                            if (target.free) deinitOwnedRow(target.allocator, &value);
                            releaseCollected(&items, target);
                            return .{ .err = ownedAllocationFailed() };
                        };
                    },
                };
                const owned = items.toOwnedSlice(target.allocator) catch {
                    releaseCollected(&items, target);
                    return .{ .err = ownedAllocationFailed() };
                };
                return .{ .ok = .{
                    .allocator = target.allocator,
                    .free_rows = target.free,
                    .items = owned,
                } };
            }

            pub fn drain(self: *@This()) Result(void) {
                self.native.drain() catch |cause|
                    return .{ .err = if (self.connection) |connection|
                        makeError(self.allocator, connection, .iterate, cause)
                    else
                        poolError(.iterate, cause) };
                self.finished = true;
                return .{ .ok = {} };
            }

            pub fn deinit(self: *@This()) void {
                if (!self.finished) self.native.drain() catch {};
                self.native.deinit();
                self.arena.deinit();
                self.* = undefined;
            }

            fn releaseCollected(items: *std.ArrayList(Row), target: OwnedTarget) void {
                if (target.free) for (items.items) |*item| deinitOwnedRow(target.allocator, item);
                items.deinit(target.allocator);
            }
        };
    }

    const OwnedTarget = struct { allocator: std.mem.Allocator, free: bool };

    fn ownedTarget(explicit: ?std.mem.Allocator, scoped: ?std.mem.Allocator, scope_free: bool) ?OwnedTarget {
        if (explicit) |allocator| return .{ .allocator = allocator, .free = true };
        return .{ .allocator = scoped orelse return null, .free = scope_free };
    }

    fn missingOwnedAllocator() Error {
        return staticError(.invalid_data, .fetch, "no owned-row allocator: pass one to toOwned or open conn.ownedScope");
    }

    fn ownedAllocationFailed() Error {
        return staticError(.other, .fetch, "unable to allocate owned row");
    }

    const DecodeError = error{
        InvalidType,
        UnexpectedNull,
        UnknownColumnName,
        InvalidEnumTag,
    };

    fn decodeRow(comptime Row: type, native: *const pg.QueryRow, allocator: std.mem.Allocator) !Row {
        var value: Row = undefined;
        inline for (@typeInfo(Row).@"struct".fields, 0..) |field, index|
            @field(value, field.name) = try decodeField(field.type, native, index, allocator);
        return value;
    }

    fn deinitQueryRow(native: *pg.QueryRow) void {
        native.result.drain() catch {};
        native.result.deinit();
    }

    fn decodePgRow(comptime Row: type, native: *const pg.Row, allocator: std.mem.Allocator) !Row {
        var value: Row = undefined;
        inline for (@typeInfo(Row).@"struct".fields, 0..) |field, index|
            @field(value, field.name) = try decodeField(field.type, native, index, allocator);
        return value;
    }

    fn decodeField(comptime T: type, native: anytype, index: usize, allocator: std.mem.Allocator) !T {
        return switch (@typeInfo(T)) {
            .@"enum" => decodeEnum(T, native, index),
            .optional => |optional| switch (@typeInfo(optional.child)) {
                .@"enum" => decodeOptionalEnum(optional.child, native, index),
                .pointer => |pointer| if (pointer.size == .slice and pointer.child != u8)
                    try decodeOptionalArray(optional.child, native, index, allocator)
                else
                    try native.get(T, index),
                else => try native.get(T, index),
            },
            .pointer => |pointer| if (pointer.size == .slice and pointer.child != u8)
                try decodeArray(T, native, index, allocator)
            else
                try native.get(T, index),
            else => try native.get(T, index),
        };
    }

    fn decodeArray(comptime T: type, native: anytype, index: usize, allocator: std.mem.Allocator) !T {
        const Element = @typeInfo(T).pointer.child;
        const DriverElement = DriverArrayElement(Element);
        var iterator = try native.iterator(DriverElement, index);
        const driver_values = try iterator.alloc(allocator);
        if (DriverElement == Element) return driver_values;
        const values = try allocator.alloc(Element, driver_values.len);
        for (driver_values, values) |driver_value, *value|
            value.* = try restoreArrayElement(Element, driver_value);
        return values;
    }

    fn decodeOptionalArray(comptime T: type, native: anytype, index: usize, allocator: std.mem.Allocator) !?T {
        const Element = @typeInfo(T).pointer.child;
        const DriverElement = DriverArrayElement(Element);
        var iterator = try native.iterator(DriverElement, index);
        if (iterator.is_null) return null;
        const driver_values = try iterator.alloc(allocator);
        if (DriverElement == Element) return driver_values;
        const values = try allocator.alloc(Element, driver_values.len);
        for (driver_values, values) |driver_value, *value|
            value.* = try restoreArrayElement(Element, driver_value);
        return values;
    }

    fn DriverArrayElement(comptime T: type) type {
        return switch (@typeInfo(T)) {
            .optional => |optional| ?DriverArrayElement(optional.child),
            .@"enum" => switch (comptime core.enumStorage(T)) {
                .integer => std.meta.Tag(T),
                .text => T,
            },
            else => T,
        };
    }

    fn restoreArrayElement(comptime T: type, value: DriverArrayElement(T)) !T {
        return switch (@typeInfo(T)) {
            .optional => |optional| if (value) |inner|
                try restoreArrayElement(optional.child, inner)
            else
                null,
            .@"enum" => switch (comptime core.enumStorage(T)) {
                .integer => std.meta.intToEnum(T, value) catch error.InvalidEnumTag,
                .text => value,
            },
            else => value,
        };
    }

    fn decodeEnum(comptime T: type, native: anytype, index: usize) DecodeError!T {
        return switch (comptime core.enumStorage(T)) {
            .integer => std.meta.intToEnum(T, try native.get(std.meta.Tag(T), index)) catch error.InvalidEnumTag,
            .text => std.meta.stringToEnum(T, try native.get([]const u8, index)) orelse error.InvalidEnumTag,
        };
    }

    fn decodeOptionalEnum(comptime T: type, native: anytype, index: usize) DecodeError!?T {
        return switch (comptime core.enumStorage(T)) {
            .integer => {
                const tag = try native.get(?std.meta.Tag(T), index) orelse return null;
                return std.meta.intToEnum(T, tag) catch error.InvalidEnumTag;
            },
            .text => {
                const name = try native.get(?[]const u8, index) orelse return null;
                return std.meta.stringToEnum(T, name) orelse error.InvalidEnumTag;
            },
        };
    }

    fn positionalArgs(allocator: std.mem.Allocator, args: anytype) !PositionalArgs(@TypeOf(args)) {
        const Args = @TypeOf(args);
        const fields = @typeInfo(Args).@"struct".fields;
        var result: PositionalArgs(Args) = undefined;
        inline for (fields, 0..) |field, index|
            result[index] = try lowerValue(allocator, field.type, @field(args, field.name));
        return result;
    }

    fn PositionalArgs(comptime Args: type) type {
        const fields = @typeInfo(Args).@"struct".fields;
        var types: [fields.len]type = undefined;
        for (fields, &types) |field, *T| T.* = LowerType(field.type);
        return @Tuple(&types);
    }

    fn LowerType(comptime T: type) type {
        return switch (@typeInfo(T)) {
            .@"enum" => switch (comptime core.enumStorage(T)) {
                .integer => std.meta.Tag(T),
                .text => []const u8,
            },
            .optional => |optional| ?LowerType(optional.child),
            .pointer => |pointer| if (pointer.size == .slice and pointer.child != u8)
                []const LowerType(pointer.child)
            else
                T,
            else => T,
        };
    }

    fn lowerValue(allocator: std.mem.Allocator, comptime T: type, value: T) !LowerType(T) {
        return switch (@typeInfo(T)) {
            .@"enum" => switch (comptime core.enumStorage(T)) {
                .integer => @intFromEnum(value),
                .text => @tagName(value),
            },
            .optional => |optional| if (value) |inner| try lowerValue(allocator, optional.child, inner) else null,
            .pointer => |pointer| if (pointer.size == .slice and pointer.child != u8) blk: {
                if (LowerType(pointer.child) == pointer.child) break :blk value;
                const lowered = try allocator.alloc(LowerType(pointer.child), value.len);
                for (value, lowered) |item, *destination|
                    destination.* = try lowerValue(allocator, pointer.child, item);
                break :blk lowered;
            } else value,
            else => value,
        };
    }

    fn decodeError(cause: anyerror) Error {
        return staticError(.invalid_data, .fetch, @errorName(cause));
    }

    fn makeError(allocator: std.mem.Allocator, native: *pg.Conn, operation: Operation, cause: anyerror) Error {
        if (native.err) |postgres_error| {
            const message = allocator.dupe(u8, postgres_error.message) catch return staticError(classifySqlState(postgres_error.code), operation, postgres_error.message);
            return .{
                .allocator = allocator,
                .class = classifySqlState(postgres_error.code),
                .backend = .postgres,
                .operation = operation,
                .message = message,
            };
        }
        return staticError(classify(cause), operation, @errorName(cause));
    }

    fn staticError(class: ErrorClass, operation: Operation, message: []const u8) Error {
        return .{ .class = class, .backend = .postgres, .operation = operation, .message = message };
    }

    fn poolError(operation: Operation, cause: anyerror) Error {
        return staticError(classify(cause), operation, @errorName(cause));
    }

    fn classifySqlState(code: []const u8) ErrorClass {
        if (code.len >= 2 and std.mem.eql(u8, code[0..2], "23")) return .constraint;
        if (std.mem.eql(u8, code, "57014")) return .cancelled;
        if (code.len >= 2 and std.mem.eql(u8, code[0..2], "08")) return .unavailable;
        return .other;
    }

    fn classify(cause: anyerror) ErrorClass {
        return switch (cause) {
            error.Timeout => .timeout,
            error.ConnectionRefused, error.ConnectionResetByPeer, error.BrokenPipe, error.EndOfStream => .unavailable,
            error.InvalidType, error.UnexpectedNull, error.UnknownColumnName, error.InvalidEnumTag => .invalid_data,
            else => .other,
        };
    }
};

test "PostgreSQL array lowering preserves nulls and enum storage" {
    const IntegerRole = enum(i32) { member, admin };
    const TextRole = enum {
        member,
        admin,
        pub const sqlz_storage: Storage = .text;
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const integer_roles = [_]?IntegerRole{ .member, null, .admin };
    const lowered_integer = try postgres.lowerValue(arena.allocator(), []const ?IntegerRole, &integer_roles);
    try std.testing.expectEqual(@as(?i32, 0), lowered_integer[0]);
    try std.testing.expect(lowered_integer[1] == null);
    try std.testing.expectEqual(@as(?i32, 1), lowered_integer[2]);

    const text_roles = [_]?TextRole{ .admin, null };
    const lowered_text = try postgres.lowerValue(arena.allocator(), []const ?TextRole, &text_roles);
    try std.testing.expectEqualStrings("admin", lowered_text[0].?);
    try std.testing.expect(lowered_text[1] == null);

    try std.testing.expectEqual(
        IntegerRole.admin,
        try postgres.restoreArrayElement(IntegerRole, @as(i32, 1)),
    );
    try std.testing.expectEqual(
        @as(?IntegerRole, null),
        try postgres.restoreArrayElement(?IntegerRole, @as(?i32, null)),
    );
}
