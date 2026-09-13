//! Select a fresh receiver mode. A previous mode ID is never reused across
//! captures; raster equality and current EDID/transport admission decide.
const std = @import("std");
const a = @import("r4os").abi;
const boot = @import("gsp_boot_mode.zig");
const outputs = @import("gsp_outputs.zig");
const catalog = @import("gsp_catalog.zig");
const link = @import("gsp_hdmi_link.zig");
pub const Choice = struct { plan: boot.Plan, resize: bool };

pub fn choose(base: boot.Plan, snapshot: *const outputs.Snapshot, object: @import("gsp_display_rpc.zig").Object,
    previous: boot.Plan) !Choice
{
    if (base.receiver_mode_id != 0 or base.cta_vic != 0 or base.epoch != previous.epoch or
        base.head != previous.head or base.window != previous.window or base.signal.display_id != previous.signal.display_id or
        !std.meta.eql(base, try boot.bind(base, snapshot, base.epoch, base.held_generation))) return error.Stale;
    const observed = try @import("gsp_hotplug.zig").observe(snapshot, base.signal.display_id);
    if (observed.state != .connected) return error.Unavailable;
    var best: ?Choice = null;
    var rank: u8 = 255;
    for (snapshot.receivers[0..snapshot.count]) |*capture| if (capture.display_id == base.signal.display_id) {
        var modes: catalog.Modes = .{ .report = &capture.report };
        while (modes.next()) |entry| {
            const plan = @import("gsp_receiver_mode.zig").select(base, snapshot, entry.mode.mode_id) catch |err| {
                if (err == error.Unsupported) continue; return err;
            };
            _ = link.derive(plan, object, snapshot) catch |err| {
                if (err == error.Unsupported) continue; return err;
            };
            const same_size = plan.width == previous.width and plan.height == previous.height;
            const preferred = entry.mode.flags & a.gfx_output_mode_preferred != 0;
            const value: u8 = if (same_size and sameSignal(plan, previous)) 0 else if (same_size and preferred) 1 else
                if (same_size) 2 else if (preferred) 3 else 4;
            if (value < rank) { best = .{ .plan = plan, .resize = !same_size }; rank = value; }
        }
    };
    // This is a candidate only. Runtime still requires a fresh successful
    // source-clock/IMP query before publishing or applying its geometry.
    return best orelse error.Unsupported;
}
fn sameSignal(left: boot.Plan, right: boot.Plan) bool {
    return left.transport_hdmi == right.transport_hdmi and left.refresh_micro_hz == right.refresh_micro_hz and
        std.meta.eql(left.signal, right.signal);
}
