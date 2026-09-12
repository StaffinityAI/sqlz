const std = @import("std");

pub const ToolOptions = struct {
    dependency: *std.Build.Dependency,
};

pub const ProjectOptions = struct {
    name: []const u8,
    config: std.Build.LazyPath,
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

        const queries_module = self.b.createModule(.{
            .root_source_file = generated,
            .imports = &.{.{ .name = "sqlz", .module = self.dependency.module("sqlz") }},
        });
        return .{ .queries_module = queries_module, .check_step = &run.step };
    }
};

pub fn addTool(b: *std.Build, options: ToolOptions) *Tool {
    const tool = b.allocator.create(Tool) catch @panic("out of memory");
    tool.* = .{ .b = b, .dependency = options.dependency };
    return tool;
}
