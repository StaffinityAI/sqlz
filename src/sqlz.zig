const std = @import("std");
const zqlite = @import("zqlite");
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
pub const cloneRow = core.cloneRow;
pub const deinitOwnedRow = core.deinitOwnedRow;

pub const Blob = zqlite.Blob;
pub const blob = zqlite.blob;

pub const sqlite = struct {
    pub const Conn = struct {
        allocator: std.mem.Allocator,
        /// Retained from initialization so every handle derived from this
        /// connection reaches the same `std.Io` implementation the caller
        /// selected. SQLite itself is a blocking in-process library, but the
        /// executor interface is shared with backends that do perform I/O.
        io: std.Io,
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
            return .{ .ok = .{ .allocator = self.allocator, .io = self.io, .conn = self.conn, .native = native } };
        }
    };

    /// Opens an owned SQLite connection. `io` is the `std.Io` implementation
    /// the application runs on (`std.Io.Threaded`, or a third-party runtime
    /// such as zio); it is stored on the connection rather than passed per
    /// call so generated bindings keep a single executor argument.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Conn {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const conn = try zqlite.open(path_z.ptr, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
        return .{ .allocator = allocator, .io = io, .conn = conn };
    }

    /// Wraps a connection the caller continues to own; `deinit` never closes it.
    pub fn borrow(allocator: std.mem.Allocator, io: std.Io, conn: zqlite.Conn) Conn {
        return .{ .allocator = allocator, .io = io, .conn = conn, .owned = false };
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
            /// Streaming iterators outlive the call that produced them, so they
            /// carry the connection's interface rather than reaching back for
            /// it. A SQLite cursor never uses it; a PostgreSQL cursor advances
            /// over a socket and will.
            io: std.Io,
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

        pub fn io(self: *Transaction) std.Io {
            return self.connection.io;
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
