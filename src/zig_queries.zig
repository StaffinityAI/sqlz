const std = @import("std");
const query_files = @import("sqlz_query_files");
const inputs = @import("sqlz_inputs");

pub const Discovery = query_files.Discovery;

pub const Error = error{
    InvalidZig,
    InvalidQueryDeclaration,
    InvalidSqlExpression,
    MissingBackends,
    MissingCardinality,
    InvalidBackend,
    InvalidCardinality,
    InvalidDeclaredType,
    InvalidCodecMap,
} || std.mem.Allocator.Error || std.zig.string_literal.ParseError;

pub fn parse(
    allocator: std.mem.Allocator,
    path: []const u8,
    contents: [:0]const u8,
) (Error || LimitError)!Discovery {
    return parseWithLimits(allocator, path, contents, .{});
}

pub const LimitError = error{ TokenLimitExceeded, NestingLimitExceeded };

pub const Limits = struct {
    tokens: u64 = 1_000_000,
    nesting: u32 = 256,
};

pub const Violation = struct {
    err: LimitError,
    /// The token that crossed the limit.
    start: usize,
    end: usize,
};

/// Like `parse`, but first bounds the tokens and nesting the Zig parser will
/// see, since it recurses once per nesting level.
pub fn parseWithLimits(
    allocator: std.mem.Allocator,
    path: []const u8,
    contents: [:0]const u8,
    limits: Limits,
) (Error || LimitError)!Discovery {
    if (checkLimits(contents, limits)) |violation| return violation.err;
    var tree = try std.zig.Ast.parse(allocator, contents, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidZig;

    var sources: std.ArrayList(query_files.Source) = .empty;
    errdefer {
        for (sources.items) |*source| source.deinit();
        sources.deinit(allocator);
    }
    try collectContainer(allocator, &tree, .root, path, &sources);
    return .{ .allocator = allocator, .sources = try sources.toOwnedSlice(allocator) };
}

pub fn discover(
    allocator: std.mem.Allocator,
    project_inputs: *inputs.Inputs,
    root: std.Io.Dir,
) anyerror!Discovery {
    const io = project_inputs.io;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (hiddenPath(entry.path)) continue;
        const candidate = std.mem.endsWith(u8, entry.basename, ".zig");
        const kind = try project_inputs.entryKind(entry.dir, entry.basename, entry.kind, candidate);
        if (kind != .file or !candidate) continue;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var sources: std.ArrayList(query_files.Source) = .empty;
    errdefer {
        for (sources.items) |*source| source.deinit();
        sources.deinit(allocator);
    }
    const limits: Limits = .{
        .tokens = project_inputs.limits.tokens_per_source,
        .nesting = project_inputs.limits.nesting_depth,
    };
    for (paths.items) |path| {
        const contents = try project_inputs.readFile(allocator, root, path);
        defer allocator.free(contents);
        const terminated = try allocator.dupeZ(u8, contents);
        defer allocator.free(terminated);
        if (checkLimits(terminated, limits)) |violation| {
            try project_inputs.failInside(root, path, contents, violation.start, violation.end);
            return violation.err;
        }
        var parsed = try parseWithLimits(allocator, path, terminated, limits);
        var moved: usize = 0;
        defer {
            for (parsed.sources[moved..]) |*source| source.deinit();
            allocator.free(parsed.sources);
        }
        try project_inputs.countQueries(root, path, parsed.sources.len);
        // Embedded declarations generate nothing and are named through their
        // own file's containers, so a name may repeat across them; Zig itself
        // rejects a repeat within one container.
        for (parsed.sources) |*source| {
            try sources.append(allocator, source.*);
            moved += 1;
        }
    }
    return .{ .allocator = allocator, .sources = try sources.toOwnedSlice(allocator) };
}

fn collectContainer(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    path: []const u8,
    sources: *std.ArrayList(query_files.Source),
) Error!void {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, node) orelse return;
    for (container.ast.members) |member| {
        if (tree.fullVarDecl(member)) |declaration| {
            if (declaration.ast.init_node.unwrap()) |init| {
                if (try parseQuery(allocator, tree, declaration, init, path)) |source|
                    try sources.append(allocator, source);
                try collectContainer(allocator, tree, init, path, sources);
            }
        } else {
            try collectContainer(allocator, tree, member, path, sources);
        }
    }
}

