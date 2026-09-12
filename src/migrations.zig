const std = @import("std");

pub const Revision = struct {
    id: []const u8,
    parents: []const []const u8,
};

pub const Error = error{
    InvalidRevisionId,
    DuplicateRevision,
    MissingParent,
    Cycle,
    MultipleHeads,
} || std.mem.Allocator.Error;

pub const Order = struct {
    allocator: std.mem.Allocator,
    indices: []const usize,
    head: usize,

    pub fn deinit(self: *Order) void {
        self.allocator.free(self.indices);
        self.* = undefined;
    }
};

pub fn validateAndOrder(
    allocator: std.mem.Allocator,
    revisions: []const Revision,
) Error!Order {
    if (revisions.len == 0) return error.MultipleHeads;

    var by_id: std.StringHashMapUnmanaged(usize) = .empty;
    defer by_id.deinit(allocator);
    for (revisions, 0..) |revision, index| {
        if (!validId(revision.id)) return error.InvalidRevisionId;
        const entry = try by_id.getOrPut(allocator, revision.id);
        if (entry.found_existing) return error.DuplicateRevision;
        entry.value_ptr.* = index;
    }

    const indegree = try allocator.alloc(usize, revisions.len);
    defer allocator.free(indegree);
    const is_head = try allocator.alloc(bool, revisions.len);
    defer allocator.free(is_head);
    @memset(is_head, true);
    for (revisions, 0..) |revision, index| {
        indegree[index] = revision.parents.len;
        for (revision.parents) |parent| {
            const parent_index = by_id.get(parent) orelse return error.MissingParent;
            is_head[parent_index] = false;
        }
    }

    var head: ?usize = null;
    for (is_head, 0..) |candidate, index| {
        if (!candidate) continue;
        if (head != null) return error.MultipleHeads;
        head = index;
    }

    const processed = try allocator.alloc(bool, revisions.len);
    defer allocator.free(processed);
    @memset(processed, false);
    const ordered = try allocator.alloc(usize, revisions.len);
    errdefer allocator.free(ordered);

    for (ordered) |*slot| {
        var selected: ?usize = null;
        for (revisions, 0..) |revision, index| {
            if (processed[index] or indegree[index] != 0) continue;
            if (selected == null or
                std.mem.order(u8, revision.id, revisions[selected.?].id) == .lt)
                selected = index;
        }
        const index = selected orelse return error.Cycle;
        processed[index] = true;
        slot.* = index;

        for (revisions, 0..) |revision, child_index| {
            if (processed[child_index]) continue;
            for (revision.parents) |parent| {
                if (std.mem.eql(u8, parent, revisions[index].id)) {
                    indegree[child_index] -= 1;
                    break;
                }
            }
        }
    }

    return .{ .allocator = allocator, .indices = ordered, .head = head.? };
}

fn validId(id: []const u8) bool {
    if (id.len != 12) return false;
    for (id) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}
