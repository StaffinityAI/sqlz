const std = @import("std");
const ziggy = @import("ziggy");
const diagnostics = @import("sqlz_diagnostics");
const inputs = @import("sqlz_inputs");
const source_manager = @import("sqlz_source");

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
    source: []const u8,
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
    manifest_path: []const u8,
    manifest: LoadedManifest,
    common_up: []const u8,
    common_down: []const u8,
    sqlite_up: []const u8,
    sqlite_down: []const u8,
    postgres_up: []const u8,
    postgres_down: []const u8,

    /// Migration SQL as a database receives it. The file's original bytes,
    /// byte order mark included, stay in the revision for checksums.
    pub fn executable(sql: []const u8) []const u8 {
        return source_manager.withoutBom(sql);
    }

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
        self.allocator.free(self.manifest_path);
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
    const value = try ziggy.deserializeLeaky(Manifest, arena.allocator(), try maskBom(arena.allocator(), source), meta, .{
        .copy_strings = .always,
    });
    try validateManifest(&value);
    return .{
        .value = value,
        .source = try arena.allocator().dupe(u8, source),
        .arena = arena,
    };
}

/// A copy of a Ziggy source with its byte order mark replaced by spaces, so
/// the deserializer sees plain whitespace and every offset it reports is an
/// offset into the original file.
pub fn maskBom(allocator: std.mem.Allocator, source: [:0]const u8) std.mem.Allocator.Error![:0]u8 {
    const copy = try allocator.dupeZ(u8, source);
    @memset(copy[0..source_manager.bomLength(copy)], ' ');
    return copy;
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

/// Discovers the revisions in the migration root `root`, reading every file
/// through `project_inputs` so the project's path and size limits apply.
pub fn discover(
    allocator: std.mem.Allocator,
    project_inputs: *inputs.Inputs,
    root: std.Io.Dir,
) anyerror!Discovery {
    return discoverImpl(allocator, project_inputs, root, null);
}

pub fn discoverWithDiagnostics(
    allocator: std.mem.Allocator,
    project_inputs: *inputs.Inputs,
    root: std.Io.Dir,
    diagnostic_list: *diagnostics.List,
) anyerror!Discovery {
    return discoverImpl(allocator, project_inputs, root, diagnostic_list);
}

fn discoverImpl(
    allocator: std.mem.Allocator,
    project_inputs: *inputs.Inputs,
    root: std.Io.Dir,
    diagnostic_list: ?*diagnostics.List,
) anyerror!Discovery {
    const io = project_inputs.io;
    const diagnostics_before = if (diagnostic_list) |list| list.slice().len else 0;
    var directory_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (directory_names.items) |name| allocator.free(name);
        directory_names.deinit(allocator);
    }
    var iterator = root.iterate();
    while (try iterator.next(io)) |entry| {
        // Only directories are revisions; files in the root are never read.
        const kind = try project_inputs.entryKind(root, entry.name, entry.kind, false);
        if (kind != .directory) continue;
        // Count before any manifest is read, so an oversized history fails
        // without buffering it.
        try project_inputs.countRevisions(root, directory_names.items.len + 1);
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
        const raw_manifest = try project_inputs.readFile(allocator, directory, "revision.ziggy");
        defer allocator.free(raw_manifest);
        const manifest_source = try allocator.dupeZ(u8, raw_manifest);
        defer allocator.free(manifest_source);
        var meta: ziggy.Deserializer.Meta = .init;
        var loaded = parseManifest(allocator, manifest_source, &meta) catch |err| {
            if (diagnostic_list) |list| {
                try appendManifestDiagnostic(list, directory_name, manifest_source, &meta, err);
                continue;
            }
            return err;
        };
        errdefer loaded.deinit();
        if (directory_name.len < 13 or directory_name[12] != '_' or
            !std.mem.eql(u8, directory_name[0..12], loaded.manifest().revision))
        {
            if (diagnostic_list) |list| {
                try appendFieldDiagnostic(
                    list,
                    directory_name,
                    manifest_source,
                    "revision",
                    "M010",
                    "revision ID does not match its directory prefix",
                    "rename the directory or correct `.revision` so their 12-character IDs match",
                );
                loaded.deinit();
                continue;
            }
            return error.DirectoryRevisionMismatch;
        }

        const common_up = try project_inputs.readOptional(allocator, directory, "common.up.sql");
        errdefer allocator.free(common_up);
        const common_down = try project_inputs.readOptional(allocator, directory, "common.down.sql");
        errdefer allocator.free(common_down);
        const sqlite_up = try project_inputs.readOptional(allocator, directory, "sqlite.up.sql");
        errdefer allocator.free(sqlite_up);
        const sqlite_down = try project_inputs.readOptional(allocator, directory, "sqlite.down.sql");
        errdefer allocator.free(sqlite_down);
        const postgres_up = try project_inputs.readOptional(allocator, directory, "postgres.up.sql");
        errdefer allocator.free(postgres_up);
        const postgres_down = try project_inputs.readOptional(allocator, directory, "postgres.down.sql");
        errdefer allocator.free(postgres_down);

        const manifest = loaded.manifest();
        validateSqlFiles(
            manifest,
            common_up,
            common_down,
            sqlite_up,
            sqlite_down,
            postgres_up,
            postgres_down,
        ) catch |err| {
            if (diagnostic_list) |list| {
                try appendSqlFilesDiagnostic(list, directory_name, manifest_source, err);
                loaded.deinit();
                allocator.free(common_up);
                allocator.free(common_down);
                allocator.free(sqlite_up);
                allocator.free(sqlite_down);
                allocator.free(postgres_up);
                allocator.free(postgres_down);
                continue;
            }
            return err;
        };

        try revisions.append(allocator, .{
            .allocator = allocator,
            .directory = try allocator.dupe(u8, directory_name),
            .manifest_path = try std.fmt.allocPrint(allocator, "{s}/revision.ziggy", .{directory_name}),
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
    if (diagnostic_list) |list| {
        if (revisions.items.len != 0 or list.slice().len == diagnostics_before)
            try appendGraphDiagnostics(allocator, revisions.items, graph, list);
    } else {
        var order = try validateAndOrder(allocator, graph);
        order.deinit();
    }
    return .{
        .allocator = allocator,
        .revisions = try revisions.toOwnedSlice(allocator),
    };
}

fn appendManifestDiagnostic(
    list: *diagnostics.List,
    directory: []const u8,
    source: [:0]const u8,
    meta: *const ziggy.Deserializer.Meta,
    err: anyerror,
) !void {
    const path = try manifestPath(list.arena.allocator(), directory);
    const field = manifestErrorField(err);
    const span = if (field) |name|
        fieldSpan(path, source, name)
    else if (isZiggyError(err))
        diagnostics.spanAt(path, source, meta.error_loc.start, meta.error_loc.end)
    else
        fieldSpan(path, source, "format_version");
    try list.appendDiagnostic(.{
        .severity = .err,
        .code = manifestErrorCode(err),
        .message = manifestErrorMessage(err),
        .primary = span,
        .notes = &.{@errorName(err)},
        .help = manifestErrorHelp(err),
    });
}

fn appendFieldDiagnostic(
    list: *diagnostics.List,
    directory: []const u8,
    source: []const u8,
    field: []const u8,
    code: []const u8,
    message: []const u8,
    help: ?[]const u8,
) !void {
    const path = try manifestPath(list.arena.allocator(), directory);
    try list.appendDiagnostic(.{
        .severity = .err,
        .code = code,
        .message = message,
        .primary = fieldSpan(path, source, field),
        .help = help,
    });
}

fn appendSqlFilesDiagnostic(
    list: *diagnostics.List,
    directory: []const u8,
    source: []const u8,
    err: DiscoveryError,
) !void {
    const field = switch (err) {
        error.MissingUpgradeSql, error.UnexpectedBackendSql => "backends",
        error.MissingDowngradeSql => "reversible",
        error.DirectoryRevisionMismatch => "revision",
    };
    const code: []const u8 = switch (err) {
        error.MissingUpgradeSql => "M020",
        error.MissingDowngradeSql => "M021",
        error.UnexpectedBackendSql => "M022",
        error.DirectoryRevisionMismatch => "M010",
    };
    const message: []const u8 = switch (err) {
        error.MissingUpgradeSql => "revision has no effective upgrade SQL",
        error.MissingDowngradeSql => "reversible revision has no effective downgrade SQL",
        error.UnexpectedBackendSql => "revision contains SQL for a backend it does not target",
        error.DirectoryRevisionMismatch => "revision ID does not match its directory prefix",
    };
    const help: ?[]const u8 = switch (err) {
        error.MissingUpgradeSql => "add common or backend-specific `.up.sql`, or make this a SQL-free merge revision",
        error.MissingDowngradeSql => "add common or backend-specific `.down.sql`, or mark the revision irreversible",
        error.UnexpectedBackendSql => "remove the backend SQL file or add that backend to `.backends` with a transaction policy",
        error.DirectoryRevisionMismatch => "rename the directory or correct `.revision`",
    };
    try appendFieldDiagnostic(list, directory, source, field, code, message, help);
}

fn appendGraphDiagnostics(
    allocator: std.mem.Allocator,
    discovered: []const DiscoveredRevision,
    graph: []const Revision,
    list: *diagnostics.List,
) !void {
    if (graph.len == 0) {
        try list.appendDiagnostic(.{
            .severity = .err,
            .code = "M030",
            .message = "migration graph has no revisions",
            .help = "create an initial revision",
        });
        return;
    }

    var by_id: std.StringHashMapUnmanaged(usize) = .empty;
    defer by_id.deinit(allocator);
    var duplicate = try allocator.alloc(bool, graph.len);
    defer allocator.free(duplicate);
    @memset(duplicate, false);
    for (graph, 0..) |revision, index| {
        const entry = try by_id.getOrPut(allocator, revision.id);
        if (!entry.found_existing) {
            entry.value_ptr.* = index;
            continue;
        }
        duplicate[index] = true;
        duplicate[entry.value_ptr.*] = true;
        const labels = [_]diagnostics.Label{
            .{
                .span = revisionFieldSpan(&discovered[entry.value_ptr.*], "revision"),
                .message = "first definition",
            },
            .{
                .span = revisionFieldSpan(&discovered[index], "revision"),
                .message = "duplicate definition",
                .primary = true,
            },
        };
        try list.appendDiagnostic(.{
            .severity = .err,
            .code = "M031",
            .message = "migration revision ID is defined more than once",
            .primary = labels[1].span,
            .labels = &labels,
            .help = "assign a new unique 12-character revision ID",
        });
    }

    var has_missing_parent = false;
    for (graph, 0..) |revision, index| {
        for (revision.parents) |parent| {
            if (by_id.contains(parent)) continue;
            has_missing_parent = true;
            const note = try std.fmt.allocPrint(
                list.arena.allocator(),
                "unknown parent `{s}`",
                .{parent},
            );
            try list.appendDiagnostic(.{
                .severity = .err,
                .code = "M032",
                .message = "migration references a missing parent",
                .primary = revisionFieldSpan(&discovered[index], "parents"),
                .notes = &.{note},
                .help = "add the parent revision or correct `.parents`",
            });
        }
    }
    if (has_missing_parent or std.mem.indexOfScalar(bool, duplicate, true) != null) return;

    const indegree = try allocator.alloc(usize, graph.len);
    defer allocator.free(indegree);
    const is_head = try allocator.alloc(bool, graph.len);
    defer allocator.free(is_head);
    @memset(is_head, true);
    for (graph, 0..) |revision, index| {
        indegree[index] = revision.parents.len;
        for (revision.parents) |parent| is_head[by_id.get(parent).?] = false;
    }
    const processed = try allocator.alloc(bool, graph.len);
    defer allocator.free(processed);
    @memset(processed, false);
    for (0..graph.len) |_| {
        var selected: ?usize = null;
        for (graph, 0..) |revision, index| {
            if (processed[index] or indegree[index] != 0) continue;
            if (selected == null or std.mem.lessThan(u8, revision.id, graph[selected.?].id))
                selected = index;
        }
        const current = selected orelse break;
        processed[current] = true;
        for (graph, 0..) |revision, child_index| {
            if (processed[child_index]) continue;
            for (revision.parents) |parent| if (std.mem.eql(u8, parent, graph[current].id)) {
                indegree[child_index] -= 1;
                break;
            };
        }
    }
    if (std.mem.indexOfScalar(bool, processed, false) != null) {
        var labels: std.ArrayList(diagnostics.Label) = .empty;
        defer labels.deinit(allocator);
        for (processed, 0..) |done, index| if (!done) try labels.append(allocator, .{
            .span = revisionFieldSpan(&discovered[index], "parents"),
            .message = "participates in or depends on this cycle",
            .primary = labels.items.len == 0,
        });
        try list.appendDiagnostic(.{
            .severity = .err,
            .code = "M033",
            .message = "migration graph contains a cycle",
            .primary = labels.items[0].span,
            .labels = labels.items,
            .help = "remove a parent edge so the graph is acyclic",
        });
        return;
    }

    var head_count: usize = 0;
    for (is_head) |head| head_count += @intFromBool(head);
    if (head_count != 1) {
        const labels = try allocator.alloc(diagnostics.Label, head_count);
        defer allocator.free(labels);
        var label_index: usize = 0;
        for (is_head, 0..) |head, index| if (head) {
            labels[label_index] = .{
                .span = revisionFieldSpan(&discovered[index], "revision"),
                .message = "graph head",
                .primary = label_index == 0,
            };
            label_index += 1;
        };
        try list.appendDiagnostic(.{
            .severity = .err,
            .code = "M034",
            .message = "migration graph has multiple heads",
            .primary = labels[0].span,
            .labels = labels,
            .help = "add a merge revision whose parents are all current heads",
        });
    }
}

fn revisionFieldSpan(revision: *const DiscoveredRevision, field: []const u8) diagnostics.Span {
    return fieldSpan(revision.manifest_path, revision.manifest.source, field);
}

fn manifestPath(allocator: std.mem.Allocator, directory: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/revision.ziggy", .{directory});
}

fn fieldSpan(path: []const u8, source: []const u8, field: []const u8) diagnostics.Span {
    var pattern_buffer: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buffer, ".{s}", .{field}) catch field;
    const start = std.mem.indexOf(u8, source, pattern) orelse 0;
    const equals = std.mem.indexOfScalarPos(u8, source, start, '=') orelse start;
    var value_start = @min(equals + 1, source.len);
    while (value_start < source.len and std.ascii.isWhitespace(source[value_start])) : (value_start += 1) {}
    var end = value_start;
    while (end < source.len and source[end] != '\n' and source[end] != ',') : (end += 1) {}
    if (end == value_start) end = @min(value_start + 1, source.len);
    return diagnostics.spanAt(path, source, value_start, end);
}

fn manifestErrorField(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.UnsupportedFormatVersion => "format_version",
        error.InvalidRevisionId => "revision",
        error.InvalidParentId, error.SelfParent, error.DuplicateParent => "parents",
        error.EmptyDescription => "description",
        error.InvalidCreatedUtc => "created_utc",
        error.MissingBackend, error.DuplicateBackend => "backends",
        error.MissingTransactionPolicy, error.UnexpectedTransactionPolicy, error.UnsupportedSqliteTransaction => "transaction",
        else => null,
    };
}

fn manifestErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedFormatVersion => "M001",
        error.InvalidRevisionId => "M002",
        error.InvalidParentId => "M003",
        error.SelfParent => "M004",
        error.DuplicateParent => "M005",
        error.EmptyDescription => "M006",
        error.InvalidCreatedUtc => "M007",
        error.MissingBackend, error.DuplicateBackend => "M008",
        error.MissingTransactionPolicy, error.UnexpectedTransactionPolicy, error.UnsupportedSqliteTransaction => "M009",
        else => "M000",
    };
}

