const std = @import("std");
const catalog = @import("sqlz_catalog");
const ir = @import("sqlz_ir");

pub const ScalarType = enum {
    integer,
    real,
    text,
    blob,
    boolean,
    unknown,
};

pub const ResultColumn = struct {
    name: []const u8,
    scalar_type: ScalarType,
    nullable: bool,
};

pub const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    columns: []const ResultColumn,
    parameters: []const ResultColumn,

    pub fn deinit(self: *Analysis) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Error = error{
    MissingRelation,
    MissingColumn,
    AmbiguousColumn,
} || std.mem.Allocator.Error;

const ResolvedColumn = struct {
    column: *const catalog.Column,
    relation_nullable: bool,
};

pub fn analyze(
    allocator: std.mem.Allocator,
    schema: *const catalog.Catalog,
    query: *const ir.Query,
) Error!Analysis {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const storage = arena.allocator();

    for (query.relation_bindings) |binding| {
        if (schema.table(binding.name) == null) return error.MissingRelation;
    }

    const columns = try storage.alloc(ResultColumn, query.projections.len);
    for (query.projections, columns) |projection, *result| {
        result.* = .{
            .name = try storage.dupe(u8, projection.name),
            .scalar_type = .unknown,
            .nullable = true,
        };
        if (projection.column) |reference| {
            const resolved = try resolveColumn(schema, query.relation_bindings, reference);
            result.scalar_type = scalarType(resolved.column.database_type);
            result.nullable = resolved.column.nullable or resolved.relation_nullable;
        } else if (projection.hint) |hint| {
            result.scalar_type = switch (hint.scalar_type) {
                .integer => .integer,
                .real => .real,
                .text => .text,
                .blob => .blob,
                .boolean => .boolean,
            };
            result.nullable = hint.nullable;
        }
    }
    const parameters = try storage.alloc(ResultColumn, query.parameter_uses.len);
    for (query.parameter_uses, parameters) |use, *result| {
        result.* = .{
            .name = try storage.dupe(u8, use.name),
            .scalar_type = if (use.integer_hint) .integer else .unknown,
            .nullable = !use.integer_hint,
        };
        const reference = use.column orelse continue;
        const resolved = try resolveParameterColumn(schema, query.relation_bindings, reference);
        result.scalar_type = scalarType(resolved.column.database_type);
        result.nullable = resolved.column.nullable;
    }
    return .{ .arena = arena, .columns = columns, .parameters = parameters };
}

fn resolveParameterColumn(
    schema: *const catalog.Catalog,
    bindings: []const ir.Relation,
    reference: ir.ColumnReference,
) Error!ResolvedColumn {
    if (reference.qualifier != null) return resolveColumn(schema, bindings, reference);
    var found: ?ResolvedColumn = null;
    for (bindings) |binding| {
        const table = schema.table(binding.name) orelse return error.MissingRelation;
        const column = table.columns.getPtr(reference.name) orelse continue;
        if (found) |prior| {
            if (!std.ascii.eqlIgnoreCase(prior.column.database_type, column.database_type) or
                prior.column.nullable != column.nullable)
                return error.AmbiguousColumn;
        } else {
            found = .{ .column = column, .relation_nullable = false };
        }
    }
    return found orelse error.MissingColumn;
}

fn resolveColumn(
    schema: *const catalog.Catalog,
    bindings: []const ir.Relation,
    reference: ir.ColumnReference,
) Error!ResolvedColumn {
    var found: ?ResolvedColumn = null;
    for (bindings) |binding| {
        if (reference.qualifier) |qualifier| {
            const matches_alias = if (binding.alias) |alias|
                std.mem.eql(u8, alias, qualifier)
            else
                false;
            if (!matches_alias and !std.mem.eql(u8, binding.name, qualifier)) continue;
        }
        const table = schema.table(binding.name) orelse return error.MissingRelation;
        const column = table.columns.getPtr(reference.name) orelse {
            if (reference.qualifier != null) return error.MissingColumn;
            continue;
        };
        if (found != null) return error.AmbiguousColumn;
        found = .{ .column = column, .relation_nullable = binding.nullable };
    }
    return found orelse error.MissingColumn;
}

fn scalarType(database_type: []const u8) ScalarType {
    const integer_types = [_][]const u8{ "int2", "int4", "int8", "integer", "smallint", "bigint" };
    const real_types = [_][]const u8{ "float4", "float8", "numeric", "real", "double" };
    const text_types = [_][]const u8{ "text", "varchar", "bpchar", "char", "name" };
    const blob_types = [_][]const u8{ "bytea", "blob" };
    const boolean_types = [_][]const u8{ "bool", "boolean" };
    if (contains(&integer_types, database_type)) return .integer;
    if (contains(&real_types, database_type)) return .real;
    if (contains(&text_types, database_type)) return .text;
    if (contains(&blob_types, database_type)) return .blob;
    if (contains(&boolean_types, database_type)) return .boolean;
    return .unknown;
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.ascii.eqlIgnoreCase(value, needle)) return true;
    return false;
}
