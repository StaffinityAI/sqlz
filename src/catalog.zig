const std = @import("std");

pub const Column = struct {
    name: []const u8,
    database_type: []const u8,
    nullable: bool,
    primary_key: bool,
    unique: bool,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    table_name: []const u8,
    columns: []const []const u8,
    unique: bool,

    pub fn deinit(self: *Index) void {
        self.allocator.free(self.name);
        self.allocator.free(self.table_name);
        for (self.columns) |column| self.allocator.free(column);
        self.allocator.free(self.columns);
        self.* = undefined;
    }
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
    MissingTable,
    MissingColumn,
    DuplicateIndex,
    MissingIndex,
} || std.mem.Allocator.Error || std.json.ParseError(std.json.Scanner);

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    tables: std.StringArrayHashMapUnmanaged(Table) = .empty,
    indexes: std.StringArrayHashMapUnmanaged(Index) = .empty,

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Catalog) void {
        var iterator = self.tables.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit();
        self.tables.deinit(self.allocator);
        var indexes = self.indexes.iterator();
        while (indexes.next()) |entry| entry.value_ptr.deinit();
        self.indexes.deinit(self.allocator);
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
            if (field(stmt, "CreateStmt")) |create| {
                try self.applyCreateTable(create);
            } else if (field(stmt, "IndexStmt")) |index| {
                try self.applyCreateIndex(index);
            } else if (field(stmt, "AlterTableStmt")) |alter| {
                try self.applyAlterTable(alter);
            } else if (field(stmt, "DropStmt")) |drop| {
                try self.applyDrop(drop);
            } else {
                return error.UnsupportedStatement;
            }
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
        for (elements.array.items) |element| {
            const constraint = field(element, "Constraint") orelse continue;
            try applyTableConstraint(&table_value, constraint);
        }
        if (table_value.columns.count() == 0) return error.InvalidAst;
        try self.tables.putNoClobber(self.allocator, table_value.name, table_value);
    }

    fn applyCreateIndex(self: *Catalog, node: std.json.Value) Error!void {
        const name_value = field(node, "idxname") orelse return error.InvalidAst;
        const relation = field(node, "relation") orelse return error.InvalidAst;
        const table_value = field(relation, "relname") orelse return error.InvalidAst;
        const params = field(node, "indexParams") orelse return error.InvalidAst;
        if (name_value != .string or table_value != .string or params != .array)
            return error.InvalidAst;
        if (self.indexes.contains(name_value.string)) return error.DuplicateIndex;
        const table_ptr = self.tables.getPtr(table_value.string) orelse return error.MissingTable;

        var columns: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (columns.items) |column| self.allocator.free(column);
            columns.deinit(self.allocator);
        }
        for (params.array.items) |param| {
            const element = field(param, "IndexElem") orelse return error.InvalidAst;
            const column = field(element, "name") orelse return error.InvalidAst;
            if (column != .string or !table_ptr.columns.contains(column.string))
                return error.MissingColumn;
            try columns.append(self.allocator, try self.allocator.dupe(u8, column.string));
        }
        const name = try self.allocator.dupe(u8, name_value.string);
        errdefer self.allocator.free(name);
        const table_name = try self.allocator.dupe(u8, table_value.string);
        errdefer self.allocator.free(table_name);
        const owned_columns = try columns.toOwnedSlice(self.allocator);
        errdefer {
            for (owned_columns) |column| self.allocator.free(column);
            self.allocator.free(owned_columns);
        }
        const unique = if (field(node, "unique")) |value|
            value == .bool and value.bool
        else
            false;
        try self.indexes.putNoClobber(self.allocator, name, .{
            .allocator = self.allocator,
            .name = name,
            .table_name = table_name,
            .columns = owned_columns,
            .unique = unique,
        });
    }

    fn applyAlterTable(self: *Catalog, node: std.json.Value) Error!void {
        const relation = field(node, "relation") orelse return error.InvalidAst;
        const table_value = field(relation, "relname") orelse return error.InvalidAst;
        const commands = field(node, "cmds") orelse return error.InvalidAst;
        if (table_value != .string or commands != .array) return error.InvalidAst;
        const table_ptr = self.tables.getPtr(table_value.string) orelse return error.MissingTable;
        for (commands.array.items) |command_value| {
            const command = field(command_value, "AlterTableCmd") orelse return error.InvalidAst;
            const subtype = field(command, "subtype") orelse return error.InvalidAst;
            if (subtype != .string) return error.InvalidAst;
            if (std.mem.eql(u8, subtype.string, "AT_AddColumn")) {
                const definition = field(command, "def") orelse return error.InvalidAst;
                const column = field(definition, "ColumnDef") orelse return error.InvalidAst;
                try addColumn(table_ptr, column);
            } else if (std.mem.eql(u8, subtype.string, "AT_DropColumn")) {
                const name = field(command, "name") orelse return error.InvalidAst;
                if (name != .string) return error.InvalidAst;
                const removed = table_ptr.columns.fetchOrderedRemove(name.string) orelse
                    return error.MissingColumn;
                table_ptr.allocator.free(removed.value.name);
                table_ptr.allocator.free(removed.value.database_type);
            } else {
                return error.UnsupportedStatement;
            }
        }
    }

    fn applyDrop(self: *Catalog, node: std.json.Value) Error!void {
        const kind = field(node, "removeType") orelse return error.InvalidAst;
        const objects = field(node, "objects") orelse return error.InvalidAst;
        if (kind != .string or objects != .array) return error.InvalidAst;
        for (objects.array.items) |object| {
            const list = field(object, "List") orelse return error.InvalidAst;
            const items = field(list, "items") orelse return error.InvalidAst;
            if (items != .array or items.array.items.len == 0) return error.InvalidAst;
            const string_node = field(items.array.items[items.array.items.len - 1], "String") orelse
                return error.InvalidAst;
            const name = field(string_node, "sval") orelse return error.InvalidAst;
            if (name != .string) return error.InvalidAst;
            if (std.mem.eql(u8, kind.string, "OBJECT_TABLE")) {
                var removed = self.tables.fetchOrderedRemove(name.string) orelse
                    return error.MissingTable;
                removed.value.deinit();
            } else if (std.mem.eql(u8, kind.string, "OBJECT_INDEX")) {
                var removed = self.indexes.fetchOrderedRemove(name.string) orelse
                    return error.MissingIndex;
                removed.value.deinit();
            } else {
                return error.UnsupportedStatement;
            }
        }
    }
};

fn applyTableConstraint(table: *Table, constraint: std.json.Value) Error!void {
    const kind = field(constraint, "contype") orelse return error.InvalidAst;
    if (kind != .string) return error.InvalidAst;
    const primary = std.mem.eql(u8, kind.string, "CONSTR_PRIMARY");
    const unique = primary or std.mem.eql(u8, kind.string, "CONSTR_UNIQUE");
    if (!unique) return;

    const keys = field(constraint, "keys") orelse return error.InvalidAst;
    if (keys != .array or keys.array.items.len == 0) return error.InvalidAst;
    for (keys.array.items) |item| {
        const string_node = field(item, "String") orelse return error.InvalidAst;
        const name = field(string_node, "sval") orelse return error.InvalidAst;
        if (name != .string) return error.InvalidAst;
        const column = table.columns.getPtr(name.string) orelse return error.MissingColumn;
        column.unique = true;
        if (primary) {
            column.primary_key = true;
            column.nullable = false;
        }
    }
}

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
    var unique = false;
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
                unique = true;
            }
            if (std.mem.eql(u8, kind.string, "CONSTR_UNIQUE")) unique = true;
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
        .unique = unique,
    });
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}