fn manifestErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedFormatVersion => "unsupported migration manifest format",
        error.InvalidRevisionId => "revision ID must be 12 lowercase hexadecimal characters",
        error.InvalidParentId => "parent revision ID is invalid",
        error.SelfParent => "revision cannot name itself as a parent",
        error.DuplicateParent => "revision names the same parent more than once",
        error.EmptyDescription => "revision description cannot be empty",
        error.InvalidCreatedUtc => "revision timestamp must use canonical UTC form",
        error.MissingBackend => "revision must target at least one backend",
        error.DuplicateBackend => "revision backend is listed more than once",
        error.MissingTransactionPolicy => "targeted backend is missing a transaction policy",
        error.UnexpectedTransactionPolicy => "untargeted backend has a transaction policy",
        error.UnsupportedSqliteTransaction => "SQLite revisions must use transaction policy `always`",
        error.UnknownField => "migration manifest contains an unknown field",
        error.DuplicateField => "migration manifest contains a duplicate field",
        error.MissingField => "migration manifest is missing a required field",
        error.Unexpected => "migration manifest contains an unexpected token",
        error.Overflow => "migration manifest integer is out of range",
        else => "migration manifest is invalid",
    };
}

fn manifestErrorHelp(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.UnsupportedFormatVersion => "use a supported manifest format version",
        error.InvalidRevisionId, error.InvalidParentId => "generate a new 12-character lowercase hexadecimal revision ID",
        error.SelfParent, error.DuplicateParent => "correct the `.parents` list",
        error.MissingBackend, error.DuplicateBackend => "list each targeted backend exactly once",
        error.MissingTransactionPolicy, error.UnexpectedTransactionPolicy, error.UnsupportedSqliteTransaction => "make `.transaction` match `.backends`",
        else => null,
    };
}

fn isZiggyError(err: anyerror) bool {
    return switch (err) {
        error.Unexpected, error.Overflow, error.DuplicateField, error.UnknownField, error.MissingField => true,
        else => false,
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
