const std = @import("std");
const parser = @import("sqlz_parser");
const pg = parser.ast;

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
    columns: [][]const u8,
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
    is_view: bool = false,
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
} || std.mem.Allocator.Error;

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

    pub fn clone(self: *const Catalog, allocator: std.mem.Allocator) std.mem.Allocator.Error!Catalog {
        var copy = Catalog.init(allocator);
        errdefer copy.deinit();

        var tables = self.tables.iterator();
        while (tables.next()) |entry| {
            const source = entry.value_ptr;
            var table_copy: Table = .{
                .allocator = allocator,
                .name = try allocator.dupe(u8, source.name),
                .is_view = source.is_view,
            };
            errdefer table_copy.deinit();
            var columns = source.columns.iterator();
            while (columns.next()) |column_entry| {
                const column = column_entry.value_ptr;
                const name = try allocator.dupe(u8, column.name);
                errdefer allocator.free(name);
                const database_type = try allocator.dupe(u8, column.database_type);
                errdefer allocator.free(database_type);
                try table_copy.columns.putNoClobber(allocator, name, .{
                    .name = name,
                    .database_type = database_type,
                    .nullable = column.nullable,
                    .primary_key = column.primary_key,
                    .unique = column.unique,
                });
            }
            try copy.tables.putNoClobber(allocator, table_copy.name, table_copy);
        }

        var indexes = self.indexes.iterator();
        while (indexes.next()) |entry| {
            const source = entry.value_ptr;
            const name = try allocator.dupe(u8, source.name);
            errdefer allocator.free(name);
            const table_name = try allocator.dupe(u8, source.table_name);
            errdefer allocator.free(table_name);
            const columns = try allocator.alloc([]const u8, source.columns.len);
            var copied: usize = 0;
            errdefer {
                for (columns[0..copied]) |column| allocator.free(column);
                allocator.free(columns);
            }
            for (source.columns, 0..) |column, index| {
                columns[index] = try allocator.dupe(u8, column);
                copied += 1;
            }
            try copy.indexes.putNoClobber(allocator, name, .{
                .allocator = allocator,
                .name = name,
                .table_name = table_name,
                .columns = columns,
                .unique = source.unique,
            });
        }
        return copy;
    }

    pub fn eql(self: *const Catalog, other: *const Catalog) bool {
        if (self.tables.count() != other.tables.count() or
            self.indexes.count() != other.indexes.count()) return false;

        var tables = self.tables.iterator();
        while (tables.next()) |entry| {
            const right = other.tables.get(entry.key_ptr.*) orelse return false;
            const left = entry.value_ptr;
            if (left.is_view != right.is_view or left.columns.count() != right.columns.count())
                return false;
            var columns = left.columns.iterator();
            while (columns.next()) |column_entry| {
                const right_column = right.columns.get(column_entry.key_ptr.*) orelse return false;
                const left_column = column_entry.value_ptr;
                if (!std.mem.eql(u8, left_column.database_type, right_column.database_type) or
                    left_column.nullable != right_column.nullable or
                    left_column.primary_key != right_column.primary_key or
                    left_column.unique != right_column.unique) return false;
            }
        }

        var indexes = self.indexes.iterator();
        while (indexes.next()) |entry| {
            const right = other.indexes.get(entry.key_ptr.*) orelse return false;
            const left = entry.value_ptr;
            if (!std.mem.eql(u8, left.table_name, right.table_name) or
                left.unique != right.unique or left.columns.len != right.columns.len)
                return false;
            for (left.columns, right.columns) |left_column, right_column| {
                if (!std.mem.eql(u8, left_column, right_column)) return false;
            }
        }
        return true;
    }

    pub fn applyParserTree(self: *Catalog, tree: *const pg.PgQuery__ParseResult) Error!void {
        for (rawSlice(tree.stmts, tree.n_stmts)) |raw| {
            if (raw == null or raw.*.stmt == null) return error.InvalidAst;
            const node = raw.*.stmt;
            switch (node.*.node_case) {
                pg.PG_QUERY__NODE__NODE_CREATE_STMT => try self.applyCreateTable(node.*.unnamed_0.create_stmt),
                pg.PG_QUERY__NODE__NODE_VIEW_STMT => try self.applyCreateView(node.*.unnamed_0.view_stmt),
                pg.PG_QUERY__NODE__NODE_INDEX_STMT => try self.applyCreateIndex(node.*.unnamed_0.index_stmt),
                pg.PG_QUERY__NODE__NODE_ALTER_TABLE_STMT => try self.applyAlterTable(node.*.unnamed_0.alter_table_stmt),
                pg.PG_QUERY__NODE__NODE_RENAME_STMT => try self.applyRename(node.*.unnamed_0.rename_stmt),
                pg.PG_QUERY__NODE__NODE_DROP_STMT => try self.applyDrop(node.*.unnamed_0.drop_stmt),
                else => return error.UnsupportedStatement,
            }
        }
    }

    fn applyCreateTable(self: *Catalog, create_ptr: [*c]pg.PgQuery__CreateStmt) Error!void {
        if (create_ptr == null or create_ptr.*.relation == null) return error.InvalidAst;
        const create = create_ptr.*;
        const table_name = cString(create.relation.*.relname) orelse return error.InvalidAst;
        if (self.tables.contains(table_name)) return error.DuplicateTable;

        var table_value: Table = .{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, table_name),
        };
        errdefer table_value.deinit();

        for (nodeSlice(create.table_elts, create.n_table_elts)) |element| {
            if (element.*.node_case == pg.PG_QUERY__NODE__NODE_COLUMN_DEF)
                try addColumn(&table_value, element.*.unnamed_0.column_def);
        }
        for (nodeSlice(create.table_elts, create.n_table_elts)) |element| {
            if (element.*.node_case == pg.PG_QUERY__NODE__NODE_CONSTRAINT)
                try applyTableConstraint(&table_value, element.*.unnamed_0.constraint);
        }
        if (table_value.columns.count() == 0) return error.InvalidAst;
        try self.tables.putNoClobber(self.allocator, table_value.name, table_value);
    }

    fn applyCreateIndex(self: *Catalog, node_ptr: [*c]pg.PgQuery__IndexStmt) Error!void {
        if (node_ptr == null or node_ptr.*.relation == null) return error.InvalidAst;
        const node = node_ptr.*;
        const index_name = cString(node.idxname) orelse return error.InvalidAst;
        const table_name_value = cString(node.relation.*.relname) orelse return error.InvalidAst;
        if (self.indexes.contains(index_name)) return error.DuplicateIndex;
        const table_ptr = self.tables.getPtr(table_name_value) orelse return error.MissingTable;

        var columns: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (columns.items) |column| self.allocator.free(column);
            columns.deinit(self.allocator);
        }
        for (nodeSlice(node.index_params, node.n_index_params)) |param| {
            if (param.*.node_case != pg.PG_QUERY__NODE__NODE_INDEX_ELEM) return error.InvalidAst;
            const column = cString(param.*.unnamed_0.index_elem.*.name) orelse return error.InvalidAst;
            if (!table_ptr.columns.contains(column)) return error.MissingColumn;
            try columns.append(self.allocator, try self.allocator.dupe(u8, column));
        }
        const name = try self.allocator.dupe(u8, index_name);
        errdefer self.allocator.free(name);
        const table_name = try self.allocator.dupe(u8, table_name_value);
        errdefer self.allocator.free(table_name);
        const owned_columns = try columns.toOwnedSlice(self.allocator);
        errdefer {
            for (owned_columns) |column| self.allocator.free(column);
            self.allocator.free(owned_columns);
        }
        try self.indexes.putNoClobber(self.allocator, name, .{
            .allocator = self.allocator,
            .name = name,
            .table_name = table_name,
            .columns = owned_columns,
            .unique = node.unique != 0,
        });
    }

    fn applyCreateView(self: *Catalog, node_ptr: [*c]pg.PgQuery__ViewStmt) Error!void {
        if (node_ptr == null or node_ptr.*.view == null or node_ptr.*.query == null)
            return error.InvalidAst;
        const node = node_ptr.*;
        if (node.replace != 0 or node.query.*.node_case != pg.PG_QUERY__NODE__NODE_SELECT_STMT)
            return error.UnsupportedStatement;
        const view_name = cString(node.view.*.relname) orelse return error.InvalidAst;
        if (self.tables.contains(view_name)) return error.DuplicateTable;
        const select = node.query.*.unnamed_0.select_stmt;
        if (select == null or select.*.op != pg.PG_QUERY__SET_OPERATION__SETOP_NONE)
            return error.UnsupportedStatement;

        var bindings: std.ArrayList(ViewBinding) = .empty;
        defer bindings.deinit(self.allocator);
        for (nodeSlice(select.*.from_clause, select.*.n_from_clause)) |from|
            try self.collectViewBindings(&bindings, from, false);
        const targets = nodeSlice(select.*.target_list, select.*.n_target_list);
        const aliases = nodeSlice(node.aliases, node.n_aliases);
        if (aliases.len != 0 and aliases.len != targets.len) return error.InvalidAst;

        var view: Table = .{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, view_name),
            .is_view = true,
        };
        errdefer view.deinit();
        for (targets, 0..) |target_node, index| {
            const target = resTarget(target_node) orelse return error.InvalidAst;
            const source = try resolveViewColumn(bindings.items, target.val);
            const result_name = if (aliases.len != 0)
                nodeString(aliases[index]) orelse return error.InvalidAst
            else
                viewResultName(target) orelse return error.InvalidAst;
            try addCopiedColumn(&view, result_name, source.column, source.nullable);
        }
        if (view.columns.count() == 0) return error.InvalidAst;
        try self.tables.putNoClobber(self.allocator, view.name, view);
    }

    fn applyAlterTable(self: *Catalog, node_ptr: [*c]pg.PgQuery__AlterTableStmt) Error!void {
        if (node_ptr == null or node_ptr.*.relation == null) return error.InvalidAst;
        const node = node_ptr.*;
        const table_name = cString(node.relation.*.relname) orelse return error.InvalidAst;
        const table_ptr = self.tables.getPtr(table_name) orelse return error.MissingTable;
        for (nodeSlice(node.cmds, node.n_cmds)) |command_node| {
            if (command_node.*.node_case != pg.PG_QUERY__NODE__NODE_ALTER_TABLE_CMD)
                return error.InvalidAst;
            const command = command_node.*.unnamed_0.alter_table_cmd.*;
            if (command.subtype == pg.PG_QUERY__ALTER_TABLE_TYPE__AT_AddColumn) {
                if (command.def == null or command.def.*.node_case != pg.PG_QUERY__NODE__NODE_COLUMN_DEF)
                    return error.InvalidAst;
                try addColumn(table_ptr, command.def.*.unnamed_0.column_def);
            } else if (command.subtype == pg.PG_QUERY__ALTER_TABLE_TYPE__AT_DropColumn) {
                const name = cString(command.name) orelse return error.InvalidAst;
                const removed = table_ptr.columns.fetchOrderedRemove(name) orelse
                    return error.MissingColumn;
                table_ptr.allocator.free(removed.value.name);
                table_ptr.allocator.free(removed.value.database_type);
            } else {
                return error.UnsupportedStatement;
            }
        }
    }

    fn applyDrop(self: *Catalog, node_ptr: [*c]pg.PgQuery__DropStmt) Error!void {
        if (node_ptr == null) return error.InvalidAst;
        const node = node_ptr.*;
        for (nodeSlice(node.objects, node.n_objects)) |object| {
            if (object.*.node_case != pg.PG_QUERY__NODE__NODE_LIST) return error.InvalidAst;
            const list = object.*.unnamed_0.list.*;
            if (list.n_items == 0) return error.InvalidAst;
            const name = nodeString(list.items[list.n_items - 1]) orelse return error.InvalidAst;
            if (node.remove_type == pg.PG_QUERY__OBJECT_TYPE__OBJECT_TABLE or
                node.remove_type == pg.PG_QUERY__OBJECT_TYPE__OBJECT_VIEW)
            {
                var removed = self.tables.fetchOrderedRemove(name) orelse
                    return error.MissingTable;
                if ((node.remove_type == pg.PG_QUERY__OBJECT_TYPE__OBJECT_VIEW) != removed.value.is_view) {
                    try self.tables.putNoClobber(self.allocator, removed.value.name, removed.value);
                    return error.MissingTable;
                }
                try self.removeIndexesForTable(name);
                removed.value.deinit();
            } else if (node.remove_type == pg.PG_QUERY__OBJECT_TYPE__OBJECT_INDEX) {
                var removed = self.indexes.fetchOrderedRemove(name) orelse
                    return error.MissingIndex;
                removed.value.deinit();
            } else {
                return error.UnsupportedStatement;
            }
        }
    }

    fn applyRename(self: *Catalog, node_ptr: [*c]pg.PgQuery__RenameStmt) Error!void {
        if (node_ptr == null or node_ptr.*.relation == null) return error.InvalidAst;
        const node = node_ptr.*;
        const table_name = cString(node.relation.*.relname) orelse return error.InvalidAst;
        const new_name = cString(node.newname) orelse return error.InvalidAst;
        if (new_name.len == 0) return error.InvalidAst;
        if (node.rename_type == pg.PG_QUERY__OBJECT_TYPE__OBJECT_TABLE) {
            try self.renameTable(table_name, new_name);
        } else if (node.rename_type == pg.PG_QUERY__OBJECT_TYPE__OBJECT_COLUMN) {
            const old_name = cString(node.subname) orelse return error.InvalidAst;
            if (old_name.len == 0) return error.InvalidAst;
            try self.renameColumn(table_name, old_name, new_name);
        } else {
            return error.UnsupportedStatement;
        }
    }

    fn removeIndexesForTable(self: *Catalog, table_name: []const u8) Error!void {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var indexes = self.indexes.iterator();
        while (indexes.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.table_name, table_name))
                try names.append(self.allocator, entry.key_ptr.*);
        }
        for (names.items) |name| {
            var removed = self.indexes.fetchOrderedRemove(name) orelse continue;
            removed.value.deinit();
        }
    }

    fn renameTable(self: *Catalog, old_name: []const u8, new_name: []const u8) Error!void {
        if (self.tables.contains(new_name)) return error.DuplicateTable;
        const owned_name = try self.allocator.dupe(u8, new_name);
        errdefer self.allocator.free(owned_name);
        var removed = self.tables.fetchOrderedRemove(old_name) orelse return error.MissingTable;
        self.allocator.free(removed.value.name);
        removed.value.name = owned_name;
        try self.tables.putNoClobber(self.allocator, owned_name, removed.value);

        var indexes = self.indexes.iterator();
        while (indexes.next()) |entry| {
            if (!std.mem.eql(u8, entry.value_ptr.table_name, old_name)) continue;
            const replacement = try self.allocator.dupe(u8, new_name);
            self.allocator.free(entry.value_ptr.table_name);
            entry.value_ptr.table_name = replacement;
        }
    }

    fn renameColumn(
        self: *Catalog,
        table_name: []const u8,
        old_name: []const u8,
        new_name: []const u8,
    ) Error!void {
        const table_ptr = self.tables.getPtr(table_name) orelse return error.MissingTable;
        if (table_ptr.columns.contains(new_name)) return error.DuplicateColumn;
        const owned_name = try self.allocator.dupe(u8, new_name);
        errdefer self.allocator.free(owned_name);
        var removed = table_ptr.columns.fetchOrderedRemove(old_name) orelse return error.MissingColumn;
        self.allocator.free(removed.value.name);
        removed.value.name = owned_name;
        try table_ptr.columns.putNoClobber(self.allocator, owned_name, removed.value);

        var indexes = self.indexes.iterator();
        while (indexes.next()) |entry| {
            if (!std.mem.eql(u8, entry.value_ptr.table_name, table_name)) continue;
            for (entry.value_ptr.columns) |*column| {
                if (!std.mem.eql(u8, column.*, old_name)) continue;
                const replacement = try self.allocator.dupe(u8, new_name);
                self.allocator.free(column.*);
                column.* = replacement;
            }
        }
    }

    fn collectViewBindings(
        self: *const Catalog,
        bindings: *std.ArrayList(ViewBinding),
        node: [*c]pg.PgQuery__Node,
        nullable: bool,
    ) Error!void {
        if (node == null) return error.InvalidAst;
        switch (node.*.node_case) {
            pg.PG_QUERY__NODE__NODE_RANGE_VAR => {
                const range = node.*.unnamed_0.range_var;
                if (range == null) return error.InvalidAst;
                const name = cString(range.*.relname) orelse return error.InvalidAst;
                const table_ptr = self.tables.getPtr(name) orelse return error.MissingTable;
                const alias = if (range.*.alias != null) value: {
                    const candidate = cString(range.*.alias.*.aliasname) orelse return error.InvalidAst;
                    break :value if (candidate.len == 0) null else candidate;
                } else null;
                try bindings.append(self.allocator, .{
                    .name = name,
                    .alias = alias,
                    .table = table_ptr,
                    .nullable = nullable,
                });
            },
            pg.PG_QUERY__NODE__NODE_JOIN_EXPR => {
                const join = node.*.unnamed_0.join_expr;
                if (join == null) return error.InvalidAst;
                try self.collectViewBindings(
                    bindings,
                    join.*.larg,
                    nullable or join.*.jointype == pg.PG_QUERY__JOIN_TYPE__JOIN_RIGHT or
                        join.*.jointype == pg.PG_QUERY__JOIN_TYPE__JOIN_FULL,
                );
                try self.collectViewBindings(
                    bindings,
                    join.*.rarg,
                    nullable or join.*.jointype == pg.PG_QUERY__JOIN_TYPE__JOIN_LEFT or
                        join.*.jointype == pg.PG_QUERY__JOIN_TYPE__JOIN_FULL,
                );
            },
            else => return error.UnsupportedStatement,
        }
    }
};

