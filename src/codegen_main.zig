const std = @import("std");
const codegen = @import("sqlz_codegen");

/// `sqlz-codegen <config> <output> [--codec <id> <import-name> <declaration>]...`
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return error.InvalidArguments;
    const config_path = args[1];
    const output_path = args[2];

    var bindings: std.ArrayList(codegen.CodecBinding) = .empty;
    var index: usize = 3;
    while (index < args.len) : (index += 4) {
        if (!std.mem.eql(u8, args[index], "--codec") or index + 3 >= args.len)
            return error.InvalidArguments;
        try bindings.append(arena, .{
            .id = args[index + 1],
            .import_name = args[index + 2],
            .declaration = args[index + 3],
        });
    }

    const project_path = std.fs.path.dirname(config_path) orelse ".";
    const config_name = std.fs.path.basename(config_path);
    var project_dir = try std.Io.Dir.cwd().openDir(init.io, project_path, .{ .iterate = true });
    defer project_dir.close(init.io);
    const generated = try codegen.generateProjectWithCodecs(
        allocator,
        init.io,
        project_dir,
        config_name,
        bindings.items,
    );
    defer allocator.free(generated);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = generated });
}
