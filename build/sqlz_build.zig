const std = @import("std");

pub const ToolOptions = struct {
    dependency: *std.Build.Dependency,
};

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
        return .{ .queries_module = queries_module, .check_step = &run.step };
    }
};

pub fn addTool(b: *std.Build, options: ToolOptions) *Tool {
    const tool = b.allocator.create(Tool) catch @panic("out of memory");
    tool.* = .{ .b = b, .dependency = options.dependency };
    return tool;
}
