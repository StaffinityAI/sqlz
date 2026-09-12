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
    scalar_type: ScalarType,
    nullable: bool,
};

const VirtualCte = struct {
    name: []const u8,
    columns: []const ResultColumn,
};

pub fn analyze(
    allocator: std.mem.Allocator,
    schema: *const catalog.Catalog,
    query: *const ir.Query,
) Error!Analysis {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const storage = arena.allocator();

    const ctes = try storage.alloc(VirtualCte, query.ctes.len);
    for (query.ctes, ctes) |cte, *virtual| {
        const cte_columns = try storage.alloc(ResultColumn, cte.columns.len);
        for (cte.columns, cte_columns) |projection, *result| {
            result.* = .{
                .name = try storage.dupe(u8, projection.name),
                .scalar_type = .unknown,
                .nullable = true,
            };
            if (projection.column) |reference| {
                const resolved = try resolvePhysicalColumn(schema, query.relation_bindings, reference);
                result.scalar_type = resolved.scalar_type;
                result.nullable = resolved.nullable;
            } else if (projection.hint) |hint| {
                result.scalar_type = fromHint(hint.scalar_type);
                result.nullable = hint.nullable;
            }
        }
        virtual.* = .{ .name = cte.name, .columns = cte_columns };
    }

    for (query.relation_bindings) |binding| {
        if (schema.table(binding.name) == null and findCte(ctes, binding.name) == null)
            return error.MissingRelation;
    }

    const columns = try storage.alloc(ResultColumn, query.projections.len);
    for (query.projections, columns) |projection, *result| {
        result.* = .{
            .name = try storage.dupe(u8, projection.name),
            .scalar_type = .unknown,
            .nullable = true,
        };
        if (projection.column) |reference| {
            const resolved = try resolveColumn(schema, ctes, query.top_level_bindings, reference, false);
            result.scalar_type = resolved.scalar_type;
            result.nullable = resolved.nullable;
        } else if (projection.hint) |hint| {
            result.scalar_type = fromHint(hint.scalar_type);
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
        const resolved = try resolveColumn(schema, ctes, query.relation_bindings, reference, true);
        result.scalar_type = resolved.scalar_type;
        result.nullable = resolved.nullable;
    }
    return .{ .arena = arena, .columns = columns, .parameters = parameters };
}

fn resolvePhysicalColumn(
    schema: *const catalog.Catalog,
    bindings: []const ir.Relation,
    reference: ir.ColumnReference,
) Error!ResolvedColumn {
    var found: ?ResolvedColumn = null;
    for (bindings) |binding| {
        if (reference.qualifier) |qualifier| {
            const alias_match = if (binding.alias) |alias| std.mem.eql(u8, alias, qualifier) else false;
            if (!alias_match and !std.mem.eql(u8, binding.name, qualifier)) continue;
        }
        const table = schema.table(binding.name) orelse continue;
        const column = table.columns.getPtr(reference.name) orelse continue;
        if (found) |prior| {
            if (prior.scalar_type != scalarType(column.database_type) or
                prior.nullable != column.nullable)
                return error.AmbiguousColumn;
        } else {
            found = .{ .scalar_type = scalarType(column.database_type), .nullable = column.nullable };
        }
    }
    return found orelse error.MissingColumn;
}

fn resolveColumn(
    schema: *const catalog.Catalog,
    ctes: []const VirtualCte,
    bindings: []const ir.Relation,
    reference: ir.ColumnReference,
    compatible_duplicates: bool,
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
        const candidate: ?ResolvedColumn = if (schema.table(binding.name)) |table| blk: {
            const column = table.columns.getPtr(reference.name) orelse break :blk null;
            break :blk .{
                .scalar_type = scalarType(column.database_type),
                .nullable = column.nullable or binding.nullable,
            };
        } else if (findCte(ctes, binding.name)) |cte| blk: {
            for (cte.columns) |column| {
                if (std.mem.eql(u8, column.name, reference.name)) break :blk .{
                    .scalar_type = column.scalar_type,
                    .nullable = column.nullable or binding.nullable,
                };
            }
            break :blk null;
        } else return error.MissingRelation;
        const resolved = candidate orelse {
            if (reference.qualifier != null) return error.MissingColumn;
            continue;
        };
        if (found) |prior| {
            if (!compatible_duplicates or prior.scalar_type != resolved.scalar_type or
                prior.nullable != resolved.nullable) return error.AmbiguousColumn;
        } else found = resolved;
    }
    return found orelse error.MissingColumn;
}

fn findCte(ctes: []const VirtualCte, name: []const u8) ?*const VirtualCte {
    for (ctes) |*cte| if (std.mem.eql(u8, cte.name, name)) return cte;
    return null;
}

fn fromHint(hint: ir.TypeHint) ScalarType {
    return switch (hint) {
        .integer => .integer,
        .real => .real,
        .text => .text,
        .blob => .blob,
        .boolean => .boolean,
    };
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
