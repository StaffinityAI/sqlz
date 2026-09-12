const sqlz = @import("sqlz");

pub fn unwrap(result: anytype) !@TypeOf(result.ok) {
    return switch (result) {
        .ok => |value| value,
        .err => |*err| {
            defer err.deinit();
            return error.SqlzQueryFailed;
        },
    };
}

pub fn openMemory(allocator: @import("std").mem.Allocator) !sqlz.sqlite.Conn {
    return sqlz.sqlite.open(allocator, ":memory:");
}
