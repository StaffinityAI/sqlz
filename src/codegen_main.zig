const std = @import("std");
const codegen = @import("sqlz_codegen");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;
    const config_path = args[1];
    const output_path = args[2];
    const project_path = std.fs.path.dirname(config_path) orelse ".";
    const config_name = std.fs.path.basename(config_path);
    var project_dir = try std.Io.Dir.cwd().openDir(init.io, project_path, .{ .iterate = true });
    defer project_dir.close(init.io);
    const generated = try codegen.generateProject(allocator, init.io, project_dir, config_name);
    defer allocator.free(generated);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = generated });
}
