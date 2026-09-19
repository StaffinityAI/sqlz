const std = @import("std");
pub const parser = @import("sqlz_parser");
const catalog = @import("sqlz_catalog");
const migrations = @import("sqlz_migrations");
const ir = @import("sqlz_ir");
const analysis = @import("sqlz_analysis");
const query_files = @import("sqlz_query_files");
const diagnostics = @import("sqlz_diagnostics");

pub const SqliteDialect = parser.SqliteDialect;
pub const SqliteProfile = parser.SqliteProfile;
pub const PostgresDialect = parser.PostgresDialect;
pub const PostgresProfile = parser.PostgresProfile;

pub const PostgresCatalogOptions = struct {
    dialect: PostgresDialect = .{},
    search_path: []const []const u8 = &.{"public"},
};

const CatalogSqlSource = struct { path: []const u8, sql: []const u8 };

pub fn appendCatalogDiagnostic(
    allocator: std.mem.Allocator,
    err: anyerror,
    discovery: *const migrations.Discovery,
    backend: migrations.Backend,
    list: *diagnostics.List,
) !bool {
    if (err != error.DuplicateTable and err != error.DuplicateColumn and
        err != error.MissingTable and err != error.MissingColumn and
        err != error.DuplicateIndex and err != error.MissingIndex and
        err != error.DuplicateType and err != error.MissingType and
        err != error.UnsupportedStatement and err != error.UnsupportedArrayDimensions)
        return false;

    const revisions = try allocator.alloc(migrations.Revision, discovery.revisions.len);
    defer allocator.free(revisions);
    for (discovery.revisions, revisions) |revision, *node| node.* = .{
        .id = revision.manifest.manifest().revision,
        .parents = revision.manifest.manifest().parents,
    };
    var order = try migrations.validateAndOrder(allocator, revisions);
    defer order.deinit();
    var scratch = catalog.Catalog.init(allocator);
    defer scratch.deinit();

    for (order.indices) |revision_index| {
        const revision = discovery.revisions[revision_index];
        const manifest = revision.manifest.manifest();
        if (!migrations.targetsBackend(manifest, backend)) continue;
        const sources = switch (backend) {
            .sqlite => [_]CatalogSqlSource{
                .{ .path = "common.up.sql", .sql = revision.common_up },
                .{ .path = "sqlite.up.sql", .sql = revision.sqlite_up },
            },
            .postgres => [_]CatalogSqlSource{
                .{ .path = "common.up.sql", .sql = revision.common_up },
                .{ .path = "postgres.up.sql", .sql = revision.postgres_up },
            },
        };
        for (sources, 0..) |source, source_index| {
            if (std.mem.trim(u8, source.sql, &std.ascii.whitespace).len == 0) continue;
            var parsed = switch (if (source_index == 0) migrations.Backend.postgres else backend) {
                .sqlite => parser.parseSqlite(allocator, source.sql),
                .postgres => parser.parse(allocator, source.sql),
            } catch continue;
            defer parsed.deinit();
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ revision.directory, source.path });
            defer allocator.free(path);
            scratch.applyParserTreeWithSource(parsed.tree, .{
                .path = path,
                .sql = source.sql,
                .revision = manifest.revision,
            }) catch |candidate| {
                if (candidate != err) continue;
                const message = catalogMessage(err);
                var labels: [1]diagnostics.Label = undefined;
                const conflict_origin = catalogConflictOrigin(&scratch, err, source.sql);
                if (conflict_origin) |origin| {
                    labels[0] = .{ .span = originSpan(origin, 1), .message = "previous declaration" };
                }
                try list.appendDiagnostic(.{
                    .severity = .err,
                    .code = catalogCode(err),
                    .message = message,
                    .primary = diagnostics.spanAt(path, source.sql, 0, @min(source.sql.len, @as(usize, 1))),
                    .labels = if (conflict_origin != null) labels[0..1] else labels[0..0],
                    .notes = &.{manifest.revision},
                    .help = catalogHelp(err),
                });
                return true;
            };
        }
    }
    return false;
}

