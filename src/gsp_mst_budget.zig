//! Persistent whole-root payload state. Edge identity is GUID/RAD/port,
//! never an index into a later topology capture. Planning performs no I/O;
//! only the live transaction may install a table after source/receiver ACT.
const std = @import("std");
const topology = @import("gsp_mst_topology.zig");
const ids = @import("gsp_mst_registry.zig");
pub const payload = @import("gsp_mst_payload.zig");
pub const Edge = struct {
    guid: [16]u8 = @splat(0), route: @import("gsp_mst_wire.zig").Route = .{}, port: u4 = 0,
    pub fn capture(graph: *const topology.Graph, index: usize) !Edge {
        if (index >= graph.edge_count or graph.edge_count > graph.edges.len) return error.Bounds;
        const edge = &graph.edges[index];
        if (edge.branch >= graph.branch_count or graph.branch_count > graph.branches.len or edge.port.input) return error.Descriptor;
        const branch = &graph.branches[edge.branch];
        const descriptor = branch.descriptor orelse return error.Stale;
        if (!branch.route.valid() or std.mem.allEqual(u8, &descriptor.guid, 0)) return error.Stale;
        return .{ .guid = descriptor.guid, .route = branch.route, .port = edge.port.number };
    }
};
pub const Entry = struct {
    handle: ids.Handle = .{ .epoch = 0, .serial = 0, .slot = 0 },
    key: ids.Key = .{},
    window: u8 = 0,
    path_count: u8 = 0,
    path: [15]Edge = @splat(.{}),
    timing: payload.Timing = .{ .clock = .{ .numerator = 0 }, .width = 0, .total = 0, .bpc = 0 },
    allocation: payload.Allocation = .{},
};
pub const Table = struct {
    count: u8 = 0, slots: u8 = 0, used_pbn: u16 = 0,
    entries: [8]Entry = @splat(.{}),
    pub fn find(self: *const Table, id: u32) ?*const Entry {
        if (self.count > self.entries.len) return null;
        for (self.entries[0..self.count]) |*entry| if (entry.allocation.display_id == id) return entry;
        return null;
    }
    /// Transaction tokens retain this digest, not a copy of every stream
    /// and path. Hash fields explicitly through autoHash; no struct padding.
    pub fn digest(self: *const Table) ![32]u8 {
        if (self.count > self.entries.len) return error.Bounds;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        std.hash.autoHash(&hash, self.count);
        std.hash.autoHash(&hash, self.slots);
        std.hash.autoHash(&hash, self.used_pbn);
        for (self.entries[0..self.count]) |*entry| std.hash.autoHash(&hash, entry.*);
        var result: [32]u8 = undefined;
        hash.final(&result);
        return result;
    }
};
pub const Training = struct {
    link: payload.Link,
    source: @import("gsp_link_caps.zig").DpSource,
    dpcd: [16]u8,
    lanes: [8]u8,
    receipt: u64,
};
pub const State = struct {
    epoch: u64 = 0, root: u32 = 0, revision: u64 = 0,
    table: Table = .{}, training: ?Training = null, completion_receipt: u64 = 0,
};
pub const Budget = struct { link: payload.Link, table: Table };

pub fn validateTable(table: *const Table, epoch: u64, root: u32, link: payload.Link) !void {
    if (table.count > 8) return error.Descriptor;
    var slots: u16 = 0; var pbn: u32 = 0; var ids_seen: u32 = 0; var heads: u8 = 0; var windows: u8 = 0;
    for (table.entries[0..table.count]) |*entry| {
        const item = entry.allocation;
        if (item.display_id == 0 or item.display_id & (item.display_id - 1) != 0 or item.head >= 8 or entry.window >= 8 or
            item.payload_id != item.head + 1 or entry.handle.epoch != epoch or entry.handle.serial == 0 or entry.handle.slot >= 32 or
            entry.key.root != root or entry.path_count == 0 or entry.path_count > entry.path.len or
            ids_seen & item.display_id != 0 or heads & (@as(u8, 1) << @intCast(item.head)) != 0 or
            windows & (@as(u8, 1) << @intCast(entry.window)) != 0) return error.Descriptor;
        if (!std.meta.eql(item.demand, try payload.demand(link, entry.timing)) or item.start != slots + 1) return error.Stale;
        const terminal = entry.path[entry.path_count - 1];
        if (!std.mem.eql(u8, &terminal.guid, &entry.key.branch_guid) or !std.meta.eql(terminal.route, entry.key.route) or
            terminal.port != entry.key.port or std.mem.allEqual(u8, &entry.key.root_guid, 0)) return error.Stale;
        for (entry.path[0..entry.path_count], 0..) |edge, index| {
            if (!edge.route.valid() or std.mem.allEqual(u8, &edge.guid, 0)) return error.Stale;
            for (entry.path[0..index]) |previous| if (std.meta.eql(previous, edge)) return error.Descriptor;
        }
        ids_seen |= item.display_id;
        heads |= @as(u8, 1) << @intCast(item.head); windows |= @as(u8, 1) << @intCast(entry.window);
        slots += item.demand.slots; pbn += item.demand.pbn;
    }
    if (slots > 63 or table.slots != slots or table.used_pbn != pbn) return error.Descriptor;
}