fn parseQuery(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    declaration: std.zig.Ast.full.VarDecl,
    init: std.zig.Ast.Node.Index,
    path: []const u8,
) Error!?query_files.Source {
    var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, init) orelse return null;
    if (!isSqlzQueryCall(tree, call.ast.fn_expr)) return null;
    if (call.ast.params.len != 1) return error.InvalidQueryDeclaration;
    var struct_buffer: [2]std.zig.Ast.Node.Index = undefined;
    const options = tree.fullStructInit(&struct_buffer, call.ast.params[0]) orelse
        return error.InvalidQueryDeclaration;

    const sql_node = fieldValue(tree, options.ast.fields, "sql") orelse
        return error.InvalidSqlExpression;
    const backend_node = fieldValue(tree, options.ast.fields, "backends") orelse
        return error.MissingBackends;
    const cardinality_node = fieldValue(tree, options.ast.fields, "cardinality") orelse
        return error.MissingCardinality;

    const sql_value = try mappedStringValue(allocator, tree, sql_node);
    errdefer {
        allocator.free(sql_value.text);
        allocator.free(sql_value.offsets);
    }
    const backends = try backendValue(tree, backend_node);
    const cardinality = std.meta.stringToEnum(
        query_files.Cardinality,
        enumLiteral(tree, cardinality_node) orelse return error.InvalidCardinality,
    ) orelse return error.InvalidCardinality;
    const params_node = fieldValue(tree, options.ast.fields, "params");
    const row_node = fieldValue(tree, options.ast.fields, "row");
    // An omitted `.params` is an empty parameter struct, which is a claim the
    // checker can still disprove; an unreadable type expression is not.
    const declared_params = if (params_node) |node|
        try declaredFields(allocator, tree, node)
    else
        try allocator.alloc(query_files.DeclaredField, 0);
    errdefer if (declared_params) |fields| query_files.freeDeclaredFields(allocator, fields);
    const declared_row = if (row_node) |node|
        try declaredFields(allocator, tree, node)
    else
        null;
    errdefer if (declared_row) |fields| query_files.freeDeclaredFields(allocator, fields);

    var param_codecs = try codecMap(allocator, tree, fieldValue(tree, options.ast.fields, "param_codecs"));
    errdefer freeCodecs(allocator, &param_codecs);
    var column_codecs = try codecMap(allocator, tree, fieldValue(tree, options.ast.fields, "column_codecs"));
    errdefer freeCodecs(allocator, &column_codecs);

    const name = tree.tokenSlice(declaration.ast.mut_token + 1);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const source_text = try allocator.dupe(u8, tree.source);
    errdefer allocator.free(source_text);
    return .{
        .allocator = allocator,
        .path = owned_path,
        .name = owned_name,
        .backends = backends,
        .cardinality = cardinality,
        .sql = sql_value.text,
        .sql_source_offsets = sql_value.offsets,
        .source_text = source_text,
        .param_codecs = try param_codecs.toOwnedSlice(allocator),
        .column_codecs = try column_codecs.toOwnedSlice(allocator),
        .declared = .{
            .embedded = true,
            .params = declared_params,
            .params_present = params_node != null,
            .row = declared_row,
            .row_present = row_node != null,
        },
    };
}

/// Reads a `.params`/`.row` struct type expression into its fields. Returns
/// `null` when the expression is a type the checker cannot read here, such as
/// an import or a qualified path.
fn declaredFields(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) Error!?[]query_files.DeclaredField {
    const container_node = resolveContainer(tree, node) orelse return null;
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, container_node) orelse return null;

    var fields: std.ArrayList(query_files.DeclaredField) = .empty;
    errdefer {
        query_files.freeDeclaredFields(allocator, fields.items);
        fields.deinit(allocator);
    }
    for (container.ast.members) |member| {
        const field = tree.fullContainerField(member) orelse continue;
        // A tuple field has no name to match a column against.
        if (field.ast.tuple_like) return error.InvalidDeclaredType;
        const type_expr = field.ast.type_expr.unwrap() orelse return error.InvalidDeclaredType;
        const raw = std.mem.trim(u8, tree.getNodeSource(type_expr), &std.ascii.whitespace);
        const optional = raw.len != 0 and raw[0] == '?';
        const type_text = try normalizeType(allocator, if (optional) raw[1..] else raw);
        errdefer allocator.free(type_text);
        const name = try allocator.dupe(u8, tree.tokenSlice(field.ast.main_token));
        errdefer allocator.free(name);
        try fields.append(allocator, .{ .name = name, .type_text = type_text, .optional = optional });
    }
    const owned = try fields.toOwnedSlice(allocator);
    return owned;
}