fn catalogConflictOrigin(schema: *const catalog.Catalog, err: anyerror, sql: []const u8) ?catalog.Origin {
    if (err == error.DuplicateTable) {
        var tables = schema.tables.iterator();
        while (tables.next()) |entry| {
            if (containsIdentifier(sql, entry.key_ptr.*)) return entry.value_ptr.origin;
        }
    } else if (err == error.DuplicateColumn) {
        var tables = schema.tables.iterator();
        while (tables.next()) |entry| {
            var columns = entry.value_ptr.columns.iterator();
            while (columns.next()) |column| {
                if (containsIdentifier(sql, column.key_ptr.*)) return column.value_ptr.origin;
            }
        }
    }
    return null;
}

fn containsIdentifier(sql: []const u8, name: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, sql, start, name)) |index| {
        const before_ok = index == 0 or (!std.ascii.isAlphanumeric(sql[index - 1]) and sql[index - 1] != '_');
        const end = index + name.len;
        const after_ok = end == sql.len or (!std.ascii.isAlphanumeric(sql[end]) and sql[end] != '_');
        if (before_ok and after_ok) return true;
        start = end;
    }
    return false;
}

fn catalogCode(err: anyerror) []const u8 {
    return switch (err) {
        error.DuplicateTable => "C010",
        error.DuplicateColumn => "C011",
        error.MissingTable => "C020",
        error.MissingColumn => "C021",
        error.DuplicateIndex => "C012",
        error.MissingIndex => "C022",
        error.DuplicateType => "C013",
        error.MissingType => "C023",
        error.UnsupportedArrayDimensions => "C030",
        else => "C001",
    };
}

fn catalogMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.DuplicateTable => "migration declares a table that already exists",
        error.DuplicateColumn => "migration declares a column that already exists",
        error.MissingTable => "migration references a table that does not exist",
        error.MissingColumn => "migration references a column that does not exist",
        error.DuplicateIndex => "migration declares an index that already exists",
        error.MissingIndex => "migration references an index that does not exist",
        error.DuplicateType => "migration declares a type that already exists",
        error.MissingType => "migration references a type that does not exist",
        error.UnsupportedArrayDimensions => "only one-dimensional PostgreSQL arrays are supported",
        else => "migration contains unsupported catalog SQL",
    };
}

fn catalogHelp(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.DuplicateTable, error.DuplicateColumn, error.DuplicateIndex, error.DuplicateType => "rename the new object or alter the existing object instead",
        error.MissingTable, error.MissingColumn, error.MissingIndex, error.MissingType => "create the referenced object earlier or correct its name",
        error.UnsupportedArrayDimensions => "use a one-dimensional array or a registered codec",
        else => null,
    };
}

