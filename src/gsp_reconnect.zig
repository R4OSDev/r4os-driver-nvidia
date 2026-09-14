//! Select a fresh receiver mode. A previous mode ID is never reused across
//! captures; raster equality and current EDID/transport admission decide.
const std = @import("std");
const a = @import("r4os").abi;
const boot = @import("gsp_boot_mode.zig");
const outputs = @import("gsp_outputs.zig");
const catalog = @import("gsp_catalog.zig");
const link = @import("gsp_display_link.zig");
const route = @import("gsp_output_route.zig");
pub const Choice = struct { plan: boot.Plan, resize: bool };
const Selection = struct {
    previous: boot.Plan,
    best: ?Choice = null,
    rank: u8 = 255,
    fn consider(self: *Selection, plan: boot.Plan, preferred: bool) void {
        const same_size = plan.width == self.previous.width and plan.height == self.previous.height;
        const rank: u8 = if (same_size and sameSignal(plan, self.previous)) 0 else if (same_size and preferred) 1 else
            if (same_size) 2 else if (preferred) 3 else 4;
        if (rank < self.rank) { self.best = .{ .plan = plan, .resize = !same_size }; self.rank = rank; }
    }
};

pub fn choose(base: boot.Plan, snapshot: *const outputs.Snapshot, object: @import("gsp_display_rpc.zig").Object,
    previous: boot.Plan) !Choice
{
    if (base.receiver_mode_id != 0 or base.cta_vic != 0 or base.epoch != previous.epoch or
        base.head != previous.head or base.window != previous.window or base.signal.display_id != previous.signal.display_id or
        !std.meta.eql(base, try boot.bind(base, snapshot, base.epoch, base.held_generation))) return error.Stale;
    const observed = try @import("gsp_hotplug.zig").observe(snapshot, base.signal.display_id);
    if (observed.state != .connected) return error.Unavailable;
    var selection: Selection = .{ .previous = previous };
    for (snapshot.receivers[0..snapshot.count]) |*capture| if (capture.display_id == base.signal.display_id) {
        var modes: catalog.Modes = .{ .report = &capture.report };
        while (modes.next()) |entry| {
            const plan = @import("gsp_receiver_mode.zig").select(base, snapshot, entry.mode.mode_id) catch |err| {
                if (err == error.Unsupported) continue; return err;
            };
            _ = link.derive(plan, object, snapshot) catch |err| {
                if (err == error.Unsupported) continue; return err;
            };
            selection.consider(plan, entry.mode.flags & a.gfx_output_mode_preferred != 0);
        }
    };
    // This is a candidate only. Runtime still requires a fresh successful
    // source-clock/IMP query before publishing or applying its geometry.
    return selection.best orelse error.Unsupported;
}
/// An assigned additional head has no firmware raster to rebind. Derive
/// each candidate from its retained channel/SOR claim and fresh exact EDID.
pub fn chooseAssigned(source: route.Source, raw: *const @import("boot_scanout.zig").Raw,
    hardware: @import("gsp_display_engine_wire.zig").StaticInfo, snapshot: *const outputs.Snapshot,
    object: @import("gsp_display_rpc.zig").Object, claim: route.Claim, previous: boot.Plan) !Choice
{
    if (source.epoch != previous.epoch or claim.head != previous.head or claim.window != previous.window or
        claim.display_id != previous.signal.display_id) return error.Stale;
    if ((try @import("gsp_hotplug.zig").observe(snapshot, claim.display_id)).state != .connected) return error.Unavailable;
    var selection: Selection = .{ .previous = previous };
    for (snapshot.receivers[0..snapshot.count]) |*capture| if (capture.display_id == claim.display_id) {
        var modes: catalog.Modes = .{ .report = &capture.report };
        while (modes.next()) |entry| {
            const plan = route.derive(source, raw, hardware, snapshot, claim, entry.mode.mode_id) catch |err| {
                if (err == error.Unsupported or err == error.Routing or err == error.Stale) continue;
                return err;
            };
            _ = link.derive(plan, object, snapshot) catch |err| {
                if (err == error.Unsupported) continue; return err;
            };
            selection.consider(plan, entry.mode.flags & a.gfx_output_mode_preferred != 0);
        }
    };
    return selection.best orelse error.Unsupported;
}
fn sameSignal(left: boot.Plan, right: boot.Plan) bool {
    return left.transport_hdmi == right.transport_hdmi and left.refresh_micro_hz == right.refresh_micro_hz and
        std.meta.eql(left.signal, right.signal);
}
