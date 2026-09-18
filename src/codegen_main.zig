const std = @import("std");
const codegen = @import("sqlz_codegen");
const diagnostics = @import("sqlz_diagnostics");

/// `sqlz-codegen <config> <output> [--codec <id> <import-name> <declaration>]...`
pub fn main(init: std.process.Init) void {
    const format = detectFormat(init) catch .human;
    run(init) catch |err| {
        renderFailure(init, format, err);
        std.process.exit(diagnostics.exitCode(err));
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return error.InvalidArguments;
    const config_path = args[1];
    const output_path = args[2];

    var bindings: std.ArrayList(codegen.CodecBinding) = .empty;
    var index: usize = 3;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--format")) {
            if (index + 1 >= args.len or parseFormat(args[index + 1]) == null)
                return error.InvalidArguments;
            index += 2;
            continue;
        }
        if (!std.mem.eql(u8, args[index], "--codec") or index + 3 >= args.len)
            return error.InvalidArguments;
        try bindings.append(arena, .{
            .id = args[index + 1],
            .import_name = args[index + 2],
            .declaration = args[index + 3],
        });
        index += 4;
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

fn detectFormat(init: std.process.Init) !diagnostics.Format {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args, 0..) |arg, index| {
        if (!std.mem.eql(u8, arg, "--format")) continue;
        if (index + 1 >= args.len) return error.InvalidArguments;
        return parseFormat(args[index + 1]) orelse error.InvalidArguments;
    }
    return .human;
}

fn parseFormat(value: []const u8) ?diagnostics.Format {
    if (std.mem.eql(u8, value, "human")) return .human;
    if (std.mem.eql(u8, value, "json")) return .json;
    return null;
}

fn renderFailure(init: std.process.Init, format: diagnostics.Format, err: anyerror) void {
    const note = @errorName(err);
    const diagnostic: diagnostics.Diagnostic = .{
        .severity = .err,
        .code = diagnostics.codeForError(err),
        .message = diagnostics.messageForError(err),
        .notes = &.{note},
        .help = if (err == error.InvalidArguments)
            "usage: sqlz-codegen <config> <output> [--format human|json] [--codec ID IMPORT DECL]..."
        else
            null,
    };
    var buffer: [4096]u8 = undefined;
    var file_writer = switch (format) {
        .human => std.Io.File.stderr().writer(init.io, &buffer),
        .json => std.Io.File.stdout().writer(init.io, &buffer),
    };
    const writer = &file_writer.interface;
    diagnostics.render(writer, diagnostic, format) catch return;
    writer.flush() catch {};
}