pub const MigrationInput = struct {
    revision: migrations.Revision,
    common_sql: []const u8 = "",
    sqlite_sql: []const u8 = "",
    postgres_sql: []const u8 = "",
    common_path: ?[]const u8 = null,
    sqlite_path: ?[]const u8 = null,
    postgres_path: ?[]const u8 = null,
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
    DivergentMerge,
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

pub fn appendSemanticDiagnostic(
    allocator: std.mem.Allocator,
    err: anyerror,
    schema: *const catalog.Catalog,
    source: *const query_files.Source,
    backend: migrations.Backend,
    sqlite_dialect: SqliteDialect,
    postgres_dialect: PostgresDialect,
    list: *diagnostics.List,
) !bool {
    if (err != error.MissingRelation and err != error.MissingColumn and err != error.AmbiguousColumn and
        err != error.ConflictingResultType and err != error.ConflictingParameterType)
        return false;
    var parsed = switch (backend) {
        .sqlite => try parser.parseSqliteWithDialect(allocator, source.sql, sqlite_dialect),
        .postgres => try parser.parsePostgresWithDialect(allocator, source.sql, postgres_dialect),
    };
    defer parsed.deinit();
    var query = try ir.adaptWithSource(
        allocator,
        parsed.tree,
        parsed.rewritten.names,
        source.sql,
        parsed.rewritten.original_offsets,
    );
    defer query.deinit();

    if (err == error.ConflictingResultType or err == error.ConflictingParameterType) {
        var conflict: ?analysis.TypeConflict = null;
        var analyzed = analysis.analyzeWithConflict(allocator, schema, &query, &conflict) catch |candidate| {
            if (candidate != err or conflict == null) return false;
            return appendTypeConflictDiagnostic(allocator, source, conflict.?, list);
        };
        analyzed.deinit();
        return false;
    }

    if (err == error.MissingRelation) {
        for (query.relation_bindings) |binding| {
            if (schema.table(binding.name) != null or hasCte(query.ctes, binding.name)) continue;
            const suggestion = nearestTable(schema, binding.name);
            const message = try std.fmt.allocPrint(allocator, "relation `{s}` does not exist", .{binding.name});
            defer allocator.free(message);
            const help = if (suggestion) |name|
                try std.fmt.allocPrint(allocator, "did you mean `{s}`?", .{name})
            else
                null;
            defer if (help) |value| allocator.free(value);
            var labels: [1]diagnostics.Label = undefined;
            const label_slice = if (suggestion) |name| label: {
                const table = schema.table(name).?;
                if (table.origin) |origin| {
                    labels[0] = .{ .span = originSpan(origin, name.len), .message = "available relation" };
                    break :label labels[0..1];
                }
                break :label labels[0..0];
            } else labels[0..0];
            try list.appendDiagnostic(.{
                .severity = .err,
                .code = "Q020",
                .message = message,
                .primary = querySpan(source, binding.offset, binding.name.len),
                .labels = label_slice,
                .help = help,
            });
            return true;
        }
    }

    const reference = firstFailingColumn(schema, &query, err == error.AmbiguousColumn) orelse return false;
    const suggestion = if (err == error.MissingColumn) nearestVisibleColumn(schema, &query, reference) else null;
    const message = if (err == error.AmbiguousColumn)
        try std.fmt.allocPrint(allocator, "column `{s}` is ambiguous", .{reference.name})
    else
        try std.fmt.allocPrint(allocator, "column `{s}` does not exist", .{reference.name});
    defer allocator.free(message);
    const help = if (err == error.AmbiguousColumn)
        try std.fmt.allocPrint(allocator, "qualify `{s}` with a table name or alias", .{reference.name})
    else if (suggestion) |candidate|
        try std.fmt.allocPrint(allocator, "did you mean `{s}`?", .{candidate.column.name})
    else
        null;
    defer if (help) |value| allocator.free(value);
    var labels: [1]diagnostics.Label = undefined;
    const label_slice = if (suggestion) |candidate| label: {
        if (candidate.column.origin) |origin| {
            labels[0] = .{ .span = originSpan(origin, candidate.column.name.len), .message = "available column" };
            break :label labels[0..1];
        }
        break :label labels[0..0];
    } else labels[0..0];
    try list.appendDiagnostic(.{
        .severity = .err,
        .code = if (err == error.AmbiguousColumn) "Q022" else "Q021",
        .message = message,
        .primary = querySpan(source, reference.offset, reference.name.len),
        .labels = label_slice,
        .help = help,
    });
    return true;
}

fn appendTypeConflictDiagnostic(
    allocator: std.mem.Allocator,
    source: *const query_files.Source,
    conflict: analysis.TypeConflict,
    list: *diagnostics.List,
) !bool {
    const first_source = conflict.first.source orelse return false;
    const second_source = conflict.second.source orelse return false;
    const first_type = try formatTypeShape(allocator, conflict.first.shape);
    defer allocator.free(first_type);
    const second_type = try formatTypeShape(allocator, conflict.second.shape);
    defer allocator.free(second_type);
    const message = switch (conflict.kind) {
        .result => try std.fmt.allocPrint(
            allocator,
            "result column `{s}` has conflicting types `{s}` and `{s}`",
            .{ conflict.name, first_type, second_type },
        ),
        .parameter => try std.fmt.allocPrint(
            allocator,
            "parameter `{s}` is constrained to conflicting types `{s}` and `{s}`",
            .{ conflict.name, first_type, second_type },
        ),
    };
    defer allocator.free(message);
    const label_message = switch (conflict.kind) {
        .result => try std.fmt.allocPrint(allocator, "first branch has type `{s}`", .{first_type}),
        .parameter => try std.fmt.allocPrint(allocator, "first use requires type `{s}`", .{first_type}),
    };
    defer allocator.free(label_message);
    const labels = [_]diagnostics.Label{.{
        .span = querySpan(source, first_source.offset, first_source.length),
        .message = label_message,
    }};
    try list.appendDiagnostic(.{
        .severity = .err,
        .code = switch (conflict.kind) {
            .result => "Q023",
            .parameter => "Q024",
        },
        .message = message,
        .primary = querySpan(source, second_source.offset, second_source.length),
        .labels = &labels,
        .help = switch (conflict.kind) {
            .result => "cast one set-operation branch so every branch returns the same type",
            .parameter => "use separate parameter names or add an explicit cast so every use has one type",
        },
    });
    return true;
}

fn formatTypeShape(allocator: std.mem.Allocator, shape: analysis.TypeShape) ![]const u8 {
    const base = shape.database_type orelse switch (shape.scalar_type) {
        .integer => "integer",
        .real => "real",
        .text => "text",
        .blob => "blob",
        .boolean => "boolean",
        .unknown => "unknown",
    };
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, base);
    for (0..shape.array_dimensions) |_| try output.appendSlice(allocator, "[]");
    return output.toOwnedSlice(allocator);
}

