//! A stable virtual RM ID names a sink; physical connector and SOR identity
//! come from its separately verified root. Every modeset rederives this
//! view from the current coherent capture instead of guessing a route.
const std = @import("std");
const outputs = @import("gsp_outputs.zig");
const display = @import("gsp_display_rpc.zig");
const topology = @import("gsp_mst_topology.zig");
const registry = @import("gsp_mst_registry.zig");
pub const Error = error{ Descriptor, Bounds, Stale, Unsupported, Routing };
pub const Stamp = struct {
    handle: registry.Handle,
    root: u32,
    display_id: u32,
};
pub const View = struct {
    stamp: Stamp,
    root: *const outputs.mst.Root,
    slot: *const registry.Slot,
    sink: *const topology.Sink,
    connector: display.Connector,
};
pub fn derive(snapshot: *const outputs.Snapshot, id: u32) Error!View {
    if (!snapshot.coherent or snapshot.generation == 0 or snapshot.final_receipt_serial == 0 or
        snapshot.final_rejection != null or snapshot.topology.rejected != null or
        snapshot.count != snapshot.topology.count or snapshot.count > snapshot.receivers.len or
        id == 0 or id & (id - 1) != 0) return error.Stale;
    const store = snapshot.mst orelse return error.Unsupported;
    if (store.registry.epoch != snapshot.topology.epoch or store.registry.epoch == 0 or snapshot.topology.client == 0 or
        id & store.registry.physical_mask != 0) return error.Stale;
    var selected: ?struct { entry: *const registry.Slot, index: usize } = null;
    for (&store.registry.slots, 0..) |*entry, index| if (entry.display_id == id) {
        if (selected != null or entry.state != .verified or entry.pending != .none or entry.generation != snapshot.generation or
            entry.source_receipt == 0 or entry.resource_receipt <= entry.source_receipt or
            snapshot.final_receipt_serial <= entry.resource_receipt) return error.Stale;
        selected = .{ .entry = entry, .index = index };
    };
    const entry = (selected orelse return error.Routing).entry;
    var branch_root: ?*const outputs.mst.Root = null;
    for (&store.roots) |*root| if (root.id == entry.key.root) {
        if (branch_root != null or root.failure != null or root.payload_dirty or !root.graph.coherent or root.graph.epoch != store.registry.epoch or
            root.graph.generation != snapshot.generation or root.graph.completion_receipt != entry.source_receipt or
            root.enabled_receipt == 0 or root.source == null or !root.source.?.mst or root.resource == null or
            entry.sink >= root.graph.sink_count) return error.Stale;
        branch_root = root;
    };
    const root = branch_root orelse return error.Routing;
    var connector: ?display.Connector = null;
    var leaf_found = false;
    for (snapshot.topology.routes[0..snapshot.count], snapshot.receivers[0..snapshot.count]) |*route, *capture| {
        if (route.id != id and route.id != entry.key.root) continue;
        const resource = route.resource orelse return error.Routing;
        if (capture.display_id != route.id or capture.epoch != snapshot.topology.epoch or capture.client != snapshot.topology.client or
            capture.connected != true) return error.Stale;
        if (route.id == id) {
            if (leaf_found or capture.source != .mst or !resource.dynamic or resource.root_port_id != entry.key.root or
                resource.index != entry.sor or resource.protocol != 8 + entry.link or resource.kind != 2 or resource.location != 0 or
                capture.receipt_serial != entry.resource_receipt) return error.Stale;
            leaf_found = true;
        } else {
            if (connector != null or !std.meta.eql(resource, root.resource.?) or !display.nativeDp(resource)) return error.Routing;
            const physical = route.connectors orelse return error.Routing;
            if (!physical.present() or physical.count != 1 or
                (physical.data[0].kind != 0x46 and physical.data[0].kind != 0x48)) return error.Unsupported;
            if (capture.dp.source_state != .complete or capture.dp.source == null or !std.meta.eql(capture.dp.source.?, root.source.?) or
                capture.dp.dpcd_state != .complete or !std.mem.eql(u8, &capture.dp.dpcd, &root.dpcd) or
                capture.dp.receiver.mst_state != .complete or !capture.dp.receiver.mst) return error.Stale;
            connector = physical.data[0];
        }
    }
    if (!leaf_found or connector == null) return error.Routing;
    const sink = &root.graph.sinks[entry.sink];
    if (sink.edge >= root.graph.edge_count or sink.path_count == 0 or sink.path_count > sink.path.len) return error.Descriptor;
    const edge = &root.graph.edges[sink.edge];
    if (edge.branch >= root.graph.branch_count or edge.port.number != entry.key.port or
        (!edge.port.connected and !edge.port.legacy_connected)) return error.Stale;
    const branch = &root.graph.branches[edge.branch];
    const descriptor = branch.descriptor orelse return error.Stale;
    if (!std.meta.eql(branch.route, entry.key.route) or !std.mem.eql(u8, &descriptor.guid, &entry.key.branch_guid)) return error.Stale;
    return .{ .stamp = .{ .handle = .{ .epoch = store.registry.epoch, .serial = entry.serial, .slot = @intCast(selected.?.index) },
        .root = root.id, .display_id = id }, .root = root, .slot = entry, .sink = sink, .connector = connector.? };
}
