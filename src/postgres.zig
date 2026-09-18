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

    pub const Ownership = enum { owned, borrowed };

    pub const Conn = struct {
        pub const backend: Backend = .postgres;

        allocator: std.mem.Allocator,
        io: std.Io,
        conn: *pg.Conn,
        ownership: Ownership,
        row_allocator: ?std.mem.Allocator = null,
        row_free: bool = true,

        pub fn deinit(self: *Conn) void {
            if (self.ownership == .owned) {
                self.conn.deinit();
                self.allocator.destroy(self.conn);
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
            const affected = self.conn.exec(sql, positionalArgs(args)) catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .execute, cause) };
            return .{ .ok = .{ .rows_affected = if (affected) |value| @intCast(value) else null } };
        }

        pub fn executeScript(self: *Conn, sql: []const u8) Result(void) {
            _ = self.conn.exec(sql, .{}) catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .execute, cause) };
            return .{ .ok = {} };
        }

        pub fn fetchOne(self: *Conn, comptime Row: type, sql: []const u8, args: anytype) Result(Single(Row)) {
            const native = self.conn.row(sql, positionalArgs(args)) catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .fetch, cause) };
            const row = native orelse return .{ .err = staticError(.invalid_data, .fetch, "query expected one row but returned none") };
            const value = decodeRow(Row, &row) catch |cause| {
                deinitQueryRow(&row);
                return .{ .err = decodeError(cause) };
            };
            return .{ .ok = .{
                .native = row,
                .value = value,
                .row_allocator = self.row_allocator,
                .row_free = self.row_free,
            } };
        }

        pub fn fetchOptional(self: *Conn, comptime Row: type, sql: []const u8, args: anytype) Result(?Single(Row)) {
            const native = self.conn.row(sql, positionalArgs(args)) catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .fetch, cause) };
            const row = native orelse return .{ .ok = null };
            const value = decodeRow(Row, &row) catch |cause| {
                deinitQueryRow(&row);
                return .{ .err = decodeError(cause) };
            };
            return .{ .ok = .{
                .native = row,
                .value = value,
                .row_allocator = self.row_allocator,
                .row_free = self.row_free,
            } };
        }

        pub fn fetch(self: *Conn, comptime Row: type, sql: []const u8, args: anytype) Result(Rows(Row)) {
            const native = self.conn.query(sql, positionalArgs(args)) catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .fetch, cause) };
            return .{ .ok = .{
                .allocator = self.allocator,
                .connection = self.conn,
                .native = native,
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
            connection: *pg.Conn,
            native: *pg.Result,
            finished: bool = false,
            row_allocator: ?std.mem.Allocator,
            row_free: bool,

            pub fn next(self: *@This()) Result(?Row) {
                if (self.finished) return .{ .ok = null };
                const native_row = self.native.next() catch |cause|
                    return .{ .err = makeError(self.allocator, self.connection, .iterate, cause) };
                const row = native_row orelse {
                    self.finished = true;
                    return .{ .ok = null };
                };
                const value = decodePgRow(Row, &row) catch |cause|
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
                    return .{ .err = makeError(self.allocator, self.connection, .iterate, cause) };
                self.finished = true;
                return .{ .ok = {} };
            }

            pub fn deinit(self: *@This()) void {
                if (!self.finished) self.native.drain() catch {};
                self.native.deinit();
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

    fn decodeRow(comptime Row: type, native: *const pg.QueryRow) DecodeError!Row {
        var value: Row = undefined;
        inline for (@typeInfo(Row).@"struct".fields, 0..) |field, index|
            @field(value, field.name) = try decodeField(field.type, native, index);
        return value;
    }

    fn deinitQueryRow(native: *pg.QueryRow) void {
        native.result.drain() catch {};
        native.result.deinit();
    }

    fn decodePgRow(comptime Row: type, native: *const pg.Row) DecodeError!Row {
        var value: Row = undefined;
        inline for (@typeInfo(Row).@"struct".fields, 0..) |field, index|
            @field(value, field.name) = try decodeField(field.type, native, index);
        return value;
    }

    fn decodeField(comptime T: type, native: anytype, index: usize) DecodeError!T {
        return switch (@typeInfo(T)) {
            .@"enum" => decodeEnum(T, native, index),
            .optional => |optional| switch (@typeInfo(optional.child)) {
                .@"enum" => decodeOptionalEnum(optional.child, native, index),
                else => try native.get(T, index),
            },
            else => try native.get(T, index),
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

    fn positionalArgs(args: anytype) PositionalArgs(@TypeOf(args)) {
        const Args = @TypeOf(args);
        const fields = @typeInfo(Args).@"struct".fields;
        var result: PositionalArgs(Args) = undefined;
        inline for (fields, 0..) |field, index|
            result[index] = lowerValue(field.type, @field(args, field.name));
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
            else => T,
        };
    }

    fn lowerValue(comptime T: type, value: T) LowerType(T) {
        return switch (@typeInfo(T)) {
            .@"enum" => switch (comptime core.enumStorage(T)) {
                .integer => @intFromEnum(value),
                .text => @tagName(value),
            },
            .optional => |optional| if (value) |inner| lowerValue(optional.child, inner) else null,
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
