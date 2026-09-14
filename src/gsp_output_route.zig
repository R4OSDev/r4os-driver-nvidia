//! Additional external SST outputs. Capability masks and the current coherent
//! RM/EDID capture supply every route and timing; this code performs no I/O.
//! Window/head compatibility is NV0073 GET_VALID_HEAD_WINDOW_ASSIGNMENT.
const std = @import("std");
const boot = @import("gsp_boot_mode.zig");
const scanout = @import("boot_scanout.zig");
const outputs = @import("gsp_outputs.zig");
const wire = @import("gsp_display_engine_wire.zig");
const display = @import("gsp_display_rpc.zig");

pub const Source = struct { epoch: u64, held_generation: u64, boot_generation: u64 };
pub const Claim = struct {
    display_id: u32, connector: display.Connector, sor: u32, protocol: u32, head: u32, window: u32,
};
pub const Selection = struct { claim: Claim, plan: boot.Plan };
pub const Assignment = struct { request: @import("gsp_sor_assignment.zig").Request, connector: display.Connector, fingerprint: [32]u8 };

/// Preflight a new SST assignment without pretending its current SOR index
/// is allocated. Firmware may report ffffffff until ASSIGN_SOR succeeds.
pub fn assignment(object: display.Object, snapshot: *const outputs.Snapshot, occupied: []const ?Claim,
    id: u32) !Assignment
{
    if (occupied.len > 8 or object.epoch != snapshot.topology.epoch or object.client != snapshot.topology.client) return error.Stale;
    const current = try route(snapshot, id);
    const resource = current.resource orelse return error.Routing;
    const physical = current.connectors orelse return error.Routing;
    if (resource.kind != 2 or resource.dynamic or resource.location != 0 or !physical.present() or physical.count != 1 or
        snapshot.topology.activeHeads(id) != 0) return error.Unsupported;
    const dp = resource.protocol == 8 or resource.protocol == 9;
    if (!dp and resource.protocol != 1 and resource.protocol != 2) return error.Unsupported;
    const kind = physical.data[0].kind;
    if (dp) {
        if (kind != 0x46 and kind != 0x48) return error.Unsupported;
    } else switch (kind) { 0x61, 0x63, 0x46, 0x48, 0x30, 0x31 => {}, else => return error.Unsupported }
    const receiver = try @import("gsp_hotplug.zig").observe(snapshot, id);
    if (receiver.state != .connected or receiver.fingerprint == null) return error.Stale;
    var result: @import("gsp_sor_assignment.zig").Request = .{ .object = object, .display_id = id };
    for (occupied) |slot| if (slot) |used| {
        if (used.display_id == id or used.connector.index == physical.data[0].index) return error.Busy;
        if (used.sor >= result.protected.len or result.protected[used.sor] != 0) return error.Routing;
        result.protected[used.sor] = used.display_id;
    };
    // An unowned firmware head is not ours to disturb, even when RM would
    // otherwise accept a new assignment next to it.
    const count = snapshot.topology.head_count orelse return error.Routing;
    if (count > 8) return error.Unsupported;
    for (snapshot.topology.heads[0..count], 0..) |head, index| {
        const active = head.display_id orelse return error.Routing;
        if (active == 0) continue;
        var owned = false;
        for (occupied) |slot| if (slot) |used| { owned = owned or (used.head == index and used.display_id == active); };
        if (!owned) return error.Routing;
    }
    return .{ .request = result, .connector = physical.data[0], .fingerprint = receiver.fingerprint.? };
}

