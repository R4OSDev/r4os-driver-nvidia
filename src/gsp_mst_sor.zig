//! Derive a shared SOR mask from the Runtime's actual completed images.
//! Each mode retains its own head intent; joining/leaving siblings never
//! rewrites their immutable link receipts or chooses a new physical route.
const std = @import("std");
const boot = @import("gsp_boot_mode.zig");
pub fn control(plan: boot.Plan, images: anytype, detach: bool) !?u32 {
    const stamp = plan.signal.mst orelse return null;
    try boot.validate(plan.signal, plan.head);
    if (stamp.handle.epoch != plan.epoch or plan.window >= 8 or images.len > 8) return error.Stale;
    var mask: u32 = if (detach) 0 else @as(u32, 1) << @intCast(plan.head);
    var departing = false;
    for (images, 0..) |*slot, index| if (slot.*) |*active| {
        const mode = active.boot_mode orelse return error.Stale;
        if (mode.window != index or mode.head >= 8) return error.Stale;
        if (mode.signal.sor != plan.signal.sor) continue;
        const sibling = mode.signal.mst orelse return error.Routing;
        if (mode.epoch != plan.epoch or sibling.root != stamp.root or sibling.handle.epoch != stamp.handle.epoch or
            mode.signal.sor_control & ~@as(u32, 255) != plan.signal.sor_control & ~@as(u32, 255) or
            active.core_point == 0 or active.window_point == 0 or active.link == null or !active.link.?.complete()) return error.Stale;
        try boot.validate(mode.signal, mode.head);
        if (index == plan.window) {
            if (!std.meta.eql(sibling, stamp) or mode.head != plan.head) return error.Stale;
            departing = true;
            continue;
        }
        const bit = @as(u32, 1) << @intCast(mode.head);
        if (mode.head == plan.head or mask & bit != 0) return error.Routing;
        mask |= bit;
    };
    if (detach and !departing) return error.Stale;
    return if (mask == 0) 0 else (plan.signal.sor_control & ~@as(u32, 255)) | mask;
}
/// A failed new stream reached Core but was never published as an image.
/// Remove its verified candidate head from the same completed sibling union.
pub fn withoutCandidate(plan: boot.Plan, images: anytype) !u32 {
    const value = (try control(plan, images, false)) orelse return error.Descriptor;
    const mask = (value & 255) & ~(@as(u32, 1) << @intCast(plan.head));
    return if (mask == 0) 0 else (value & ~@as(u32, 255)) | mask;
}