const ViewBinding = struct {
    name: []const u8,
    alias: ?[]const u8,
    table: *const Table,
    nullable: bool,
};

const ResolvedViewColumn = struct {
    column: *const Column,
    nullable: bool,
};

fn resolveViewColumn(bindings: []const ViewBinding, node: [*c]pg.PgQuery__Node) Error!ResolvedViewColumn {
    if (node == null or node.*.node_case != pg.PG_QUERY__NODE__NODE_COLUMN_REF)
        return error.UnsupportedStatement;
    const reference = node.*.unnamed_0.column_ref;
    if (reference == null or reference.*.n_fields == 0) return error.InvalidAst;
    const fields = nodeSlice(reference.*.fields, reference.*.n_fields);
    const column_name = nodeString(fields[fields.len - 1]) orelse return error.UnsupportedStatement;
    const qualifier = if (fields.len >= 2) nodeString(fields[fields.len - 2]) else null;
    var found: ?ResolvedViewColumn = null;
    for (bindings) |binding| {
        if (qualifier) |name| {
            const alias_match = if (binding.alias) |alias| std.mem.eql(u8, alias, name) else false;
            if (!alias_match and !std.mem.eql(u8, binding.name, name)) continue;
        }
        const column = binding.table.columns.getPtr(column_name) orelse continue;
        if (found != null) return error.InvalidAst;
        found = .{ .column = column, .nullable = column.nullable or binding.nullable };
    }
    return found orelse error.MissingColumn;
}

