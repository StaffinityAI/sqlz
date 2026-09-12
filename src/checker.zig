const std = @import("std");
const parser = @import("sqlz_parser");
const catalog = @import("sqlz_catalog");
const migrations = @import("sqlz_migrations");

pub const MigrationInput = struct {
    revision: migrations.Revision,
    common_sql: []const u8 = "",
    sqlite_sql: []const u8 = "",
};

pub const Error = migrations.Error || parser.ParseError || catalog.Error;

pub fn replaySqlite(
    allocator: std.mem.Allocator,
    inputs: []const MigrationInput,
) Error!catalog.Catalog {
    const revisions = try allocator.alloc(migrations.Revision, inputs.len);
    defer allocator.free(revisions);
    for (inputs, revisions) |input, *revision| revision.* = input.revision;

    var order = try migrations.validateAndOrder(allocator, revisions);
    defer order.deinit();

    var schema = catalog.Catalog.init(allocator);
    errdefer schema.deinit();
    for (order.indices) |index| {
        const input = inputs[index];
        try applySqliteRevisionAtomic(
            &schema,
            allocator,
            input.common_sql,
            input.sqlite_sql,
        );
    }
    return schema;
}

pub fn replayDiscoveredSqlite(
    allocator: std.mem.Allocator,
    discovery: *const migrations.Discovery,
) Error!catalog.Catalog {
    const inputs = try allocator.alloc(MigrationInput, discovery.revisions.len);
    defer allocator.free(inputs);
    for (discovery.revisions, inputs) |revision, *input| {
        const manifest = revision.manifest.manifest();
        input.* = .{
            .revision = .{ .id = manifest.revision, .parents = manifest.parents },
            .common_sql = revision.common_up,
            .sqlite_sql = revision.sqlite_up,
        };
    }
    return replaySqlite(allocator, inputs);
}

pub fn applySqliteRevisionAtomic(
    schema: *catalog.Catalog,
    allocator: std.mem.Allocator,
    common_sql: []const u8,
    sqlite_sql: []const u8,
) (parser.ParseError || catalog.Error)!void {
    var staged = try schema.clone(allocator);
    errdefer staged.deinit();
    try parseAndApply(&staged, allocator, common_sql);
    try parseAndApply(&staged, allocator, sqlite_sql);

    schema.deinit();
    schema.* = staged;
}

fn parseAndApply(
    schema: *catalog.Catalog,
    allocator: std.mem.Allocator,
    sql: []const u8,
) (parser.ParseError || catalog.Error)!void {
    if (std.mem.trim(u8, sql, &std.ascii.whitespace).len == 0) return;
    var parsed = try parser.parse(allocator, sql);
    defer parsed.deinit();
    try schema.applyParserJson(parsed.ast_json);
}
