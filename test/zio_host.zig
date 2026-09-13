//! The host pipeline is as runtime-agnostic as the runtime handles are: every
//! file it touches goes through the caller's `std.Io`. This drives the whole
//! codegen pipeline — configuration, migration replay, query discovery,
//! checking, and emission — on a zio-backed interface rather than `Threaded`.

const std = @import("std");
const zio = @import("zio");
const codegen = @import("sqlz_codegen");

fn generate(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var project_dir = try std.Io.Dir.cwd().openDir(io, "test/fixtures/codegen", .{ .iterate = true });
    defer project_dir.close(io);
    return codegen.generateProject(allocator, io, project_dir, "sqlz.ziggy");
}

test "the codegen pipeline runs on a zio std.Io" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const generated = try generate(std.testing.allocator, runtime.io());
    defer std.testing.allocator.free(generated);

    try std.testing.expect(generated.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, generated, "sqlz.Query") != null);
}

test "zio and Threaded produce byte-identical output" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const via_zio = try generate(std.testing.allocator, runtime.io());
    defer std.testing.allocator.free(via_zio);
    const via_threaded = try generate(std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(via_threaded);

    // Generated bindings are cached build outputs; the interface behind the
    // file reads must not perturb them.
    try std.testing.expectEqualStrings(via_threaded, via_zio);
}

test "the pipeline runs inside a zio task" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var task = try runtime.spawn(generate, .{ std.testing.allocator, runtime.io() });
    const generated = try task.join();
    defer std.testing.allocator.free(generated);
    try std.testing.expect(generated.len > 0);
}
