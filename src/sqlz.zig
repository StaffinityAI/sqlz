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
pub const Storage = core.Storage;

/// Compile-time contract for a codec declaration the build registered. This
/// slice derives codecs for Zig enums only: sqlz converts them through their
/// stored representation, so no hand-written encode/decode pair is needed.
/// Any other declaration is rejected here rather than at the first query.
pub fn assertCodec(comptime T: type) void {
    if (@typeInfo(T) != .@"enum") @compileError(
        "sqlz codec '" ++ @typeName(T) ++
            "' is not supported yet: only Zig enums are derived in this slice",
    );
}

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
        /// `owned` closes the handle, `borrowed` leaves it to the caller, and
        /// `pooled` returns it to the pool it came from.
        ownership: Ownership = .owned,
        pool: ?*Pool = null,
        /// Allocator the current owned-row scope hands to `toOwned` when the
        /// caller does not name one. `row_free` records whether rows taken from
        /// that scope own their memory: an arena releases everything at once,
        /// so its rows must not free field by field.
        row_allocator: ?std.mem.Allocator = null,
        row_free: bool = true,

        pub fn deinit(self: *Conn) void {
            switch (self.ownership) {
                .owned => self.conn.close(),
                .borrowed => {},
                .pooled => self.conn.release(self.io),
            }
            self.* = undefined;
        }

        pub fn raw(self: *Conn) zqlite.Conn {
            return self.conn;
        }

        /// Directs allocator-less `toOwned` calls on this connection at
        /// `allocator` until the returned scope is deinitialized. Scopes nest;
        /// `deinit` restores the previous one.
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

        pub fn begin(self: *Conn) Result(Transaction) {
            self.conn.transaction() catch |cause| return .{ .err = makeError(self.allocator, self.conn, .transaction, cause) };
            return .{ .ok = .{ .connection = self } };
        }

        pub fn execute(self: *Conn, sql: []const u8, args: anytype) Result(ExecResult) {
            const bound = core.bindArgs(args);
            const statement = self.conn.prepare(sql) catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .execute, cause) };
            defer statement.deinit();
            statement.bind(bound) catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .execute, cause) };
            // `sqlite3_changes` keeps reporting the previous statement's count
            // for a command that writes no rows, so a read-only statement has
            // no meaningful count to report at all.
            const readonly = zqlite.c.sqlite3_stmt_readonly(statement.stmt) != 0;
            statement.stepToCompletion() catch |cause|
                return .{ .err = makeError(self.allocator, self.conn, .execute, cause) };
            return .{ .ok = .{
                .rows_affected = if (readonly) null else @intCast(self.conn.changes()),
            } };
        }

        /// SQLite's `last_insert_rowid`. Portable code should prefer
        /// `RETURNING`; this is the backend-specific escape hatch.
        pub fn lastInsertRowId(self: *Conn) i64 {
            return self.conn.lastInsertedRowId();
        }

        /// Rows changed by the most recent statement on this connection.
        pub fn changes(self: *Conn) u64 {
            return @intCast(self.conn.changes());
        }

        pub fn fetchOne(self: *Conn, comptime Row: type, sql: []const u8, args: anytype) Result(Single(Row)) {
            const bound = core.bindArgs(args);
            const native = self.conn.row(sql, bound) catch |cause| return .{ .err = makeError(self.allocator, self.conn, .fetch, cause) };
            const row = native orelse return .{ .err = staticError(.invalid_data, .fetch, "query expected one row but returned none") };
            // A row that cannot be decoded still owns a statement to finalize.
            const single = Single(Row).init(row, self) catch |cause| {
                row.deinit();
                return .{ .err = decodeError(cause) };
            };
            return .{ .ok = single };
        }

        pub fn fetchOptional(self: *Conn, comptime Row: type, sql: []const u8, args: anytype) Result(?Single(Row)) {
            const bound = core.bindArgs(args);
            const native = self.conn.row(sql, bound) catch |cause| return .{ .err = makeError(self.allocator, self.conn, .fetch, cause) };
            const row = native orelse return .{ .ok = null };
            const single = Single(Row).init(row, self) catch |cause| {
                row.deinit();
                return .{ .err = decodeError(cause) };
            };
            return .{ .ok = single };
        }

        pub fn fetch(self: *Conn, comptime Row: type, sql: []const u8, args: anytype) Result(Rows(Row)) {
            const bound = core.bindArgs(args);
            const native = self.conn.rows(sql, bound) catch |cause| return .{ .err = makeError(self.allocator, self.conn, .fetch, cause) };
            return .{ .ok = .{
                .allocator = self.allocator,
                .io = self.io,
                .conn = self.conn,
                .native = native,
                .row_allocator = self.row_allocator,
                .row_free = self.row_free,
            } };
        }
    };

    pub const ScopeOptions = struct {
        /// `false` for an arena the caller releases wholesale: owned rows from
        /// the scope then treat `deinit` as a no-op.
        free_rows: bool = true,
    };

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

    const OwnedTarget = struct {
        allocator: std.mem.Allocator,
        free: bool,
    };

    fn ownedTarget(explicit: ?std.mem.Allocator, scoped: ?std.mem.Allocator, scope_free: bool) ?OwnedTarget {
        if (explicit) |allocator| return .{ .allocator = allocator, .free = true };
        return .{ .allocator = scoped orelse return null, .free = scope_free };
    }

    fn missingOwnedAllocator() Error {
        return staticError(
            .invalid_data,
            .fetch,
            "no owned-row allocator: pass one to toOwned or open conn.ownedScope",
        );
    }

    fn ownedAllocationFailed() Error {
        return staticError(.other, .fetch, "unable to allocate owned row");
    }

    pub const Ownership = enum { owned, borrowed, pooled };

    pub const JournalMode = enum { delete, truncate, persist, memory, wal, off };
    pub const Synchronous = enum { off, normal, full, extra };

    /// Connection setup sqlz applies on the caller's behalf. Every knob is
    /// optional: `null` leaves SQLite's own default in place. Anything not
    /// named here stays a `raw()` PRAGMA.
    pub const OpenOptions = struct {
        create: bool = true,
        read_only: bool = false,
        foreign_keys: ?bool = null,
        journal_mode: ?JournalMode = null,
        synchronous: ?Synchronous = null,
        busy_timeout_ms: ?u32 = null,
    };

    fn openFlags(options: OpenOptions) c_int {
        var flags: c_int = zqlite.OpenFlags.EXResCode;
        if (options.read_only) return flags | zqlite.OpenFlags.ReadOnly;
        flags |= zqlite.OpenFlags.ReadWrite;
        if (options.create) flags |= zqlite.OpenFlags.Create;
        return flags;
    }

    /// Applies the typed options to a freshly opened handle. Order matters:
    /// the busy timeout is installed first so a contended journal-mode switch
    /// waits instead of failing.
    fn applyOptions(conn: zqlite.Conn, options: OpenOptions) !void {
        if (options.busy_timeout_ms) |timeout| try conn.busyTimeout(@intCast(timeout));
        if (options.foreign_keys) |enabled|
            try conn.execNoArgs(if (enabled) "PRAGMA foreign_keys = ON" else "PRAGMA foreign_keys = OFF");
        if (options.journal_mode) |mode| try conn.execNoArgs(switch (mode) {
            .delete => "PRAGMA journal_mode = DELETE",
            .truncate => "PRAGMA journal_mode = TRUNCATE",
            .persist => "PRAGMA journal_mode = PERSIST",
            .memory => "PRAGMA journal_mode = MEMORY",
            .wal => "PRAGMA journal_mode = WAL",
            .off => "PRAGMA journal_mode = OFF",
        });
        if (options.synchronous) |level| try conn.execNoArgs(switch (level) {
            .off => "PRAGMA synchronous = OFF",
            .normal => "PRAGMA synchronous = NORMAL",
            .full => "PRAGMA synchronous = FULL",
            .extra => "PRAGMA synchronous = EXTRA",
        });
    }

    /// Opens an owned SQLite connection. `io` is the `std.Io` implementation
    /// the application runs on (`std.Io.Threaded`, or a third-party runtime
    /// such as zio); it is stored on the connection rather than passed per
    /// call so generated bindings keep a single executor argument.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, options: OpenOptions) !Conn {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const conn = try zqlite.open(path_z.ptr, openFlags(options));
        errdefer conn.close();
        try applyOptions(conn, options);
        return .{ .allocator = allocator, .io = io, .conn = conn };
    }

    /// Wraps a connection the caller continues to own; `deinit` never closes it.
    pub fn borrow(allocator: std.mem.Allocator, io: std.Io, conn: zqlite.Conn) Conn {
        return .{ .allocator = allocator, .io = io, .conn = conn, .ownership = .borrowed };
    }

    pub const PoolOptions = struct {
        size: usize = 5,
        connection: OpenOptions = .{},
    };

    /// Wraps zqlite's native pool: sqlz adds no pool of its own, it only hands
    /// back sqlz connections with pooled release semantics.
    pub const Pool = struct {
        allocator: std.mem.Allocator,
        /// Retained for the same reason a connection retains it: every handle
        /// derived from this pool reaches the caller's runtime.
        io: std.Io,
        pool: *zqlite.Pool,
        options: OpenOptions,
        /// The callback context zqlite holds while it opens its connections.
        options_context: *OpenOptions,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, options: PoolOptions) !Pool {
            const path_z = try allocator.dupeZ(u8, path);
            defer allocator.free(path_z);
            const stored = try allocator.create(OpenOptions);
            errdefer allocator.destroy(stored);
            stored.* = options.connection;
            const pool = try zqlite.Pool.init(allocator, .{
                .size = options.size,
                .flags = openFlags(options.connection),
                .path = path_z.ptr,
                .on_connection = configureConnection,
                .on_connection_context = stored,
            });
            return .{
                .allocator = allocator,
                .io = io,
                .pool = pool,
                .options = options.connection,
                .options_context = stored,
            };
        }

        pub fn deinit(self: *Pool) void {
            self.pool.deinit();
            self.allocator.destroy(self.options_context);
            self.* = undefined;
        }

        /// Borrows a connection for as long as the returned handle lives;
        /// its `deinit` returns the connection to the pool.
        pub fn acquire(self: *Pool) !Conn {
            const conn = try self.pool.acquire(self.io);
            return .{
                .allocator = self.allocator,
                .io = self.io,
                .conn = conn,
                .ownership = .pooled,
                .pool = self,
            };
        }

        // The executor protocol, so a pool can run a checked query directly.
        // Result-holding cardinalities keep the connection alive by handing
        // ownership of it to the returned handle.

        pub fn execute(self: *Pool, sql: []const u8, args: anytype) Result(ExecResult) {
            var conn = self.acquire() catch |cause| return .{ .err = acquireError(cause) };
            defer conn.deinit();
            return conn.execute(sql, args);
        }

        pub fn fetchOne(self: *Pool, comptime Row: type, sql: []const u8, args: anytype) Result(Single(Row)) {
            const owner = self.checkout() catch |cause| return .{ .err = acquireError(cause) };
            switch (owner.fetchOne(Row, sql, args)) {
                .ok => |value| {
                    var single = value;
                    single.owner = owner;
                    return .{ .ok = single };
                },
                .err => |err| {
                    self.checkin(owner);
                    return .{ .err = err };
                },
            }
        }

        pub fn fetchOptional(self: *Pool, comptime Row: type, sql: []const u8, args: anytype) Result(?Single(Row)) {
            const owner = self.checkout() catch |cause| return .{ .err = acquireError(cause) };
            switch (owner.fetchOptional(Row, sql, args)) {
                .ok => |value| {
                    var single = value orelse {
                        self.checkin(owner);
                        return .{ .ok = null };
                    };
                    single.owner = owner;
                    return .{ .ok = single };
                },
                .err => |err| {
                    self.checkin(owner);
                    return .{ .err = err };
                },
            }
        }

        pub fn fetch(self: *Pool, comptime Row: type, sql: []const u8, args: anytype) Result(Rows(Row)) {
            const owner = self.checkout() catch |cause| return .{ .err = acquireError(cause) };
            switch (owner.fetch(Row, sql, args)) {
                .ok => |value| {
                    var rows = value;
                    rows.owner = owner;
                    return .{ .ok = rows };
                },
                .err => |err| {
                    self.checkin(owner);
                    return .{ .err = err };
                },
            }
        }

        /// A pooled connection that outlives this call, owned by whatever
        /// handle the caller receives.
        fn checkout(self: *Pool) !*Conn {
            const owner = try self.allocator.create(Conn);
            errdefer self.allocator.destroy(owner);
            owner.* = try self.acquire();
            return owner;
        }

        fn checkin(self: *Pool, owner: *Conn) void {
            owner.deinit();
            self.allocator.destroy(owner);
        }

        pub fn raw(self: *Pool) *zqlite.Pool {
            return self.pool;
        }

        fn configureConnection(conn: zqlite.Conn, context: ?*anyopaque) anyerror!void {
            const options: *const OpenOptions = @ptrCast(@alignCast(context.?));
            try applyOptions(conn, options.*);
        }
    };

    pub fn Single(comptime Row: type) type {
        return struct {
            native: zqlite.Row,
            value: Row,
            row_allocator: ?std.mem.Allocator = null,
            row_free: bool = true,
            /// Set when a pool produced this handle: released on `deinit`.
            owner: ?*Conn = null,

            fn init(native: zqlite.Row, connection: *const Conn) DecodeError!@This() {
                return .{
                    .native = native,
                    .value = try decodeRow(Row, native),
                    .row_allocator = connection.row_allocator,
                    .row_free = connection.row_free,
                };
            }

            pub fn row(self: *@This()) Row {
                return self.value;
            }

            pub fn deinit(self: *@This()) void {
                self.native.deinit();
                releaseOwner(self.owner);
                self.* = undefined;
            }

            /// `null` uses the connection's owned-row scope; an explicit
            /// allocator always owns the copy and must free it.
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
        };
    }

    pub fn Owned(comptime Row: type) type {
        return struct {
            /// `null` when the row came from a scope that frees wholesale;
            /// `deinit` then releases nothing but still poisons the handle.
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
            /// `false` when the rows came from a scope that frees wholesale.
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
            /// Streaming iterators outlive the call that produced them, so they
            /// carry the connection's interface rather than reaching back for
            /// it. A SQLite cursor never uses it; a PostgreSQL cursor advances
            /// over a socket and will.
            io: std.Io,
            conn: zqlite.Conn,
            native: zqlite.Rows,
            finished: bool = false,
            row_allocator: ?std.mem.Allocator = null,
            row_free: bool = true,
            /// Set when a pool produced this cursor: released on `deinit`.
            owner: ?*Conn = null,

            pub fn next(self: *@This()) Result(?Row) {
                if (self.finished) return .{ .ok = null };
                if (self.native.next()) |native_row| {
                    const value = decodeRow(Row, native_row) catch |cause| return .{ .err = decodeError(cause) };
                    return .{ .ok = value };
                }
                self.finished = true;
                if (self.native.err) |cause| return .{ .err = makeError(self.allocator, self.conn, .iterate, cause) };
                return .{ .ok = null };
            }

            /// Streaming counterpart to `Single.toOwned`: the returned row no
            /// longer points into the cursor, so it survives the next advance.
            pub fn nextOwned(self: *@This(), allocator: ?std.mem.Allocator) Result(?Owned(Row)) {
                const target = ownedTarget(allocator, self.row_allocator, self.row_free) orelse
                    return .{ .err = missingOwnedAllocator() };
                switch (self.next()) {
                    .err => |err| return .{ .err = err },
                    .ok => |maybe_row| {
                        const borrowed = maybe_row orelse return .{ .ok = null };
                        const value = cloneRow(target.allocator, borrowed) catch
                            return .{ .err = ownedAllocationFailed() };
                        return .{ .ok = .{
                            .allocator = if (target.free) target.allocator else null,
                            .value = value,
                        } };
                    },
                }
            }

            /// Drains the cursor into owned rows. Pairs with an arena scope,
            /// where the whole result set is released in one call.
            pub fn collectOwned(self: *@This(), allocator: ?std.mem.Allocator) Result(OwnedRows(Row)) {
                const target = ownedTarget(allocator, self.row_allocator, self.row_free) orelse
                    return .{ .err = missingOwnedAllocator() };
                var collected: std.ArrayList(Row) = .empty;
                while (true) switch (self.next()) {
                    .err => |err| {
                        releaseCollected(&collected, target);
                        return .{ .err = err };
                    },
                    .ok => |maybe_row| {
                        const borrowed = maybe_row orelse break;
                        var value = cloneRow(target.allocator, borrowed) catch {
                            releaseCollected(&collected, target);
                            return .{ .err = ownedAllocationFailed() };
                        };
                        collected.append(target.allocator, value) catch {
                            if (target.free) deinitOwnedRow(target.allocator, &value);
                            releaseCollected(&collected, target);
                            return .{ .err = ownedAllocationFailed() };
                        };
                    },
                };
                const items = collected.toOwnedSlice(target.allocator) catch {
                    releaseCollected(&collected, target);
                    return .{ .err = ownedAllocationFailed() };
                };
                return .{ .ok = .{
                    .allocator = target.allocator,
                    .free_rows = target.free,
                    .items = items,
                } };
            }

            fn releaseCollected(collected: *std.ArrayList(Row), target: OwnedTarget) void {
                if (target.free) for (collected.items) |*item| deinitOwnedRow(target.allocator, item);
                collected.deinit(target.allocator);
            }

            pub fn drain(self: *@This()) Result(void) {
                while (true) switch (self.next()) {
                    .ok => |row| if (row == null) return .{ .ok = {} },
                    .err => |err| return .{ .err = err },
                };
            }

            pub fn deinit(self: *@This()) void {
                self.native.deinit();
                releaseOwner(self.owner);
                self.* = undefined;
            }
        };
    }

    fn releaseOwner(owner: ?*Conn) void {
        const connection = owner orelse return;
        const allocator = connection.allocator;
        connection.deinit();
        allocator.destroy(connection);
    }

    fn acquireError(cause: anyerror) Error {
        return staticError(classify(cause), .connect, @errorName(cause));
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

        pub fn lastInsertRowId(self: *Transaction) i64 {
            return self.connection.lastInsertRowId();
        }

        pub fn changes(self: *Transaction) u64 {
            return self.connection.changes();
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

    fn decodeRow(comptime Row: type, native: zqlite.Row) DecodeError!Row {
        var value: Row = undefined;
        inline for (@typeInfo(Row).@"struct".fields, 0..) |field, index| {
            @field(value, field.name) = try decodeField(field.type, native, index);
        }
        return value;
    }

    /// zqlite decodes a fixed set of storage types. Everything sqlz adds on top
    /// — application enums, and `Blob` columns, which zqlite only hands back as
    /// `[]const u8` — is reconstructed here.
    fn decodeField(comptime T: type, native: zqlite.Row, index: usize) DecodeError!T {
        if (T == Blob) return .{ .value = native.get([]const u8, index) };
        if (T == ?Blob) {
            const bytes = native.get(?[]const u8, index) orelse return null;
            return Blob{ .value = bytes };
        }
        switch (@typeInfo(T)) {
            .@"enum" => return decodeEnum(T, native, index),
            .optional => |optional| {
                if (@typeInfo(optional.child) != .@"enum") return native.get(T, index);
                switch (comptime core.enumStorage(optional.child)) {
                    .integer => {
                        const stored = native.get(?i64, index) orelse return null;
                        return try intToEnum(optional.child, stored);
                    },
                    .text => {
                        const stored = native.get(?[]const u8, index) orelse return null;
                        return try nameToEnum(optional.child, stored);
                    },
                }
            },
            else => return native.get(T, index),
        }
    }

    fn decodeEnum(comptime E: type, native: zqlite.Row, index: usize) DecodeError!E {
        return switch (comptime core.enumStorage(E)) {
            .integer => intToEnum(E, native.get(i64, index)),
            .text => nameToEnum(E, native.get([]const u8, index)),
        };
    }

    fn intToEnum(comptime E: type, stored: i64) DecodeError!E {
        return std.enums.fromInt(E, stored) orelse error.InvalidEnumValue;
    }

    fn nameToEnum(comptime E: type, stored: []const u8) DecodeError!E {
        return std.meta.stringToEnum(E, stored) orelse error.InvalidEnumValue;
    }
};

const DecodeError = error{InvalidEnumValue};

fn decodeError(cause: DecodeError) Error {
    return switch (cause) {
        error.InvalidEnumValue => staticError(
            .invalid_data,
            .fetch,
            "column value is not a member of the declared enum",
        ),
    };
}

fn staticError(class: ErrorClass, operation: Operation, message: []const u8) Error {
    return .{ .class = class, .backend = .sqlite, .operation = operation, .message = message };
}

fn makeError(allocator: std.mem.Allocator, conn: zqlite.Conn, operation: Operation, cause: anyerror) Error {
    // Connections are opened with EXResCode, so this is the extended code.
    const code: i32 = @intCast(zqlite.c.sqlite3_extended_errcode(conn.conn));
    const message = allocator.dupe(u8, std.mem.span(conn.lastError())) catch {
        var fallback = staticError(classify(cause), operation, @errorName(cause));
        fallback.code = code;
        return fallback;
    };
    return .{
        .allocator = allocator,
        .class = classify(cause),
        .backend = .sqlite,
        .operation = operation,
        .code = code,
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
