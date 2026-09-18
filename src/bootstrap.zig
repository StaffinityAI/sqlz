const std = @import("std");
const analysis = @import("sqlz_analysis");
const catalog = @import("sqlz_catalog");

pub const Conversion = enum {
    integer,
    real,
    text,
    blob,
    boolean,
};

pub const ColumnPlan = struct {
    source_name: []const u8,
    source_type: []const u8,
    source_nullable: bool,
    source_primary_key: bool,
    destination_name: []const u8,
    destination_type: []const u8,
    nullable: bool,
    primary_key: bool,
    conversion: Conversion,
};

pub const TablePlan = struct {
    source_name: []const u8,
    destination_schema: []const u8,
    destination_name: []const u8,
    columns: []ColumnPlan,
};

pub const TransferPlan = struct {
    allocator: std.mem.Allocator,
    tables: []TablePlan,

    pub fn deinit(self: *TransferPlan) void {
        for (self.tables) |table| self.allocator.free(table.columns);
        self.allocator.free(self.tables);
        self.* = undefined;
    }
};

pub const Error = error{
    AmbiguousDestinationTable,
    MissingDestinationTable,
    MissingDestinationColumn,
    ExtraDestinationColumn,
    ExtraDestinationTable,
    UnsupportedArray,
    UnsupportedType,
    IncompatibleType,
    InvalidDestinationName,
} || std.mem.Allocator.Error;

pub fn plan(
    allocator: std.mem.Allocator,
    sqlite: *const catalog.Catalog,
    postgres: *const catalog.Catalog,
    default_schema: []const u8,
) Error!TransferPlan {
    var tables: std.ArrayList(TablePlan) = .empty;
    errdefer {
        for (tables.items) |table| allocator.free(table.columns);
        tables.deinit(allocator);
    }

    var source_tables = sqlite.tables.iterator();
    var planned_table_count: usize = 0;
    while (source_tables.next()) |entry| {
        const source = entry.value_ptr;
        if (source.is_view or std.mem.startsWith(u8, source.name, "sqlite_")) continue;

        const destination = try findDestinationTable(postgres, source.name, default_schema);
        if (destination.is_view) return error.MissingDestinationTable;
        const destination_name = splitQualified(destination.name, default_schema) orelse
            return error.InvalidDestinationName;

        if (source.columns.count() != destination.columns.count())
            return error.ExtraDestinationColumn;
        const columns = try allocator.alloc(ColumnPlan, source.columns.count());
        errdefer allocator.free(columns);
        var index: usize = 0;
        var source_columns = source.columns.iterator();
        while (source_columns.next()) |column_entry| : (index += 1) {
            const source_column = column_entry.value_ptr;
            const destination_column = destination.columns.get(source_column.name) orelse
                return error.MissingDestinationColumn;
            if (source_column.array_dimensions != 0 or destination_column.array_dimensions != 0)
                return error.UnsupportedArray;
            if (std.ascii.eqlIgnoreCase(destination_column.database_type, "numeric") or
                std.ascii.eqlIgnoreCase(destination_column.database_type, "decimal"))
                return error.UnsupportedType;
            const source_type = analysis.scalarType(source_column.database_type);
            const destination_type = analysis.scalarType(destination_column.database_type);
            const conversion = try compatibleConversion(source_type, destination_type);
            columns[index] = .{
                .source_name = source_column.name,
                .source_type = source_column.database_type,
                .source_nullable = source_column.nullable,
                .source_primary_key = source_column.primary_key,
                .destination_name = destination_column.name,
                .destination_type = destination_column.database_type,
                .nullable = destination_column.nullable,
                .primary_key = destination_column.primary_key,
                .conversion = conversion,
            };
        }
        try tables.append(allocator, .{
            .source_name = source.name,
            .destination_schema = destination_name.schema,
            .destination_name = destination_name.name,
            .columns = columns,
        });
        planned_table_count += 1;
    }

    var destination_table_count: usize = 0;
    var destination_tables = postgres.tables.iterator();
    while (destination_tables.next()) |entry| if (!entry.value_ptr.is_view) {
        destination_table_count += 1;
    };
    if (planned_table_count != destination_table_count) return error.ExtraDestinationTable;

    return .{ .allocator = allocator, .tables = try tables.toOwnedSlice(allocator) };
}

fn compatibleConversion(source: analysis.ScalarType, destination: analysis.ScalarType) Error!Conversion {
    if (source == .unknown or destination == .unknown) return error.UnsupportedType;
    return switch (destination) {
        .integer => if (source == .integer) .integer else error.IncompatibleType,
        .real => if (source == .real or source == .integer) .real else error.IncompatibleType,
        .text => if (source == .text) .text else error.IncompatibleType,
        .blob => if (source == .blob) .blob else error.IncompatibleType,
        .boolean => if (source == .boolean or source == .integer) .boolean else error.IncompatibleType,
        .unknown => error.UnsupportedType,
    };
}

fn findDestinationTable(
    postgres: *const catalog.Catalog,
    source_name: []const u8,
    default_schema: []const u8,
) Error!*const catalog.Table {
    if (postgres.tables.getPtr(source_name)) |table| return table;
    const qualified = try std.fmt.allocPrint(postgres.allocator, "{s}.{s}", .{ default_schema, source_name });
    defer postgres.allocator.free(qualified);
    if (postgres.tables.getPtr(qualified)) |table| return table;

    var match: ?*const catalog.Table = null;
    var tables = postgres.tables.iterator();
    while (tables.next()) |entry| {
        const name = splitQualified(entry.value_ptr.name, default_schema) orelse continue;
        if (!std.mem.eql(u8, name.name, source_name)) continue;
        if (match != null) return error.AmbiguousDestinationTable;
        match = entry.value_ptr;
    }
    return match orelse error.MissingDestinationTable;
}

const QualifiedName = struct { schema: []const u8, name: []const u8 };

fn splitQualified(name: []const u8, default_schema: []const u8) ?QualifiedName {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    if (dot == null) return .{ .schema = default_schema, .name = name };
    if (dot.? == 0 or dot.? + 1 == name.len or std.mem.indexOfScalarPos(u8, name, dot.? + 1, '.') != null)
        return null;
    return .{ .schema = name[0..dot.?], .name = name[dot.? + 1 ..] };
}
