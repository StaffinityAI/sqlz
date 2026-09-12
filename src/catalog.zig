const std = @import("std");

pub const Column = struct {
    name: []const u8,
    database_type: []const u8,
    nullable: bool,
    primary_key: bool,
};

pub const Table = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    columns: std.StringArrayHashMapUnmanaged(Column) = .empty,

    pub fn deinit(self: *Table) void {
        var iterator = self.columns.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.database_type);
        }
        self.columns.deinit(self.allocator);
        self.allocator.free(self.name);
        self.* = undefined;
    }
};

pub const Error = error{
    InvalidAst,
    UnsupportedStatement,
    DuplicateTable,
    DuplicateColumn,
} || std.mem.Allocator.Error || std.json.ParseError(std.json.Scanner);

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    tables: std.StringArrayHashMapUnmanaged(Table) = .empty,

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Catalog) void {
        var iterator = self.tables.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit();
        self.tables.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn table(self: *const Catalog, name: []const u8) ?*const Table {
        return self.tables.getPtr(name);
    }

    pub fn applyParserJson(self: *Catalog, ast_json: []const u8) Error!void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, ast_json, .{});
        defer parsed.deinit();

        const statements = field(parsed.value, "stmts") orelse return error.InvalidAst;
        if (statements != .array) return error.InvalidAst;
        for (statements.array.items) |statement| {
            const stmt = field(statement, "stmt") orelse return error.InvalidAst;
            const create = field(stmt, "CreateStmt") orelse return error.UnsupportedStatement;
            try self.applyCreateTable(create);
        }
    }

    fn applyCreateTable(self: *Catalog, create: std.json.Value) Error!void {
        const relation = field(create, "relation") orelse return error.InvalidAst;
        const name_value = field(relation, "relname") orelse return error.InvalidAst;
        if (name_value != .string) return error.InvalidAst;
        if (self.tables.contains(name_value.string)) return error.DuplicateTable;

        var table_value: Table = .{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, name_value.string),
        };
        errdefer table_value.deinit();

        const elements = field(create, "tableElts") orelse return error.InvalidAst;
        if (elements != .array) return error.InvalidAst;
        for (elements.array.items) |element| {
            const definition = field(element, "ColumnDef") orelse continue;
            try addColumn(&table_value, definition);
        }
        if (table_value.columns.count() == 0) return error.InvalidAst;
        try self.tables.putNoClobber(self.allocator, table_value.name, table_value);
    }
};

fn addColumn(table: *Table, definition: std.json.Value) Error!void {
    const name_value = field(definition, "colname") orelse return error.InvalidAst;
    const type_name = field(definition, "typeName") orelse return error.InvalidAst;
    if (name_value != .string) return error.InvalidAst;
    if (table.columns.contains(name_value.string)) return error.DuplicateColumn;

    const type_parts = field(type_name, "names") orelse return error.InvalidAst;
    if (type_parts != .array or type_parts.array.items.len == 0) return error.InvalidAst;
    const last = type_parts.array.items[type_parts.array.items.len - 1];
    const string_node = field(last, "String") orelse return error.InvalidAst;
    const type_value = field(string_node, "sval") orelse return error.InvalidAst;
    if (type_value != .string) return error.InvalidAst;

    var nullable = true;
    var primary_key = false;
    if (field(definition, "constraints")) |constraints| {
        if (constraints != .array) return error.InvalidAst;
        for (constraints.array.items) |item| {
            const constraint = field(item, "Constraint") orelse continue;
            const kind = field(constraint, "contype") orelse continue;
            if (kind != .string) continue;
            if (std.mem.eql(u8, kind.string, "CONSTR_NOTNULL")) nullable = false;
            if (std.mem.eql(u8, kind.string, "CONSTR_PRIMARY")) {
                nullable = false;
                primary_key = true;
            }
        }
    }

    const name = try table.allocator.dupe(u8, name_value.string);
    errdefer table.allocator.free(name);
    const database_type = try table.allocator.dupe(u8, type_value.string);
    errdefer table.allocator.free(database_type);
    try table.columns.putNoClobber(table.allocator, name, .{
        .name = name,
        .database_type = database_type,
        .nullable = nullable,
        .primary_key = primary_key,
    });
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}