fn route(snapshot: *const outputs.Snapshot, id: u32) !*const @import("gsp_topology.zig").Route {
    if (!snapshot.coherent or snapshot.generation == 0 or snapshot.final_receipt_serial == 0 or
        snapshot.final_rejection != null or snapshot.topology.rejected != null or
        snapshot.count != snapshot.topology.count or snapshot.count > snapshot.topology.routes.len or
        id == 0 or id & (id - 1) != 0) return error.Stale;
    var found: ?*const @import("gsp_topology.zig").Route = null;
    for (snapshot.topology.routes[0..snapshot.count]) |*value| if (value.id == id) {
        if (found != null) return error.Routing;
        found = value;
    };
    return found orelse error.Routing;
}
pub fn identify(plan: boot.Plan, snapshot: *const outputs.Snapshot) !Claim {
    const current = try route(snapshot, plan.signal.display_id);
    const resource = current.resource orelse return error.Routing;
    const physical = current.connectors orelse return error.Routing;
    if (!physical.present() or physical.count != 1 or resource.kind != 2 or resource.dynamic or resource.location != 0 or
        resource.index != plan.signal.sor or resource.protocol != (plan.signal.sor_control >> 8) & 15) return error.Routing;
    return .{ .display_id = current.id, .connector = physical.data[0], .sor = resource.index,
        .protocol = resource.protocol, .head = plan.head, .window = plan.window };
}
fn compatible(raw: *const scanout.Raw, hardware: wire.StaticInfo, snapshot: *const outputs.Snapshot, claim: Claim) !void {
    const head_count = snapshot.topology.head_count orelse return error.Routing;
    const windows = snapshot.topology.window_heads orelse return error.Unsupported;
    if (head_count == 0 or head_count > 8 or hardware.heads == 0 or hardware.heads > 8 or
        raw.headCount() == 0 or raw.headCount() > 8 or raw.sorCount() > 8 or raw.windowCount() > 8 or
        claim.head >= head_count or claim.head >= hardware.heads or claim.head >= raw.headCount() or
        claim.sor >= raw.sorCount() or claim.window >= raw.windowCount() or claim.window >= 8) return error.Bounds;
    const head_mask = @as(u32, 1) << @intCast(claim.head);
    if (raw.headMask() & head_mask == 0 or raw.sorMask() & (@as(u32, 1) << @intCast(claim.sor)) == 0 or
        windows[claim.window] & head_mask == 0 or
        hardware.windows & raw.window_mask & (@as(u32, 1) << @intCast(claim.window)) == 0) return error.Unsupported;
    // Knowing only some current assignments cannot prove an unused head.
    for (snapshot.topology.heads[0..head_count], 0..) |head, i| {
        const id = head.display_id orelse return error.Routing;
        if (i == claim.head and id != 0 and id != claim.display_id) return error.Routing;
    }
}

/// Re-run at each actual RPC/commit gate. A claim keeps the physical socket,
/// SOR and channel fixed across captures; it never retains a receiver timing.
pub fn derive(source: Source, raw: *const scanout.Raw, hardware: wire.StaticInfo,
    snapshot: *const outputs.Snapshot, claim: Claim, mode_id: u32) !boot.Plan
{
    if (source.epoch == 0 or source.held_generation == 0 or source.boot_generation == 0 or mode_id == 0) return error.Descriptor;
    try compatible(raw, hardware, snapshot, claim);
    if (claim.protocol != 1 and claim.protocol != 2 and claim.protocol != 8 and claim.protocol != 9) return error.Unsupported;
    // C67D SOR owner bits7:0 and protocol11:8, positive DE, no repetition.
    // All raster values below must be replaced by the exact receiver mode
    // before this private seed can leave the function.
    const seed: boot.Plan = .{ .boot_generation = source.boot_generation, .head = claim.head, .window = claim.window,
        .width = 0, .height = 0, .refresh_micro_hz = 0,
        .signal = .{ .sor = claim.sor, .sor_control = (@as(u32, 1) << @intCast(claim.head)) | (claim.protocol << 8),
            .clock = 0, .total = 0, .sync_end = 0, .blank_end = 0, .blank_start = 0,
            .viewport = 0, .polarity = 0, .hdmi = 0, .min_frame_idle = 0 } };
    const bound = try boot.bind(seed, snapshot, source.epoch, source.held_generation);
    if (!std.meta.eql(claim, try identify(bound, snapshot))) return error.Stale;
    return @import("gsp_receiver_mode.zig").select(bound, snapshot, mode_id);
}

/// Select one free compatible channel/head. Existing firmware assignments,
/// the adopted primary and pending claims all count as occupied resources.
pub fn choose(source: Source, raw: *const scanout.Raw, hardware: wire.StaticInfo,
    snapshot: *const outputs.Snapshot, occupied: []const ?Claim, id: u32, mode_id: u32) !Selection
{
    if (occupied.len > 8) return error.Bounds;
    const current = try route(snapshot, id);
    const resource = current.resource orelse return error.Routing;
    const physical = current.connectors orelse return error.Routing;
    if (!physical.present() or physical.count != 1 or resource.index >= 8 or resource.kind != 2 or
        resource.dynamic or resource.location != 0) return error.Unsupported;
    if (snapshot.topology.activeHeads(id) != 0) return error.Routing;
    for (occupied) |slot| if (slot) |used| {
        if (used.display_id == id or used.sor == resource.index or used.connector.index == physical.data[0].index) return error.Busy;
    };
    for (0..8) |window| {
        for (0..8) |head| {
            var busy = false;
            for (occupied) |slot| if (slot) |used| { busy = busy or used.window == window or used.head == head; };
            if (busy) continue;
            const claim: Claim = .{ .display_id = id, .connector = physical.data[0], .sor = resource.index,
                .protocol = resource.protocol, .head = @intCast(head), .window = @intCast(window) };
            compatible(raw, hardware, snapshot, claim) catch continue;
            return .{ .claim = claim, .plan = try derive(source, raw, hardware, snapshot, claim, mode_id) };
        }
    }
    return error.Unsupported;
}