fn viewResultName(target: *const pg.PgQuery__ResTarget) ?[]const u8 {
    if (cString(target.name)) |name| if (name.len != 0) return name;
    if (target.val == null or target.val.*.node_case != pg.PG_QUERY__NODE__NODE_COLUMN_REF) return null;
    const reference = target.val.*.unnamed_0.column_ref;
    if (reference == null or reference.*.n_fields == 0) return null;
    return nodeString(reference.*.fields[reference.*.n_fields - 1]);
}

fn addCopiedColumn(table: *Table, name_value: []const u8, source: *const Column, nullable: bool) Error!void {
    if (table.columns.contains(name_value)) return error.DuplicateColumn;
    const name = try table.allocator.dupe(u8, name_value);
    errdefer table.allocator.free(name);
    const database_type = try table.allocator.dupe(u8, source.database_type);
    errdefer table.allocator.free(database_type);
    try table.columns.putNoClobber(table.allocator, name, .{
        .name = name,
        .database_type = database_type,
        .nullable = nullable,
        .primary_key = false,
        .unique = false,
    });
}

fn applyTableConstraint(table: *Table, constraint_ptr: [*c]pg.PgQuery__Constraint) Error!void {
    if (constraint_ptr == null) return error.InvalidAst;
    const constraint = constraint_ptr.*;
    const primary = constraint.contype == pg.PG_QUERY__CONSTR_TYPE__CONSTR_PRIMARY;
    const unique = primary or constraint.contype == pg.PG_QUERY__CONSTR_TYPE__CONSTR_UNIQUE;
    if (!unique) return;
    if (constraint.n_keys == 0) return error.InvalidAst;
    for (nodeSlice(constraint.keys, constraint.n_keys)) |item| {
        const name = nodeString(item) orelse return error.InvalidAst;
        const column = table.columns.getPtr(name) orelse return error.MissingColumn;
        column.unique = true;
        if (primary) {
            column.primary_key = true;
            column.nullable = false;
        }
    }
}

