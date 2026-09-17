const std = @import("std");
const parser = @import("sqlz_parser");
const catalog = @import("sqlz_catalog");
const migrations = @import("sqlz_migrations");
const ir = @import("sqlz_ir");
const analysis = @import("sqlz_analysis");
const query_files = @import("sqlz_query_files");

pub const SqliteDialect = parser.SqliteDialect;
pub const SqliteProfile = parser.SqliteProfile;

pub const MigrationInput = struct {
    revision: migrations.Revision,
    common_sql: []const u8 = "",
    sqlite_sql: []const u8 = "",
};

pub const Error = migrations.Error || parser.ParseError || catalog.Error || ir.Error || analysis.Error || error{
    BackendNotSelected,
    UnknownCodec,
    UnknownCodecTarget,
    IncompatibleCodec,
    UnexpectedResultColumns,
    MissingResultColumns,
    MissingDeclaredField,
    UnexpectedDeclaredField,
    DeclaredFieldOrder,
    DeclaredTypeMismatch,
    DeclaredNullabilityMismatch,
    MissingCodecForDeclaredType,
    UninferredDeclaredType,
    MissingDeclaredRow,
    UnexpectedDeclaredRow,
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
    return checkNamedSqliteWithDialect(allocator, schema, source, .{});
}

/// One registered codec as the checker sees it: a stable ID plus the scalar
/// type its declared database patterns resolve to. The Zig declaration behind
/// the ID is a build-time binding the generator resolves, not a checker input.
pub const CodecInfo = struct {
    id: []const u8,
    sqlite_type: analysis.ScalarType = .unknown,
};

pub fn checkNamedSqliteWithDialect(
    allocator: std.mem.Allocator,
    schema: *const catalog.Catalog,
    source: *const query_files.Source,
    dialect: SqliteDialect,
) Error!CheckedQuery {
    return checkNamedSqliteWithCodecs(allocator, schema, source, dialect, &.{});
}

pub fn checkNamedSqliteWithCodecs(
    allocator: std.mem.Allocator,
    schema: *const catalog.Catalog,
    source: *const query_files.Source,
    dialect: SqliteDialect,
    codecs: []const CodecInfo,
) Error!CheckedQuery {
    if (!source.backends.sqlite) return error.BackendNotSelected;
    var parsed = try parser.parseSqliteWithDialect(allocator, source.sql, dialect);
    errdefer parsed.deinit();
    var query = try ir.adapt(allocator, parsed.tree, parsed.rewritten.names);
    errdefer query.deinit();
    const produces_rows = query.projections.len != 0;
    if (source.cardinality == .exec and produces_rows) return error.UnexpectedResultColumns;
    if (source.cardinality != .exec and !produces_rows) return error.MissingResultColumns;
    var analyzed = try analysis.analyze(allocator, schema, &query);
    errdefer analyzed.deinit();
    try applyCodecs(&analyzed, source, codecs);
    try verifyDeclaration(&analyzed, source);
    return .{ .parsed = parsed, .query = query, .analysis = analyzed };
}

/// Compares an embedded declaration's `.params` and `.row` structs against
/// what the SQL actually produces. A `.sql` file declares nothing, so this is
/// a no-op for it.
fn verifyDeclaration(
    analyzed: *const analysis.Analysis,
    source: *const query_files.Source,
) Error!void {
    const declared = source.declared;
    if (!declared.embedded) return;
    if (source.cardinality == .exec) {
        if (declared.row_present) return error.UnexpectedDeclaredRow;
    } else if (!declared.row_present) return error.MissingDeclaredRow;

    if (declared.params) |fields| try verifyFields(fields, analyzed.parameters, .parameter);
    if (declared.row) |fields| try verifyFields(fields, analyzed.columns, .result);
}

const ValueKind = enum { parameter, result };

fn verifyFields(
    declared: []const query_files.DeclaredField,
    values: []const analysis.ResultColumn,
    kind: ValueKind,
) Error!void {
    if (declared.len < values.len) return error.MissingDeclaredField;
    if (declared.len > values.len) return error.UnexpectedDeclaredField;
    for (declared, values) |field, value| {
        if (!std.mem.eql(u8, field.name, value.name)) {
            // Declaring the right fields in the wrong order is its own mistake:
            // parameters bind and columns decode by position.
            if (containsName(values, field.name)) return error.DeclaredFieldOrder;
            return error.UnexpectedDeclaredField;
        }
        try verifyNullability(field, value, kind);
        try verifyType(field, value);
    }
}

fn verifyNullability(
    field: query_files.DeclaredField,
    value: analysis.ResultColumn,
    kind: ValueKind,
) Error!void {
    switch (kind) {
        // A nullable column cannot decode into a non-optional field, but
        // widening a known non-null column to optional is the author's choice.
        .result => if (value.nullable and !field.optional)
            return error.DeclaredNullabilityMismatch,
        // A parameter the query requires must not be declared optional, or the
        // declaration promises a NULL the statement cannot accept. Narrowing a
        // nullable parameter to a definite value is safe.
        .parameter => if (!value.nullable and field.optional)
            return error.DeclaredNullabilityMismatch,
    }
}