/// Follows a bare identifier to a container declared in the same file, so a
/// named row struct is verified like an inline one.
fn resolveContainer(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ?std.zig.Ast.Node.Index {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&buffer, node) != null) return node;
    if (tree.nodeTag(node) != .identifier) return null;
    const wanted = tree.tokenSlice(tree.nodeMainToken(node));
    var index: u32 = 0;
    while (index < tree.nodes.len) : (index += 1) {
        const candidate: std.zig.Ast.Node.Index = @enumFromInt(index);
        const declaration = tree.fullVarDecl(candidate) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(declaration.ast.mut_token + 1), wanted)) continue;
        const init = declaration.ast.init_node.unwrap() orelse continue;
        var init_buffer: [2]std.zig.Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&init_buffer, init) != null) return init;
    }
    return null;
}

fn normalizeType(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var pending_space = false;
    for (text) |character| {
        if (std.ascii.isWhitespace(character)) {
            pending_space = output.items.len != 0;
            continue;
        }
        if (pending_space) {
            try output.append(allocator, ' ');
            pending_space = false;
        }
        try output.append(allocator, character);
    }
    return output.toOwnedSlice(allocator);
}

/// Reads `.param_codecs`/`.column_codecs` — a struct literal mapping field
/// names to registered codec IDs.
fn codecMap(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node: ?std.zig.Ast.Node.Index,
) Error!std.ArrayList(query_files.CodecOverride) {
    var overrides: std.ArrayList(query_files.CodecOverride) = .empty;
    errdefer freeCodecs(allocator, &overrides);
    const map = node orelse return overrides;
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const literal = tree.fullStructInit(&buffer, map) orelse return error.InvalidCodecMap;
    for (literal.ast.fields) |value| {
        const first = tree.firstToken(value);
        if (first < 2) return error.InvalidCodecMap;
        const field_name = tree.tokenSlice(first - 2);
        const codec = stringValue(allocator, tree, value) catch return error.InvalidCodecMap;
        errdefer allocator.free(codec);
        const owned_name = try allocator.dupe(u8, field_name);
        errdefer allocator.free(owned_name);
        try overrides.append(allocator, .{ .name = owned_name, .codec = codec });
    }
    return overrides;
}

fn freeCodecs(
    allocator: std.mem.Allocator,
    overrides: *std.ArrayList(query_files.CodecOverride),
) void {
    for (overrides.items) |override| {
        allocator.free(override.name);
        allocator.free(override.codec);
    }
    overrides.deinit(allocator);
}

fn isSqlzQueryCall(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .field_access) return false;
    const data = tree.nodeData(node).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(data[1]), "Query")) return false;
    return tree.nodeTag(data[0]) == .identifier and
        std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(data[0])), "sqlz");
}

fn fieldValue(
    tree: *const std.zig.Ast,
    fields: []const std.zig.Ast.Node.Index,
    wanted: []const u8,
) ?std.zig.Ast.Node.Index {
    for (fields) |value| {
        const first = tree.firstToken(value);
        if (first >= 2 and std.mem.eql(u8, tree.tokenSlice(first - 2), wanted)) return value;
    }
    return null;
}

