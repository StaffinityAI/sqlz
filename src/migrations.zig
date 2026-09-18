const std = @import("std");
const ziggy = @import("ziggy");

pub const Backend = enum { sqlite, postgres };
pub const Direction = enum { up, down };
pub const TransactionPolicy = enum { always, never };

pub const Transactions = struct {
    sqlite: ?TransactionPolicy = null,
    postgres: ?TransactionPolicy = null,
};

pub const Manifest = struct {
    format_version: u32,
    revision: []const u8,
    parents: []const []const u8,
    description: []const u8,
    created_utc: []const u8,
    backends: []const Backend,
    reversible: bool,
    transaction: Transactions,
};

pub const ManifestValidationError = error{
    UnsupportedFormatVersion,
    InvalidRevisionId,
    InvalidParentId,
    SelfParent,
    DuplicateParent,
    EmptyDescription,
    InvalidCreatedUtc,
    MissingBackend,
    DuplicateBackend,
    MissingTransactionPolicy,
    UnexpectedTransactionPolicy,
    UnsupportedSqliteTransaction,
};

pub const ManifestError = ziggy.Deserializer.Error || ManifestValidationError;

pub const LoadedManifest = struct {
    value: Manifest,
    arena: std.heap.ArenaAllocator,

    pub fn manifest(self: *const LoadedManifest) *const Manifest {
        return &self.value;
    }

    pub fn deinit(self: *LoadedManifest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const DiscoveredRevision = struct {
    allocator: std.mem.Allocator,
    directory: []const u8,
    manifest: LoadedManifest,
    common_up: []const u8,
    common_down: []const u8,
    sqlite_up: []const u8,
    sqlite_down: []const u8,
    postgres_up: []const u8,
    postgres_down: []const u8,

    pub fn commonSql(self: *const DiscoveredRevision, direction: Direction) []const u8 {
        return switch (direction) {
            .up => self.common_up,
            .down => self.common_down,
        };
    }

    pub fn backendSql(
        self: *const DiscoveredRevision,
        backend: Backend,
        direction: Direction,
    ) []const u8 {
        return switch (backend) {
            .sqlite => switch (direction) {
                .up => self.sqlite_up,
                .down => self.sqlite_down,
            },
            .postgres => switch (direction) {
                .up => self.postgres_up,
                .down => self.postgres_down,
            },
        };
    }

    pub fn deinit(self: *DiscoveredRevision) void {
        self.manifest.deinit();
        self.allocator.free(self.directory);
        self.allocator.free(self.common_up);
        self.allocator.free(self.common_down);
        self.allocator.free(self.sqlite_up);
        self.allocator.free(self.sqlite_down);
        self.allocator.free(self.postgres_up);
        self.allocator.free(self.postgres_down);
        self.* = undefined;
    }
};

pub const Discovery = struct {
    allocator: std.mem.Allocator,
    revisions: []DiscoveredRevision,

    pub fn deinit(self: *Discovery) void {
        for (self.revisions) |*revision| revision.deinit();
        self.allocator.free(self.revisions);
        self.* = undefined;
    }
};

pub const DiscoveryError = error{
    DirectoryRevisionMismatch,
    MissingUpgradeSql,
    MissingDowngradeSql,
    UnexpectedBackendSql,
};

pub fn parseManifest(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    meta: *ziggy.Deserializer.Meta,
) ManifestError!LoadedManifest {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const value = try ziggy.deserializeLeaky(Manifest, arena.allocator(), source, meta, .{
        .copy_strings = .always,
    });
    try validateManifest(&value);
    return .{ .value = value, .arena = arena };
}

pub fn validateManifest(manifest: *const Manifest) ManifestValidationError!void {
    if (manifest.format_version != 1) return error.UnsupportedFormatVersion;
    if (!validId(manifest.revision)) return error.InvalidRevisionId;
    if (manifest.description.len == 0) return error.EmptyDescription;
    if (!validUtcTimestamp(manifest.created_utc)) return error.InvalidCreatedUtc;
    for (manifest.parents, 0..) |parent, index| {
        if (!validId(parent)) return error.InvalidParentId;
        if (std.mem.eql(u8, parent, manifest.revision)) return error.SelfParent;
        for (manifest.parents[0..index]) |prior| {
            if (std.mem.eql(u8, parent, prior)) return error.DuplicateParent;
        }
    }

    if (manifest.backends.len == 0) return error.MissingBackend;
    var sqlite = false;
    var postgres = false;
    for (manifest.backends) |backend| switch (backend) {
        .sqlite => {
            if (sqlite) return error.DuplicateBackend;
            sqlite = true;
        },
        .postgres => {
            if (postgres) return error.DuplicateBackend;
            postgres = true;
        },
    };
    if (sqlite) {
        const policy = manifest.transaction.sqlite orelse
            return error.MissingTransactionPolicy;
        if (policy != .always) return error.UnsupportedSqliteTransaction;
    } else if (manifest.transaction.sqlite != null) {
        return error.UnexpectedTransactionPolicy;
    }
    if (postgres) {
        _ = manifest.transaction.postgres orelse
            return error.MissingTransactionPolicy;
    } else if (manifest.transaction.postgres != null) {
        return error.UnexpectedTransactionPolicy;
    }
}

pub fn discover(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    max_source_bytes: usize,
) anyerror!Discovery {
    var directory_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (directory_names.items) |name| allocator.free(name);
        directory_names.deinit(allocator);
    }
    var iterator = root.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try directory_names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, directory_names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var revisions: std.ArrayList(DiscoveredRevision) = .empty;
    errdefer {
        for (revisions.items) |*revision| revision.deinit();
        revisions.deinit(allocator);
    }
    for (directory_names.items) |directory_name| {
        var directory = try root.openDir(io, directory_name, .{});
        defer directory.close(io);
        const raw_manifest = try directory.readFileAlloc(
            io,
            "revision.ziggy",
            allocator,
            .limited(max_source_bytes),
        );
        defer allocator.free(raw_manifest);
        const manifest_source = try allocator.dupeZ(u8, raw_manifest);
        defer allocator.free(manifest_source);
        var meta: ziggy.Deserializer.Meta = .init;
        var loaded = try parseManifest(allocator, manifest_source, &meta);
        errdefer loaded.deinit();
        if (directory_name.len < 13 or directory_name[12] != '_' or
            !std.mem.eql(u8, directory_name[0..12], loaded.manifest().revision))
            return error.DirectoryRevisionMismatch;

        const common_up = try readOptionalSql(
            allocator,
            io,
            directory,
            "common.up.sql",
            max_source_bytes,
        );
        errdefer allocator.free(common_up);
        const common_down = try readOptionalSql(
            allocator,
            io,
            directory,
            "common.down.sql",
            max_source_bytes,
        );
        errdefer allocator.free(common_down);
        const sqlite_up = try readOptionalSql(
            allocator,
            io,
            directory,
            "sqlite.up.sql",
            max_source_bytes,
        );
        errdefer allocator.free(sqlite_up);
        const sqlite_down = try readOptionalSql(
            allocator,
            io,
            directory,
            "sqlite.down.sql",
            max_source_bytes,
        );
        errdefer allocator.free(sqlite_down);
        const postgres_up = try readOptionalSql(
            allocator,
            io,
            directory,
            "postgres.up.sql",
            max_source_bytes,
        );
        errdefer allocator.free(postgres_up);
        const postgres_down = try readOptionalSql(
            allocator,
            io,
            directory,
            "postgres.down.sql",
            max_source_bytes,
        );
        errdefer allocator.free(postgres_down);

        const manifest = loaded.manifest();
        try validateSqlFiles(
            manifest,
            common_up,
            common_down,
            sqlite_up,
            sqlite_down,
            postgres_up,
            postgres_down,
        );

        try revisions.append(allocator, .{
            .allocator = allocator,
            .directory = try allocator.dupe(u8, directory_name),
            .manifest = loaded,
            .common_up = common_up,
            .common_down = common_down,
            .sqlite_up = sqlite_up,
            .sqlite_down = sqlite_down,
            .postgres_up = postgres_up,
            .postgres_down = postgres_down,
        });
    }

    const graph = try allocator.alloc(Revision, revisions.items.len);
    defer allocator.free(graph);
    for (revisions.items, graph) |revision, *node| {
        node.* = .{
            .id = revision.manifest.manifest().revision,
            .parents = revision.manifest.manifest().parents,
        };
    }
    var order = try validateAndOrder(allocator, graph);
    order.deinit();
    return .{
        .allocator = allocator,
        .revisions = try revisions.toOwnedSlice(allocator),
    };
}

fn readOptionalSql(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    name: []const u8,
    max_source_bytes: usize,
) anyerror![]const u8 {
    return directory.readFileAlloc(
        io,
        name,
        allocator,
        .limited(max_source_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => allocator.dupe(u8, ""),
        else => err,
    };
}

pub fn targetsBackend(manifest: *const Manifest, backend: Backend) bool {
    for (manifest.backends) |candidate| if (candidate == backend) return true;
    return false;
}

fn validateSqlFiles(
    manifest: *const Manifest,
    common_up: []const u8,
    common_down: []const u8,
    sqlite_up: []const u8,
    sqlite_down: []const u8,
    postgres_up: []const u8,
    postgres_down: []const u8,
) DiscoveryError!void {
    const merge = manifest.parents.len >= 2;
    const common_up_present = hasSql(common_up);
    const common_down_present = hasSql(common_down);
    const sqlite_up_present = hasSql(sqlite_up);
    const sqlite_down_present = hasSql(sqlite_down);
    const postgres_up_present = hasSql(postgres_up);
    const postgres_down_present = hasSql(postgres_down);

    if (!targetsBackend(manifest, .sqlite) and (sqlite_up_present or sqlite_down_present))
        return error.UnexpectedBackendSql;
    if (!targetsBackend(manifest, .postgres) and (postgres_up_present or postgres_down_present))
        return error.UnexpectedBackendSql;

    for (manifest.backends) |backend| {
        const backend_up = switch (backend) {
            .sqlite => sqlite_up_present,
            .postgres => postgres_up_present,
        };
        if (!merge and !common_up_present and !backend_up)
            return error.MissingUpgradeSql;

        const backend_down = switch (backend) {
            .sqlite => sqlite_down_present,
            .postgres => postgres_down_present,
        };
        if (manifest.reversible and !merge and !common_down_present and !backend_down)
            return error.MissingDowngradeSql;
    }
}

fn hasSql(source: []const u8) bool {
    return std.mem.trim(u8, source, &std.ascii.whitespace).len != 0;
}

pub const Revision = struct {
    id: []const u8,
    parents: []const []const u8,
};

pub const Error = error{
    InvalidRevisionId,
    DuplicateRevision,
    MissingParent,
    Cycle,
    MultipleHeads,
} || std.mem.Allocator.Error;

pub const Order = struct {
    allocator: std.mem.Allocator,
    indices: []const usize,
    head: usize,

    pub fn deinit(self: *Order) void {
        self.allocator.free(self.indices);
        self.* = undefined;
    }
};

pub fn validateAndOrder(
    allocator: std.mem.Allocator,
    revisions: []const Revision,
) Error!Order {
    if (revisions.len == 0) return error.MultipleHeads;

    var by_id: std.StringHashMapUnmanaged(usize) = .empty;
    defer by_id.deinit(allocator);
    for (revisions, 0..) |revision, index| {
        if (!validId(revision.id)) return error.InvalidRevisionId;
        const entry = try by_id.getOrPut(allocator, revision.id);
        if (entry.found_existing) return error.DuplicateRevision;
        entry.value_ptr.* = index;
    }

    const indegree = try allocator.alloc(usize, revisions.len);
    defer allocator.free(indegree);
    const is_head = try allocator.alloc(bool, revisions.len);
    defer allocator.free(is_head);
    @memset(is_head, true);
    for (revisions, 0..) |revision, index| {
        indegree[index] = revision.parents.len;
        for (revision.parents) |parent| {
            const parent_index = by_id.get(parent) orelse return error.MissingParent;
            is_head[parent_index] = false;
        }
    }

    var head: ?usize = null;
    for (is_head, 0..) |candidate, index| {
        if (!candidate) continue;
        if (head != null) return error.MultipleHeads;
        head = index;
    }

    const processed = try allocator.alloc(bool, revisions.len);
    defer allocator.free(processed);
    @memset(processed, false);
    const ordered = try allocator.alloc(usize, revisions.len);
    errdefer allocator.free(ordered);

    for (ordered) |*slot| {
        var selected: ?usize = null;
        for (revisions, 0..) |revision, index| {
            if (processed[index] or indegree[index] != 0) continue;
            if (selected == null or
                std.mem.order(u8, revision.id, revisions[selected.?].id) == .lt)
                selected = index;
        }
        const index = selected orelse return error.Cycle;
        processed[index] = true;
        slot.* = index;

        for (revisions, 0..) |revision, child_index| {
            if (processed[child_index]) continue;
            for (revision.parents) |parent| {
                if (std.mem.eql(u8, parent, revisions[index].id)) {
                    indegree[child_index] -= 1;
                    break;
                }
            }
        }
    }

    return .{ .allocator = allocator, .indices = ordered, .head = head.? };
}

pub fn validId(id: []const u8) bool {
    if (id.len != 12) return false;
    for (id) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

fn validUtcTimestamp(value: []const u8) bool {
    if (value.len != 20 or value[4] != '-' or value[7] != '-' or
        value[10] != 'T' or value[13] != ':' or value[16] != ':' or
        value[19] != 'Z') return false;
    for (value, 0..) |c, index| switch (index) {
        4, 7, 10, 13, 16, 19 => {},
        else => if (!std.ascii.isDigit(c)) return false,
    };
    return true;
}
