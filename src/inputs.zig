//! The trust boundary between a project directory and the checker. Every file
//! the checker reads goes through `Inputs`, which keeps reads inside the
//! canonical project root and charges them against the configured limits
//! before anything is parsed or generated.
const std = @import("std");
const diagnostics = @import("sqlz_diagnostics");
const source = @import("sqlz_source");

pub const Error = error{
    PathEscapesProject,
    SymlinkedDirectory,
    SourceTooLarge,
    RegisteredSourceLimitExceeded,
    RevisionLimitExceeded,
    QueryLimitExceeded,
    TokenLimitExceeded,
    NestingLimitExceeded,
    NotRegularFile,
    InvalidUtf8,
};

/// The project-level limits a discovery pass enforces. Defaults match the
/// documented `sqlz.ziggy` defaults so tests and tools share one baseline.
pub const Limits = struct {
    source_bytes: u64 = 16 * 1024 * 1024,
    registered_source_bytes: u64 = 512 * 1024 * 1024,
    revisions: u32 = 10_000,
    queries: u32 = 100_000,
    tokens_per_source: u64 = 1_000_000,
    nesting_depth: u32 = 256,

    /// Selects the input limits from a parsed `sqlz.ziggy` `.limits` value.
    /// Taken structurally so this module stays independent of the config parser.
    pub fn fromConfig(limits: anytype) Limits {
        return .{
            .source_bytes = limits.source_bytes,
            .registered_source_bytes = limits.registered_source_bytes,
            .revisions = limits.revisions,
            .queries = limits.queries,
            .tokens_per_source = limits.tokens_per_source,
            .nesting_depth = limits.nesting_depth,
        };
    }
};

