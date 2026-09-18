const std = @import("std");
const options = @import("sqlz_cli_options");

pub fn main(init: std.process.Init) !void {
    if (comptime options.bootstrap_enabled) {
        return @import("sqlz_bootstrap_cli").main(init);
    }
    std.log.err("SQLite-to-PostgreSQL bootstrap requires -Dsqlite=true -Dpostgres=true", .{});
    return error.BootstrapBackendsDisabled;
}