const ColumnCandidate = struct {
    column: *const catalog.Column,
    distance: usize,
};

fn firstFailingColumn(
    schema: *const catalog.Catalog,
    query: *const ir.Query,
    ambiguous: bool,
) ?ir.ColumnReference {
    const expected: u2 = if (ambiguous) 2 else 0;
    for (query.projections) |projection| {
        if (projection.set_operands.len != 0) {
            for (projection.set_operands) |operand| if (operand.column) |reference|
                if (columnMatchCount(schema, operand.bindings, reference) == expected) return reference;
        } else if (projection.column) |reference| {
            if (columnMatchCount(schema, query.top_level_bindings, reference) == expected)
                return reference;
        }
    }
    for (query.parameter_uses) |use| for (use.columns) |reference| {
        if (columnMatchCount(schema, query.relation_bindings, reference) == expected)
            return reference;
    };
    return null;
}

fn columnMatchCount(schema: *const catalog.Catalog, bindings: []const ir.Relation, reference: ir.ColumnReference) u2 {
    var count: u2 = 0;
    for (bindings) |binding| {
        if (reference.qualifier) |qualifier| {
            const alias_match = if (binding.alias) |alias| std.mem.eql(u8, alias, qualifier) else false;
            if (!alias_match and !std.mem.eql(u8, binding.qualifier_name, qualifier)) continue;
        }
        const table = schema.table(binding.name) orelse continue;
        if (!table.columns.contains(reference.name)) continue;
        count = @min(count + 1, 2);
    }
    return count;
}

fn nearestVisibleColumn(
    schema: *const catalog.Catalog,
    query: *const ir.Query,
    reference: ir.ColumnReference,
) ?ColumnCandidate {
    var best: ?ColumnCandidate = null;
    for (query.relation_bindings) |binding| {
        if (reference.qualifier) |qualifier| {
            const alias_match = if (binding.alias) |alias| std.mem.eql(u8, alias, qualifier) else false;
            if (!alias_match and !std.mem.eql(u8, binding.qualifier_name, qualifier)) continue;
        }
        const table = schema.table(binding.name) orelse continue;
        var columns = table.columns.iterator();
        while (columns.next()) |entry| {
            const distance = editDistance(reference.name, entry.key_ptr.*);
            if (!plausibleSuggestion(reference.name.len, distance)) continue;
            if (best == null or distance < best.?.distance or
                (distance == best.?.distance and std.mem.lessThan(u8, entry.key_ptr.*, best.?.column.name)))
                best = .{ .column = entry.value_ptr, .distance = distance };
        }
    }
    return best;
}

