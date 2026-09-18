const std = @import("std");

pub const ToolOptions = struct {
    dependency: *std.Build.Dependency,
};

pub const RuntimeOptions = struct {
    sqlite: bool = false,
    postgres: bool = false,
    postgres_tls: bool = false,
};

pub const RuntimeOptionsError = error{PostgresTlsRequiresPostgres};

pub fn validateRuntimeOptions(options: RuntimeOptions) RuntimeOptionsError!void {
    if (options.postgres_tls and !options.postgres)
        return error.PostgresTlsRequiresPostgres;
}

/// Binds one codec ID from `sqlz.ziggy` to the Zig declaration generated code
/// should name. IDs and bindings are one to one: a configured ID without a
/// binding, or a binding the configuration never declares, fails the check.
pub const CodecBinding = struct {
    id: []const u8,
    module: *std.Build.Module,
    declaration: []const u8,
};

pub const ProjectOptions = struct {
    name: []const u8,
    config: std.Build.LazyPath,
    codecs: []const CodecBinding = &.{},
};

pub const Project = struct {
    runtime_module: *std.Build.Module,
    queries_module: *std.Build.Module,
    check_step: *std.Build.Step,
};

pub const Tool = struct {
    b: *std.Build,
    dependency: *std.Build.Dependency,
    names: std.StringHashMapUnmanaged(void) = .empty,

    pub fn addProject(self: *Tool, options: ProjectOptions) Project {
        const name = self.b.dupe(options.name);
        const entry = self.names.getOrPut(self.b.allocator, name) catch @panic("out of memory");
        if (entry.found_existing) @panic("duplicate sqlz project name");

        const run = self.b.addRunArtifact(self.dependency.artifact("sqlz-codegen"));
        run.setName(self.b.fmt("check sqlz project {s}", .{name}));
        run.addFileArg(options.config);
        const generated = run.addOutputFileArg(self.b.fmt("{s}_queries.zig", .{name}));
        _ = run.step.addDirectoryWatchInput(options.config.dirname()) catch @panic("out of memory");
        // The tool discovers its own inputs — migrations, `.sql` files, and the
        // Zig roots — so the config file alone is not what the result depends
        // on. Register every candidate input, or an edited query would keep a
        // cached module and skip its check entirely.
        addProjectInputs(self.b, run, options.config);

        var imports: std.ArrayList(std.Build.Module.Import) = .empty;
        imports.append(
            self.b.allocator,
            .{ .name = "sqlz", .module = self.dependency.module("sqlz") },
        ) catch @panic("out of memory");
        var codec_ids: std.StringHashMapUnmanaged(void) = .empty;
        defer codec_ids.deinit(self.b.allocator);
        for (options.codecs) |codec| {
            const codec_entry = codec_ids.getOrPut(self.b.allocator, codec.id) catch @panic("out of memory");
            if (codec_entry.found_existing) @panic("duplicate sqlz codec binding");
            const import_name = self.b.fmt("sqlz_codec_{s}", .{codec.id});
            run.addArg("--codec");
            run.addArg(codec.id);
            run.addArg(import_name);
            run.addArg(codec.declaration);
            imports.append(
                self.b.allocator,
                .{ .name = import_name, .module = codec.module },
            ) catch @panic("out of memory");
        }

        const queries_module = self.b.createModule(.{
            .root_source_file = generated,
            .imports = imports.items,
        });
        return .{
            .runtime_module = self.dependency.module("sqlz"),
            .queries_module = queries_module,
            .check_step = &run.step,
        };
    }
};

/// Registers every file under a project directory that the checker may read as
/// an input of `run`, so adding, editing, or removing one re-runs the check.
/// Only works for a source-tree path; a generated configuration keeps the
/// narrower dependency on the file itself.
pub fn addProjectInputs(b: *std.Build, run: *std.Build.Step.Run, config: std.Build.LazyPath) void {
    const root = switch (config) {
        .src_path => |src| std.fs.path.dirname(src.sub_path) orelse ".",
        else => return,
    };
    var directory = b.build_root.handle.openDir(b.graph.io, root, .{ .iterate = true }) catch return;
    defer directory.close(b.graph.io);
    var walker = directory.walk(b.allocator) catch @panic("out of memory");
    defer walker.deinit();
    while (walker.next(b.graph.io) catch return) |entry| {
        if (entry.kind != .file or skipPath(entry.path) or !checkerInput(entry.basename)) continue;
        run.addFileInput(b.path(b.pathJoin(&.{ root, entry.path })));
    }
}

fn checkerInput(basename: []const u8) bool {
    const extensions = [_][]const u8{ ".sql", ".zig", ".ziggy" };
    for (extensions) |extension| if (std.mem.endsWith(u8, basename, extension)) return true;
    return false;
}

fn skipPath(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (components.next()) |component| {
        if (component.len > 0 and component[0] == '.') return true;
        if (std.mem.eql(u8, component, "zig-out") or
            std.mem.eql(u8, component, "zig-cache") or
            std.mem.eql(u8, component, "zig-pkg")) return true;
    }
    return false;
}

pub fn addTool(b: *std.Build, options: ToolOptions) *Tool {
    const tool = b.allocator.create(Tool) catch @panic("out of memory");
    tool.* = .{ .b = b, .dependency = options.dependency };
    return tool;
}