fn stringValue(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) Error![]u8 {
    return switch (tree.nodeTag(node)) {
        .string_literal => std.zig.string_literal.parseAlloc(
            allocator,
            tree.tokenSlice(tree.nodeMainToken(node)),
        ),
        .multiline_string_literal => result: {
            const tokens = tree.nodeData(node).token_and_token;
            var output: std.ArrayList(u8) = .empty;
            errdefer output.deinit(allocator);
            var token = tokens[0];
            while (token <= tokens[1]) : (token += 1) {
                const line = tree.tokenSlice(token);
                if (line.len < 2) return error.InvalidSqlExpression;
                if (token != tokens[0]) try output.append(allocator, '\n');
                try output.appendSlice(allocator, line[2..]);
            }
            break :result try output.toOwnedSlice(allocator);
        },
        else => error.InvalidSqlExpression,
    };
}

const MappedString = struct { text: []u8, offsets: []usize };

fn mappedStringValue(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) Error!MappedString {
    const token = tree.nodeMainToken(node);
    const token_start = tree.tokens.items(.start)[token];
    return switch (tree.nodeTag(node)) {
        .string_literal => result: {
            const raw = tree.tokenSlice(token);
            const text = try std.zig.string_literal.parseAlloc(allocator, raw);
            errdefer allocator.free(text);
            const offsets = try allocator.alloc(usize, text.len + 1);
            var raw_index: usize = 1;
            var output_index: usize = 0;
            while (output_index < text.len and raw_index + 1 < raw.len) {
                offsets[output_index] = token_start + raw_index;
                if (raw[raw_index] == '\\') {
                    raw_index += 1;
                    if (raw_index < raw.len and raw[raw_index] == 'x') raw_index += 2;
                }
                raw_index += 1;
                output_index += 1;
            }
            while (output_index < text.len) : (output_index += 1) offsets[output_index] = token_start + 1;
            offsets[text.len] = token_start + raw.len - 1;
            break :result .{ .text = text, .offsets = offsets };
        },
        .multiline_string_literal => result: {
            const tokens = tree.nodeData(node).token_and_token;
            var output: std.ArrayList(u8) = .empty;
            errdefer output.deinit(allocator);
            var offsets: std.ArrayList(usize) = .empty;
            errdefer offsets.deinit(allocator);
            var current = tokens[0];
            while (current <= tokens[1]) : (current += 1) {
                const line = tree.tokenSlice(current);
                if (line.len < 2) return error.InvalidSqlExpression;
                if (current != tokens[0]) {
                    try output.append(allocator, '\n');
                    try offsets.append(allocator, tree.tokens.items(.start)[current] - 1);
                }
                const start = tree.tokens.items(.start)[current];
                try output.appendSlice(allocator, line[2..]);
                for (2..line.len) |index| try offsets.append(allocator, start + index);
            }
            try offsets.append(allocator, tree.tokens.items(.start)[tokens[1]] + tree.tokenSlice(tokens[1]).len);
            break :result .{
                .text = try output.toOwnedSlice(allocator),
                .offsets = try offsets.toOwnedSlice(allocator),
            };
        },
        else => error.InvalidSqlExpression,
    };
}

fn backendValue(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) Error!query_files.Backends {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const options = tree.fullStructInit(&buffer, node) orelse return error.InvalidBackend;
    var result: query_files.Backends = .{};
    for (options.ast.fields) |value| {
        if (tree.nodeTag(value) != .identifier or
            !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "true"))
            return error.InvalidBackend;
        const first = tree.firstToken(value);
        const name = if (first >= 2) tree.tokenSlice(first - 2) else return error.InvalidBackend;
        if (std.mem.eql(u8, name, "sqlite")) result.sqlite = true else if (std.mem.eql(u8, name, "postgres")) result.postgres = true else return error.InvalidBackend;
    }
    if (!result.sqlite and !result.postgres) return error.InvalidBackend;
    return result;
}