fn nearestTable(schema: *const catalog.Catalog, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    var tables = schema.tables.iterator();
    while (tables.next()) |entry| {
        const distance = editDistance(name, entry.key_ptr.*);
        if (!plausibleSuggestion(name.len, distance)) continue;
        if (distance < best_distance or (distance == best_distance and
            (best == null or std.mem.lessThan(u8, entry.key_ptr.*, best.?))))
        {
            best = entry.key_ptr.*;
            best_distance = distance;
        }
    }
    return best;
}

fn plausibleSuggestion(length: usize, distance: usize) bool {
    const limit: usize = if (length <= 4) 1 else if (length <= 8) 2 else 3;
    return distance <= limit;
}

fn editDistance(left: []const u8, right: []const u8) usize {
    var previous: [256]usize = undefined;
    var current: [256]usize = undefined;
    if (right.len >= previous.len) return std.math.maxInt(usize);
    for (0..right.len + 1) |index| previous[index] = index;
    for (left, 1..) |left_byte, row| {
        current[0] = row;
        for (right, 1..) |right_byte, column| {
            const substitution = previous[column - 1] + @intFromBool(std.ascii.toLower(left_byte) != std.ascii.toLower(right_byte));
            current[column] = @min(@min(current[column - 1] + 1, previous[column] + 1), substitution);
        }
        @memcpy(previous[0 .. right.len + 1], current[0 .. right.len + 1]);
    }
    return previous[right.len];
}

fn hasCte(ctes: []const ir.Cte, name: []const u8) bool {
    for (ctes) |cte| if (std.mem.eql(u8, cte.name, name)) return true;
    return false;
}

fn querySpan(source: *const query_files.Source, offset: usize, length: usize) diagnostics.Span {
    const local_start = diagnostics.positionAt(source.sql, offset);
    const local_end = diagnostics.positionAt(source.sql, offset + length);
    return .{
        .path = source.path,
        .start = .{
            .offset = source.sql_offset + local_start.offset,
            .line = source.sql_line + local_start.line - 1,
            .column = if (local_start.line == 1) source.sql_column + local_start.column - 1 else local_start.column,
        },
        .end = .{
            .offset = source.sql_offset + local_end.offset,
            .line = source.sql_line + local_end.line - 1,
            .column = if (local_end.line == 1) source.sql_column + local_end.column - 1 else local_end.column,
        },
    };
}

fn originSpan(origin: catalog.Origin, length: usize) diagnostics.Span {
    return .{
        .path = origin.path,
        .start = .{ .offset = origin.offset, .line = origin.line, .column = origin.column },
        .end = .{ .offset = origin.offset + length, .line = origin.line, .column = origin.column + length },
    };
}

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
    postgres_type: analysis.ScalarType = .unknown,
    postgres_patterns: []const []const u8 = &.{},
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
    var query = try ir.adaptWithSource(allocator, parsed.tree, parsed.rewritten.names, source.sql, parsed.rewritten.original_offsets);
    errdefer query.deinit();
    const produces_rows = query.projections.len != 0;
    if (source.cardinality == .exec and produces_rows) return error.UnexpectedResultColumns;
    if (source.cardinality != .exec and !produces_rows) return error.MissingResultColumns;
    var analyzed = try analysis.analyze(allocator, schema, &query);
    errdefer analyzed.deinit();
    try applyCodecs(&analyzed, source, codecs, .sqlite);
    try verifyDeclaration(&analyzed, source);
    return .{ .parsed = parsed, .query = query, .analysis = analyzed };
}

pub fn checkNamedPostgres(
    allocator: std.mem.Allocator,
    schema: *const catalog.Catalog,
    source: *const query_files.Source,
) Error!CheckedQuery {
    return checkNamedPostgresWithDialect(allocator, schema, source, .{});
}

pub fn checkNamedPostgresWithDialect(
    allocator: std.mem.Allocator,
    schema: *const catalog.Catalog,
    source: *const query_files.Source,
    dialect: PostgresDialect,
) Error!CheckedQuery {
    return checkNamedPostgresWithCodecs(allocator, schema, source, dialect, &.{});
}