/// captured is the owned table at ENUM_PATH_RESOURCES capture time. It
/// supplies exactly that capture's reusable PBN, not all allocations made
/// since then. This prevents counting newly allocated bandwidth twice.
pub fn plan(graph: *const topology.Graph, state: *const State, captured: *const Table,
    link: payload.Link, replacement: Entry) !Budget
{
    if (!graph.coherent or graph.epoch == 0 or graph.root == 0 or graph.generation == 0 or graph.completion_receipt == 0 or
        graph.edge_count > topology.max_edges or graph.branch_count > topology.max_branches or
        (state.epoch != 0 and (state.epoch != graph.epoch or state.root != graph.root)) or state.revision == std.math.maxInt(u64)) return error.Stale;
    if (state.table.count != 0 and (state.training == null or state.completion_receipt == 0 or state.revision == 0 or
        !std.meta.eql(state.training.?.link, link))) return error.Stale;
    try validateTable(&state.table, graph.epoch, graph.root, link);
    try validateTable(captured, graph.epoch, graph.root, link);
    var quotas: [topology.max_edges]payload.Path = @splat(.{ .total_pbn = 0, .free_pbn = 0 });
    var keys: [topology.max_edges]Edge = @splat(.{});
    for (graph.edges[0..graph.edge_count], 0..) |*edge, index| {
        const resources = edge.resources orelse return error.Stale;
        keys[index] = try Edge.capture(graph, index);
        for (keys[0..index]) |previous| if (std.meta.eql(previous, keys[index])) return error.Descriptor;
        var owned: u32 = 0;
        for (captured.entries[0..captured.count]) |*entry| for (entry.path[0..entry.path_count]) |path| {
            if (std.meta.eql(path, keys[index])) owned += entry.allocation.demand.pbn;
        };
        if (owned > resources.total_pbn or @as(u32, resources.free_pbn) + owned > resources.total_pbn) return error.Stale;
        // EPR's optional DFPLinkAvailablePBN limits the downstream physical
        // link (dp_deviceimpl.cpp). It is distinct from the branch's FreePBN.
        const limit = @min(resources.total_pbn, resources.downstream_pbn orelse resources.total_pbn);
        if (owned > limit) return error.Bandwidth;
        const available = @min(limit, @as(u32, resources.free_pbn) + owned);
        quotas[index] = .{ .total_pbn = limit, .free_pbn = @intCast(available - owned), .owned_pbn = @intCast(owned) };
    }
    var result: Budget = .{ .link = link, .table = .{} };
    var wanted: [8]payload.Wanted = undefined;
    const previous = state.table.find(replacement.allocation.display_id);
    if (previous) |old| if (old.allocation.head != replacement.allocation.head or old.window != replacement.window or
        !std.meta.eql(old.key, replacement.key) or !std.meta.eql(old.handle, replacement.handle)) return error.Stale;
    if (replacement.allocation.head >= 8 or replacement.path_count == 0 or replacement.path_count > replacement.path.len) return error.Descriptor;
    // A removed stream compacts later slots; a new/re-sized stream appends
    // at the end, as the receiver's payload allocator does. Payload IDs
    // remain head+1 independently of allocation order.
    for (0..@as(usize, state.table.count) + 1) |index| {
        const entry = if (index == state.table.count) replacement else state.table.entries[index];
        if (index != state.table.count and entry.allocation.display_id == replacement.allocation.display_id) continue;
        const head = entry.allocation.head;
        if (entry.handle.epoch != graph.epoch or entry.handle.serial == 0 or entry.key.root != graph.root or
            entry.window >= 8 or entry.path_count == 0 or entry.path_count > entry.path.len) return error.Stale;
        var request: payload.Wanted = .{ .display_id = entry.allocation.display_id, .payload_id = @intCast(head + 1),
            .head = @intCast(head), .timing = entry.timing, .path_count = entry.path_count };
        for (entry.path[0..entry.path_count], 0..) |path, path_index| {
            var found: ?u8 = null;
            for (keys[0..graph.edge_count], 0..) |key, edge_index| if (std.meta.eql(key, path)) { found = @intCast(edge_index); };
            request.path[path_index] = found orelse return error.Stale;
        }
        if (result.table.count == result.table.entries.len) return error.Capacity;
        result.table.entries[result.table.count] = entry;
        wanted[result.table.count] = request;
        result.table.count += 1;
    }
    const allocation = try payload.plan(link, quotas[0..graph.edge_count], wanted[0..result.table.count]);
    result.table.slots = allocation.slots; result.table.used_pbn = allocation.used_pbn;
    for (result.table.entries[0..result.table.count], allocation.allocations[0..allocation.count]) |*entry, item| entry.allocation = item;
    try validateTable(&result.table, graph.epoch, graph.root, link);
    return result;
}

/// Receiver deletion compacts the remaining streams without changing their
/// bandwidth or IDs. The live owner must still program source slots and ACT.
pub fn remove(table: *const Table, epoch: u64, root: u32, link: payload.Link, id: u32) !Table {
    try validateTable(table, epoch, root, link);
    _ = table.find(id) orelse return error.Stale;
    var result: Table = .{};
    for (table.entries[0..table.count]) |entry| {
        if (entry.allocation.display_id == id) continue;
        var next = entry;
        next.allocation.start = result.slots + 1;
        result.entries[result.count] = next;
        result.count += 1; result.slots += next.allocation.demand.slots; result.used_pbn += next.allocation.demand.pbn;
    }
    try validateTable(&result, epoch, root, link);
    return result;
}
