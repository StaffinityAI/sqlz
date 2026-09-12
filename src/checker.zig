const std = @import("std");
const parser = @import("sqlz_parser");
const catalog = @import("sqlz_catalog");
const migrations = @import("sqlz_migrations");
const ir = @import("sqlz_ir");
const analysis = @import("sqlz_analysis");
const query_files = @import("sqlz_query_files");

pub const MigrationInput = struct {
    revision: migrations.Revision,
    common_sql: []const u8 = "",
    sqlite_sql: []const u8 = "",
};

pub const Error = migrations.Error || parser.ParseError || catalog.Error || ir.Error || analysis.Error || error{
    BackendNotSelected,
    UnexpectedResultColumns,
    MissingResultColumns,
};

pub const CheckedQuery = struct {
    parsed: parser.ParseResult,
    query: ir.Query,
    analysis: analysis.Analysis,

    pub fn deinit(self: *CheckedQuery) void {
        self.analysis.deinit();
        self.query.deinit();
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub fn checkNamedSqlite(
    allocator: std.mem.Allocator,
    schema: *const catalog.Catalog,
    source: *const query_files.Source,
) Error!CheckedQuery {
    if (!source.backends.sqlite) return error.BackendNotSelected;
    var parsed = try parser.parseSqlite(allocator, source.sql);
    errdefer parsed.deinit();
    var query = try ir.adapt(allocator, parsed.tree, parsed.rewritten.names);
    errdefer query.deinit();
    const produces_rows = query.projections.len != 0;
    if (source.cardinality == .exec and produces_rows) return error.UnexpectedResultColumns;
    if (source.cardinality != .exec and !produces_rows) return error.MissingResultColumns;
    const analyzed = try analysis.analyze(allocator, schema, &query);
    return .{ .parsed = parsed, .query = query, .analysis = analyzed };
}

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
    try parseAndApply(&staged, allocator, common_sql, false);
    try parseAndApply(&staged, allocator, sqlite_sql, true);

    schema.deinit();
    schema.* = staged;
}

fn parseAndApply(
    schema: *catalog.Catalog,
    allocator: std.mem.Allocator,
    sql: []const u8,
    sqlite: bool,
) (parser.ParseError || catalog.Error)!void {
    if (std.mem.trim(u8, sql, &std.ascii.whitespace).len == 0) return;
    var parsed = if (sqlite)
        try parser.parseSqlite(allocator, sql)
    else
        try parser.parse(allocator, sql);
    defer parsed.deinit();
    try schema.applyParserTree(parsed.tree);
}