pub fn checkNamedPostgresWithCodecs(
    allocator: std.mem.Allocator,
    schema: *const catalog.Catalog,
    source: *const query_files.Source,
    dialect: PostgresDialect,
    codecs: []const CodecInfo,
) Error!CheckedQuery {
    if (!source.backends.postgres) return error.BackendNotSelected;
    var parsed = try parser.parsePostgresWithDialect(allocator, source.sql, dialect);
    errdefer parsed.deinit();
    var query = try ir.adaptWithSource(allocator, parsed.tree, parsed.rewritten.names, source.sql, parsed.rewritten.original_offsets);
    errdefer query.deinit();
    const produces_rows = query.projections.len != 0;
    if (source.cardinality == .exec and produces_rows) return error.UnexpectedResultColumns;
    if (source.cardinality != .exec and !produces_rows) return error.MissingResultColumns;
    var analyzed = try analysis.analyze(allocator, schema, &query);
    errdefer analyzed.deinit();
    try applyCodecs(&analyzed, source, codecs, .postgres);
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
    const array_element = if (value.array_dimensions == 1) arrayElementType(field.type_text) else null;
    if (value.array_dimensions == 1 and array_element == null) return error.DeclaredTypeMismatch;
    const declared_scalar = analysis.classifyZigType(array_element orelse field.type_text);
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

fn arrayElementType(type_text: []const u8) ?[]const u8 {
    const prefix = "[]const ?";
    if (!std.mem.startsWith(u8, type_text, prefix) or type_text.len == prefix.len) return null;
    return type_text[prefix.len..];
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
    backend: migrations.Backend,
) Error!void {
    const storage = analyzed.arena.allocator();
    for (source.param_codecs) |override|
        try applyCodec(storage, analyzed.parameters, override, codecs, backend);
    for (source.column_codecs) |override|
        try applyCodec(storage, analyzed.columns, override, codecs, backend);
}

fn applyCodec(
    storage: std.mem.Allocator,
    values: []analysis.ResultColumn,
    override: query_files.CodecOverride,
    codecs: []const CodecInfo,
    backend: migrations.Backend,
) Error!void {
    const codec = findCodec(codecs, override.codec) orelse return error.UnknownCodec;
    const target = findValue(values, override.name) orelse return error.UnknownCodecTarget;
    // The codec declares which database types it accepts, so a codec pinned to
    // a column of another shape is a contradiction, not a coercion. A value the
    // analyzer could not type is exactly what a codec is there to rescue.
    const database_type = switch (backend) {
        .sqlite => codec.sqlite_type,
        .postgres => codec.postgres_type,
    };
    if (backend == .postgres and target.database_type != null and codec.postgres_patterns.len != 0) {
        var matched = false;
        for (codec.postgres_patterns) |pattern| {
            if (postgresPatternMatches(pattern, target)) {
                matched = true;
                break;
            }
        }
        if (!matched) return error.IncompatibleCodec;
    }
    if (database_type != .unknown) {
        if (target.scalar_type == .unknown)
            target.scalar_type = database_type
        else if (target.scalar_type != database_type)
            return error.IncompatibleCodec;
    }
    if (target.codec) |existing| {
        if (!std.mem.eql(u8, existing, codec.id)) return error.IncompatibleCodec;
        return;
    }
    target.codec = try storage.dupe(u8, codec.id);
}

fn postgresPatternMatches(pattern: []const u8, target: *const analysis.ResultColumn) bool {
    const array = std.mem.endsWith(u8, pattern, "[]");
    if (array != (target.array_dimensions == 1)) return false;
    const base = if (array) pattern[0 .. pattern.len - 2] else pattern;
    return std.ascii.eqlIgnoreCase(base, target.database_type.?);
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
    return replayBackend(allocator, inputs, .sqlite, dialect, .{});
}

pub fn replayPostgres(
    allocator: std.mem.Allocator,
    inputs: []const MigrationInput,
) Error!catalog.Catalog {
    return replayPostgresWithDialect(allocator, inputs, .{});
}

pub fn replayPostgresWithDialect(
    allocator: std.mem.Allocator,
    inputs: []const MigrationInput,
    dialect: PostgresDialect,
) Error!catalog.Catalog {
    return replayBackend(allocator, inputs, .postgres, .{}, dialect);
}

fn replayBackend(
    allocator: std.mem.Allocator,
    inputs: []const MigrationInput,
    backend: migrations.Backend,
    sqlite_dialect: SqliteDialect,
    postgres_dialect: PostgresDialect,
) Error!catalog.Catalog {
    const revisions = try allocator.alloc(migrations.Revision, inputs.len);
    defer allocator.free(revisions);
    for (inputs, revisions) |input, *revision| revision.* = input.revision;

    var order = try migrations.validateAndOrder(allocator, revisions);
    defer order.deinit();

    const snapshots = try allocator.alloc(?catalog.Catalog, inputs.len);
    defer allocator.free(snapshots);
    @memset(snapshots, null);
    errdefer for (snapshots) |*snapshot| if (snapshot.*) |*schema| schema.deinit();

    for (order.indices) |index| {
        const input = inputs[index];
        var schema = if (input.revision.parents.len == 0)
            catalog.Catalog.init(allocator)
        else blk: {
            const first_parent = revisionIndex(revisions, input.revision.parents[0]).?;
            const first = &snapshots[first_parent].?;
            for (input.revision.parents[1..]) |parent_id| {
                const parent = revisionIndex(revisions, parent_id).?;
                if (!first.eql(&snapshots[parent].?)) return error.DivergentMerge;
            }
            break :blk try first.clone(allocator);
        };
        errdefer schema.deinit();
        try applyRevisionAtomic(
            &schema,
            allocator,
            input.common_sql,
            switch (backend) {
                .sqlite => input.sqlite_sql,
                .postgres => input.postgres_sql,
            },
            backend,
            sqlite_dialect,
            postgres_dialect,
            .{ .path = input.common_path, .revision = input.revision.id },
            .{
                .path = switch (backend) {
                    .sqlite => input.sqlite_path,
                    .postgres => input.postgres_path,
                },
                .revision = input.revision.id,
            },
        );
        snapshots[index] = schema;
    }
    const result = snapshots[order.head].?;
    snapshots[order.head] = null;
    for (snapshots) |*snapshot| if (snapshot.*) |*schema| {
        schema.deinit();
        snapshot.* = null;
    };
    return result;
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
            .common_sql = if (migrations.targetsBackend(manifest, .sqlite)) revision.common_up else "",
            .sqlite_sql = if (migrations.targetsBackend(manifest, .sqlite)) revision.sqlite_up else "",
            .common_path = try std.fmt.allocPrint(allocator, "{s}/common.up.sql", .{revision.directory}),
            .sqlite_path = try std.fmt.allocPrint(allocator, "{s}/sqlite.up.sql", .{revision.directory}),
        };
    }
    defer for (inputs) |input| {
        if (input.common_path) |path| allocator.free(path);
        if (input.sqlite_path) |path| allocator.free(path);
    };
    return replaySqliteWithDialect(allocator, inputs, dialect);
}