fn verifyType(field: query_files.DeclaredField, value: analysis.ResultColumn) Error!void {
    const declared_scalar = analysis.classifyZigType(field.type_text);
    if (value.codec != null) {
        // A codec maps the application's own type; a built-in spelling there
        // means the codec was pinned to the wrong field.
        if (declared_scalar != null) return error.DeclaredTypeMismatch;
        return;
    }
    if (declared_scalar == null) return error.MissingCodecForDeclaredType;
    if (value.scalar_type == .unknown) return error.UninferredDeclaredType;
    if (!analysis.scalarAccepts(declared_scalar.?, value.scalar_type))
        return error.DeclaredTypeMismatch;
}

fn containsName(values: []const analysis.ResultColumn, name: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value.name, name)) return true;
    return false;
}

/// Resolves the query's codec directives against the project's registered
/// codecs and records them on the analyzed parameters and columns.
fn applyCodecs(
    analyzed: *analysis.Analysis,
    source: *const query_files.Source,
    codecs: []const CodecInfo,
) Error!void {
    const storage = analyzed.arena.allocator();
    for (source.param_codecs) |override|
        try applyCodec(storage, analyzed.parameters, override, codecs);
    for (source.column_codecs) |override|
        try applyCodec(storage, analyzed.columns, override, codecs);
}

fn applyCodec(
    storage: std.mem.Allocator,
    values: []analysis.ResultColumn,
    override: query_files.CodecOverride,
    codecs: []const CodecInfo,
) Error!void {
    const codec = findCodec(codecs, override.codec) orelse return error.UnknownCodec;
    const target = findValue(values, override.name) orelse return error.UnknownCodecTarget;
    // The codec declares which database types it accepts, so a codec pinned to
    // a column of another shape is a contradiction, not a coercion. A value the
    // analyzer could not type is exactly what a codec is there to rescue.
    if (codec.sqlite_type != .unknown) {
        if (target.scalar_type == .unknown)
            target.scalar_type = codec.sqlite_type
        else if (target.scalar_type != codec.sqlite_type)
            return error.IncompatibleCodec;
    }
    if (target.codec) |existing| {
        if (!std.mem.eql(u8, existing, codec.id)) return error.IncompatibleCodec;
        return;
    }
    target.codec = try storage.dupe(u8, codec.id);
}

fn findCodec(codecs: []const CodecInfo, id: []const u8) ?CodecInfo {
    for (codecs) |codec| if (std.mem.eql(u8, codec.id, id)) return codec;
    return null;
}

fn findValue(values: []analysis.ResultColumn, name: []const u8) ?*analysis.ResultColumn {
    for (values) |*value| if (std.mem.eql(u8, value.name, name)) return value;
    return null;
}

pub fn replaySqlite(
    allocator: std.mem.Allocator,
    inputs: []const MigrationInput,
) Error!catalog.Catalog {
    return replaySqliteWithDialect(allocator, inputs, .{});
}

pub fn replaySqliteWithDialect(
    allocator: std.mem.Allocator,
    inputs: []const MigrationInput,
    dialect: SqliteDialect,
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
        try applySqliteRevisionAtomicWithDialect(
            &schema,
            allocator,
            input.common_sql,
            input.sqlite_sql,
            dialect,
        );
    }
    return schema;
}

pub fn replayDiscoveredSqlite(
    allocator: std.mem.Allocator,
    discovery: *const migrations.Discovery,
) Error!catalog.Catalog {
    return replayDiscoveredSqliteWithDialect(allocator, discovery, .{});
}

pub fn replayDiscoveredSqliteWithDialect(
    allocator: std.mem.Allocator,
    discovery: *const migrations.Discovery,
    dialect: SqliteDialect,
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
    return replaySqliteWithDialect(allocator, inputs, dialect);
}

pub fn applySqliteRevisionAtomic(
    schema: *catalog.Catalog,
    allocator: std.mem.Allocator,
    common_sql: []const u8,
    sqlite_sql: []const u8,
) (parser.ParseError || catalog.Error)!void {
    return applySqliteRevisionAtomicWithDialect(schema, allocator, common_sql, sqlite_sql, .{});
}

pub fn applySqliteRevisionAtomicWithDialect(
    schema: *catalog.Catalog,
    allocator: std.mem.Allocator,
    common_sql: []const u8,
    sqlite_sql: []const u8,
    dialect: SqliteDialect,
) (parser.ParseError || catalog.Error)!void {
    var staged = try schema.clone(allocator);
    errdefer staged.deinit();
    try parseAndApply(&staged, allocator, common_sql, false, dialect);
    try parseAndApply(&staged, allocator, sqlite_sql, true, dialect);

    schema.deinit();
    schema.* = staged;
}

fn parseAndApply(
    schema: *catalog.Catalog,
    allocator: std.mem.Allocator,
    sql: []const u8,
    sqlite: bool,
    dialect: SqliteDialect,
) (parser.ParseError || catalog.Error)!void {
    if (std.mem.trim(u8, sql, &std.ascii.whitespace).len == 0) return;
    var parsed = if (sqlite)
        try parser.parseSqliteWithDialect(allocator, sql, dialect)
    else
        try parser.parse(allocator, sql);
    defer parsed.deinit();
    try schema.applyParserTree(parsed.tree);
}
