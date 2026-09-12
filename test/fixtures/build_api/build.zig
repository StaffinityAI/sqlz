const std = @import("std");
const sqlz_build = @import("sqlz_build");

pub fn build(b: *std.Build) void {
    const sqlz = b.dependency("sqlz_build", .{});
    const tool = sqlz_build.addTool(b, .{ .dependency = sqlz });
    const project = tool.addProject(.{
        .name = "fixture",
        .config = b.path("sqlz.ziggy"),
    });
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "queries", .module = project.queries_module }},
        }),
    });
    const run = b.addRunArtifact(tests);
    run.step.dependOn(project.check_step);
    b.default_step.dependOn(&run.step);
}