pub fn replayDiscoveredPostgres(
    allocator: std.mem.Allocator,
    discovery: *const migrations.Discovery,
) Error!catalog.Catalog {
    return replayDiscoveredPostgresWithDialect(allocator, discovery, .{});
}

pub fn replayDiscoveredPostgresWithDialect(
    allocator: std.mem.Allocator,
    discovery: *const migrations.Discovery,
    dialect: PostgresDialect,
) Error!catalog.Catalog {
    return replayDiscoveredPostgresWithOptions(allocator, discovery, .{ .dialect = dialect });
}

pub fn replayDiscoveredPostgresWithOptions(
    allocator: std.mem.Allocator,
    discovery: *const migrations.Discovery,
    options: PostgresCatalogOptions,
) Error!catalog.Catalog {
    const inputs = try allocator.alloc(MigrationInput, discovery.revisions.len);
    defer allocator.free(inputs);
    for (discovery.revisions, inputs) |revision, *input| {
        const manifest = revision.manifest.manifest();
        input.* = .{
            .revision = .{ .id = manifest.revision, .parents = manifest.parents },
            .common_sql = if (migrations.targetsBackend(manifest, .postgres)) revision.common_up else "",
            .postgres_sql = if (migrations.targetsBackend(manifest, .postgres)) revision.postgres_up else "",
            .common_path = try std.fmt.allocPrint(allocator, "{s}/common.up.sql", .{revision.directory}),
            .postgres_path = try std.fmt.allocPrint(allocator, "{s}/postgres.up.sql", .{revision.directory}),
        };
    }
    defer for (inputs) |input| {
        if (input.common_path) |path| allocator.free(path);
        if (input.postgres_path) |path| allocator.free(path);
    };
    var schema = try replayPostgresWithDialect(allocator, inputs, options.dialect);
    errdefer schema.deinit();
    try schema.setPostgresSearchPath(options.search_path);
    return schema;
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
    return applyRevisionAtomic(schema, allocator, common_sql, sqlite_sql, .sqlite, dialect, .{}, .{}, .{});
}