fn enumLiteral(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ?[]const u8 {
    if (tree.nodeTag(node) != .enum_literal) return null;
    return tree.tokenSlice(tree.nodeMainToken(node));
}

fn hiddenPath(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (components.next()) |component| {
        if (component.len > 0 and component[0] == '.') return true;
        if (std.mem.eql(u8, component, "zig-cache") or
            std.mem.eql(u8, component, "zig-out") or
            std.mem.eql(u8, component, "zig-pkg")) return true;
    }
    return false;
}

/// The largest `nesting` limit sqlz accepts, matching the SQL lexer.
pub const max_nesting_depth: u32 = 1024;

/// Returns the first token that crosses the token or nesting limit.
///
/// Nesting estimates how deeply the Zig parser will recurse. Each open bracket
/// is a level. Within a level, every token that can start a nested operand or
/// type adds one until the next `,`, `;`, `=`, or `=>`: prefix operators (`!`,
/// `-`, `~`, `&`, `*`, `?`, `try`, `comptime`), an error union's `!`, a `fn`
/// type, each closed `[...]` as in `[4]*const ?T`, control flow that takes an
/// operand (`return`, `break`, `defer`, ...), `anyframe->`, and an `if`,
/// loop, or `switch` that is directly the body of another. Binary operators
/// that share those tokens are counted too, which only overestimates. Each
/// `else if` nests the rest of its chain.
pub fn checkLimits(contents: [:0]const u8, limits: Limits) ?Violation {
    std.debug.assert(limits.tokens > 0 and limits.nesting > 0);
    std.debug.assert(limits.nesting <= max_nesting_depth);
    const Level = struct { operands: u32, chain: u32 };
    var tokenizer: std.zig.Tokenizer = .init(contents);
    var tokens: u64 = 0;
    // The enclosing levels' counts. A level past the limit fails the check
    // before it is stored, so the stack never overflows.
    var levels: [max_nesting_depth + 1]Level = undefined;
    var depth: u32 = 0;
    var outer: u64 = 0;
    var current: Level = .{ .operands = 0, .chain = 0 };
    var previous: std.zig.Token.Tag = .invalid;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return null;
        tokens += 1;
        if (tokens > limits.tokens)
            return .{ .err = error.TokenLimitExceeded, .start = token.loc.start, .end = token.loc.end };
        switch (token.tag) {
            .bang, .minus, .minus_percent, .tilde, .ampersand, .asterisk, .asterisk_asterisk, .question_mark, .keyword_try, .keyword_comptime, .keyword_nosuspend => current.operands += 1,
            .comma, .equal, .equal_angle_bracket_right => current.operands = 0,
            .semicolon => current = .{ .operands = 0, .chain = 0 },
            .keyword_if => if (previous == .keyword_else) {
                current.chain += 1;
            } else {
                current.chain = 0;
                if (startsNestedBody(previous)) current.operands += 1;
            },
            // A loop or switch directly in another's body, as in
            // `if (a) while (b) ...` or `x: for (c) ...`, nests inside it.
            .keyword_while, .keyword_for, .keyword_switch, .keyword_inline => if (startsNestedBody(previous)) {
                current.operands += 1;
            },
            // Control flow and `anyframe->` take a nested operand.
            .keyword_return, .keyword_break, .keyword_continue, .keyword_resume, .keyword_suspend, .keyword_defer, .keyword_errdefer, .arrow => current.operands += 1,
            .l_paren, .l_bracket, .l_brace => {
                // `fn (` is a function type, whose return type nests.
                if (token.tag == .l_paren and previous == .keyword_fn) current.operands += 1;
                if (depth + 1 + outer + current.operands + current.chain > limits.nesting)
                    return .{ .err = error.NestingLimitExceeded, .start = token.loc.start, .end = token.loc.end };
                levels[depth] = current;
                outer += current.operands + current.chain;
                depth += 1;
                current = .{ .operands = 0, .chain = 0 };
            },
            .r_paren, .r_bracket, .r_brace => if (depth > 0) {
                depth -= 1;
                current = levels[depth];
                outer -= current.operands + current.chain;
                if (token.tag == .r_bracket) current.operands += 1;
            },
            else => {},
        }
        previous = token.tag;
        if (depth + outer + current.operands + current.chain > limits.nesting)
            return .{ .err = error.NestingLimitExceeded, .start = token.loc.start, .end = token.loc.end };
    }
}

/// Whether a token after `previous` is the body of an enclosing `if`, loop, or
/// label rather than a statement of its own.
fn startsNestedBody(previous: std.zig.Token.Tag) bool {
    return switch (previous) {
        .r_paren, .colon, .keyword_else, .pipe => true,
        else => false,
    };
}
