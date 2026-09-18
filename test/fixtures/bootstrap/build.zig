const std = @import("std");
const sqlz_build = @import("sqlz_build");

pub fn build(b: *std.Build) void {
    const sqlz = b.dependency("sqlz_build", .{
        .sqlite = true,
        .postgres = true,
    });
    const tool = sqlz_build.addTool(b, .{ .dependency = sqlz });
    _ = tool.addProject(.{
        .name = "bootstrap",
        .config = b.path("sqlz.ziggy"),
    });
}