pub const Inputs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: std.Io.Dir,
    /// Canonical absolute path of `project_dir`; every read must resolve under it.
    project_path: []u8,
    limits: Limits,
    registered_bytes: u64 = 0,
    query_count: u64 = 0,
    /// Project-relative path of the input that crossed a boundary, kept so the
    /// caller can point its diagnostic at the offending file.
    failure_path: ?[]u8 = null,
    /// Where in that input the boundary was crossed, when it was crossed
    /// inside the text rather than by the file as a whole.
    failure_span: ?diagnostics.Span = null,
    failure_excerpt: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        project_dir: std.Io.Dir,
        limits: Limits,
    ) !Inputs {
        std.debug.assert(limits.source_bytes > 0);
        std.debug.assert(limits.registered_source_bytes > 0);
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try project_dir.realPath(io, &buffer);
        return .{
            .allocator = allocator,
            .io = io,
            .project_dir = project_dir,
            .project_path = try allocator.dupe(u8, buffer[0..length]),
            .limits = limits,
        };
    }

    pub fn deinit(self: *Inputs) void {
        if (self.failure_path) |path| self.allocator.free(path);
        if (self.failure_excerpt) |excerpt| self.allocator.free(excerpt);
        self.allocator.free(self.project_path);
        self.* = undefined;
    }

    /// Opens a configured root. The root may be spelled through a symlink, but
    /// its canonical location must stay inside the project.
    pub fn openRoot(self: *Inputs, path: []const u8) !std.Io.Dir {
        var root = self.project_dir.openDir(self.io, path, .{ .iterate = true }) catch |err| {
            try self.fail(path);
            return err;
        };
        errdefer root.close(self.io);
        // Resolve the opened handle rather than the path, so a link swapped
        // in after the check cannot redirect what is read.
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try root.realPath(self.io, &buffer);
        if (!within(self.project_path, buffer[0..length])) {
            try self.fail(path);
            return error.PathEscapesProject;
        }
        return root;
    }

    /// Charges bytes the caller read itself, such as the configuration file,
    /// against the per-source and total limits.
    pub fn register(self: *Inputs, path: []const u8, length: usize) !void {
        self.charge(length) catch |err| {
            try self.fail(path);
            return err;
        };
    }

    fn charge(self: *Inputs, length: usize) Error!void {
        if (length > self.limits.source_bytes) return error.SourceTooLarge;
        if (length > self.limits.registered_source_bytes - self.registered_bytes)
            return error.RegisteredSourceLimitExceeded;
        self.registered_bytes += length;
    }

    /// Reads one source file. The opened handle, not the path, is checked
    /// against the project root, so a link swapped in after the check cannot
    /// redirect the read. The read is bounded by whichever limit is closer, so
    /// an oversized file fails before it is buffered whole.
    pub fn readFile(
        self: *Inputs,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        sub_path: []const u8,
    ) ![]u8 {
        // Opening a FIFO blocks until a writer appears, so only regular files
        // are opened at all.
        const stat = dir.statFile(self.io, sub_path, .{}) catch |err| {
            try self.failAt(dir, sub_path);
            return err;
        };
        if (stat.kind != .file) {
            try self.failAt(dir, sub_path);
            return error.NotRegularFile;
        }
        var file = dir.openFile(self.io, sub_path, .{}) catch |err| {
            try self.failAt(dir, sub_path);
            return err;
        };
        defer file.close(self.io);
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try file.realPath(self.io, &buffer);
        if (!within(self.project_path, buffer[0..length])) {
            try self.failAt(dir, sub_path);
            return error.PathEscapesProject;
        }

        const remaining = self.limits.registered_source_bytes - self.registered_bytes;
        const bound = @min(self.limits.source_bytes, remaining);
        const bound_bytes = std.math.cast(usize, bound) orelse std.math.maxInt(usize) - 1;
        var reader = file.reader(self.io, &.{});
        // `limited(n)` fails once `n` bytes are reached, so a file of exactly
        // the limit needs one byte of headroom to be accepted.
        const contents = reader.interface.allocRemaining(allocator, .limited(bound_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => {
                try self.failAt(dir, sub_path);
                if (bound == self.limits.source_bytes) return error.SourceTooLarge;
                return error.RegisteredSourceLimitExceeded;
            },
            error.ReadFailed => return reader.err.?,
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer allocator.free(contents);
        self.charge(contents.len) catch |err| {
            try self.failAt(dir, sub_path);
            return err;
        };
        // Every consumer decodes its source as UTF-8, so a malformed byte
        // fails here, once, at its exact offset.
        if (source.invalidUtf8Offset(contents)) |offset| {
            try self.failInside(dir, sub_path, contents, offset, offset + 1);
            return error.InvalidUtf8;
        }
        return contents;
    }

    /// Records that `text`, read from `sub_path` in `dir`, crossed a boundary
    /// at `start..end`, such as a token or nesting limit found while lexing.
    pub fn failInside(
        self: *Inputs,
        dir: std.Io.Dir,
        sub_path: []const u8,
        text: []const u8,
        start: usize,
        end: usize,
    ) !void {
        std.debug.assert(start <= end);
        if (self.failure_path != null) return;
        try self.failAt(dir, sub_path);
        const span = diagnostics.spanAt("", text, start, end);
        self.failure_excerpt = try self.allocator.dupe(u8, span.excerpt.?);
        self.failure_span = span;
        self.failure_span.?.excerpt = self.failure_excerpt;
    }

    /// Like `readFile`, but a missing file reads as empty.
    pub fn readOptional(
        self: *Inputs,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        sub_path: []const u8,
    ) ![]u8 {
        dir.access(self.io, sub_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return allocator.dupe(u8, ""),
            else => return err,
        };
        return self.readFile(allocator, dir, sub_path);
    }

    /// Resolves the kind of a directory entry. `candidate` says whether the
    /// caller would read the entry if it is a file. Symlinked directories are
    /// never followed, since a silently skipped directory would drop sources
    /// and a followed one could loop or reach the same sources twice. A
    /// dangling candidate fails rather than being skipped. Containment of a
    /// candidate is checked when `readFile` opens it; any other symlinked file
    /// is never read, so where it points does not matter.
    pub fn entryKind(
        self: *Inputs,
        dir: std.Io.Dir,
        basename: []const u8,
        kind: std.Io.File.Kind,
        candidate: bool,
    ) !std.Io.File.Kind {
        if (kind != .sym_link) return kind;
        const stat = dir.statFile(self.io, basename, .{}) catch |err| {
            if (!candidate) return .sym_link;
            try self.failAt(dir, basename);
            return err;
        };
        if (stat.kind == .directory) {
            try self.failAt(dir, basename);
            return error.SymlinkedDirectory;
        }
        return stat.kind;
    }

    /// Checks the revision directories found in the migration root `dir`.
    pub fn countRevisions(self: *Inputs, dir: std.Io.Dir, count: usize) !void {
        if (count > self.limits.revisions) {
            try self.failAt(dir, "");
            return error.RevisionLimitExceeded;
        }
    }

    /// Charges `count` queries discovered at `sub_path` in `dir` against the
    /// project limit.
    pub fn countQueries(self: *Inputs, dir: std.Io.Dir, sub_path: []const u8, count: usize) !void {
        if (count > self.limits.queries - self.query_count) {
            try self.failAt(dir, sub_path);
            return error.QueryLimitExceeded;
        }
        self.query_count += count;
    }

    /// Appends the diagnostic for a boundary error recorded by this pass.
    /// Returns false for any other error, which the caller reports itself.
    pub fn appendDiagnostic(self: *const Inputs, list: *diagnostics.List, err: anyerror) !bool {
        if (!isBoundaryError(err)) return false;
        const path = self.failure_path orelse ".";
        var primary: diagnostics.Span = self.failure_span orelse .{
            .path = "",
            .start = .{ .offset = 0, .line = 1, .column = 1 },
            .end = .{ .offset = 0, .line = 1, .column = 1 },
        };
        primary.path = path;
        try list.appendDiagnostic(.{
            .severity = .err,
            .code = diagnostics.codeForError(err),
            .message = diagnostics.messageForError(err),
            .primary = primary,
            .help = help(err),
        });
        return true;
    }

    fn failAt(self: *Inputs, dir: std.Io.Dir, sub_path: []const u8) !void {
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = dir.realPath(self.io, &buffer) catch return self.fail(sub_path);
        const directory = buffer[0..length];
        if (!within(self.project_path, directory)) return self.fail(sub_path);
        const relative = std.mem.trimStart(u8, directory[self.project_path.len..], &.{std.fs.path.sep});
        if (relative.len == 0) return self.fail(if (sub_path.len == 0) "." else sub_path);
        const joined = try std.fs.path.join(self.allocator, &.{ relative, sub_path });
        defer self.allocator.free(joined);
        try self.fail(joined);
    }

    fn fail(self: *Inputs, path: []const u8) !void {
        // The first boundary error stops discovery, so a later one never
        // replaces the path it reports.
        if (self.failure_path != null) return;
        self.failure_path = try self.allocator.dupe(u8, path);
    }
};

pub fn isBoundaryError(err: anyerror) bool {
    return switch (err) {
        error.PathEscapesProject,
        error.SymlinkedDirectory,
        error.SourceTooLarge,
        error.RegisteredSourceLimitExceeded,
        error.RevisionLimitExceeded,
        error.QueryLimitExceeded,
        error.TokenLimitExceeded,
        error.NestingLimitExceeded,
        error.NotRegularFile,
        error.InvalidUtf8,
        => true,
        else => false,
    };
}

fn help(err: anyerror) []const u8 {
    return switch (err) {
        error.PathEscapesProject => "keep project sources inside the directory that holds `sqlz.ziggy`",
        error.SymlinkedDirectory => "replace the directory symlink with a real directory, or configure its target as a root",
        error.SourceTooLarge => "split the file or raise `.limits.source_bytes`",
        error.RegisteredSourceLimitExceeded => "raise `.limits.registered_source_bytes` or narrow the configured roots",
        error.RevisionLimitExceeded => "raise `.limits.revisions`",
        error.QueryLimitExceeded => "raise `.limits.queries` or narrow the configured roots",
        error.TokenLimitExceeded => "split the source or raise `.limits.tokens_per_source`",
        error.NestingLimitExceeded => "flatten the expression or raise `.limits.nesting_depth`",
        error.NotRegularFile => "replace it with a regular file",
        error.InvalidUtf8 => "save the file as UTF-8",
        else => unreachable,
    };
}

fn within(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    const sep = std.fs.path.sep;
    return root.len > 0 and (root[root.len - 1] == sep or path[root.len] == sep);
}