pub fn applyPostgresRevisionAtomic(
    schema: *catalog.Catalog,
    allocator: std.mem.Allocator,
    common_sql: []const u8,
    postgres_sql: []const u8,
) (parser.ParseError || catalog.Error)!void {
    return applyPostgresRevisionAtomicWithDialect(schema, allocator, common_sql, postgres_sql, .{});
}

pub fn applyPostgresRevisionAtomicWithDialect(
    schema: *catalog.Catalog,
    allocator: std.mem.Allocator,
    common_sql: []const u8,
    postgres_sql: []const u8,
    dialect: PostgresDialect,
) (parser.ParseError || catalog.Error)!void {
    return applyRevisionAtomic(schema, allocator, common_sql, postgres_sql, .postgres, .{}, dialect, .{}, .{});
}

fn applyRevisionAtomic(
    schema: *catalog.Catalog,
    allocator: std.mem.Allocator,
    common_sql: []const u8,
    backend_sql: []const u8,
    backend: migrations.Backend,
    sqlite_dialect: SqliteDialect,
    postgres_dialect: PostgresDialect,
    common_source: SourceContext,
    backend_source: SourceContext,
) (parser.ParseError || catalog.Error)!void {
    var staged = try schema.clone(allocator);
    errdefer staged.deinit();
    try parseAndApply(&staged, allocator, common_sql, .postgres, sqlite_dialect, postgres_dialect, common_source);
    try parseAndApply(&staged, allocator, backend_sql, backend, sqlite_dialect, postgres_dialect, backend_source);

    schema.deinit();
    schema.* = staged;
}

const SourceContext = struct {
    path: ?[]const u8 = null,
    revision: ?[]const u8 = null,
};

fn parseAndApply(
    schema: *catalog.Catalog,
    allocator: std.mem.Allocator,
    sql: []const u8,
    backend: migrations.Backend,
    sqlite_dialect: SqliteDialect,
    postgres_dialect: PostgresDialect,
    source: SourceContext,
) (parser.ParseError || catalog.Error)!void {
    if (std.mem.trim(u8, sql, &std.ascii.whitespace).len == 0) return;
    var parsed = switch (backend) {
        .sqlite => try parser.parseSqliteWithDialect(allocator, sql, sqlite_dialect),
        .postgres => try parser.parsePostgresWithDialect(allocator, sql, postgres_dialect),
    };
    defer parsed.deinit();
    if (source.path) |path| {
        try schema.applyParserTreeWithSource(parsed.tree, .{
            .path = path,
            .sql = sql,
            .revision = source.revision,
        });
    } else try schema.applyParserTree(parsed.tree);
}

fn revisionIndex(revisions: []const migrations.Revision, id: []const u8) ?usize {
    for (revisions, 0..) |revision, index| {
        if (std.mem.eql(u8, revision.id, id)) return index;
    }
    return null;
}