fn addColumn(table: *Table, definition_ptr: [*c]pg.PgQuery__ColumnDef) Error!void {
    if (definition_ptr == null or definition_ptr.*.type_name == null) return error.InvalidAst;
    const definition = definition_ptr.*;
    const column_name = cString(definition.colname) orelse return error.InvalidAst;
    if (table.columns.contains(column_name)) return error.DuplicateColumn;
    const type_name = definition.type_name.*;
    if (type_name.n_names == 0) return error.InvalidAst;
    const database_type_value = nodeString(type_name.names[type_name.n_names - 1]) orelse
        return error.InvalidAst;

    var nullable = true;
    var primary_key = false;
    var unique = false;
    for (nodeSlice(definition.constraints, definition.n_constraints)) |item| {
        if (item.*.node_case != pg.PG_QUERY__NODE__NODE_CONSTRAINT) continue;
        const kind = item.*.unnamed_0.constraint.*.contype;
        if (kind == pg.PG_QUERY__CONSTR_TYPE__CONSTR_NOTNULL) nullable = false;
        if (kind == pg.PG_QUERY__CONSTR_TYPE__CONSTR_PRIMARY) {
            nullable = false;
            primary_key = true;
            unique = true;
        }
        if (kind == pg.PG_QUERY__CONSTR_TYPE__CONSTR_UNIQUE) unique = true;
    }

    const name = try table.allocator.dupe(u8, column_name);
    errdefer table.allocator.free(name);
    const database_type = try table.allocator.dupe(u8, database_type_value);
    errdefer table.allocator.free(database_type);
    try table.columns.putNoClobber(table.allocator, name, .{
        .name = name,
        .database_type = database_type,
        .nullable = nullable,
        .primary_key = primary_key,
        .unique = unique,
    });
}

fn nodeString(node: [*c]pg.PgQuery__Node) ?[]const u8 {
    if (node == null or node.*.node_case != pg.PG_QUERY__NODE__NODE_STRING) return null;
    return cString(node.*.unnamed_0.string.*.sval);
}

fn resTarget(node: [*c]pg.PgQuery__Node) ?*const pg.PgQuery__ResTarget {
    if (node == null or node.*.node_case != pg.PG_QUERY__NODE__NODE_RES_TARGET) return null;
    return node.*.unnamed_0.res_target;
}

fn cString(value: [*c]u8) ?[]const u8 {
    if (value == null) return null;
    return std.mem.span(value);
}

fn nodeSlice(value: [*c][*c]pg.PgQuery__Node, len: usize) []const [*c]pg.PgQuery__Node {
    if (len == 0) return &.{};
    return value[0..len];
}

fn rawSlice(value: [*c][*c]pg.PgQuery__RawStmt, len: usize) []const [*c]pg.PgQuery__RawStmt {
    if (len == 0) return &.{};
    return value[0..len];
}
