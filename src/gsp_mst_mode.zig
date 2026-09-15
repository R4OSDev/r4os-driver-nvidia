//! Exact RGB8/10 MST admission against the physical source/root and every
//! shared branch path. The leaf's remote DPCD is never a root training cap.
const std = @import("std");
const boot = @import("gsp_boot_mode.zig");
const binding = @import("gsp_mst_binding.zig");
const budget = @import("gsp_mst_budget.zig");
const color = @import("gsp_color_signal.zig");
pub fn admit(plan: boot.Plan, snapshot: *const @import("gsp_outputs.zig").Snapshot) !budget.Budget {
    const stamp = plan.signal.mst orelse return error.Descriptor;
    try boot.validate(plan.signal, plan.head);
    try color.validate(plan);
    const view = try binding.derive(snapshot, stamp.display_id);
    if (!std.meta.eql(stamp, view.stamp) or !std.meta.eql(plan, try boot.bind(plan, snapshot, plan.epoch, plan.held_generation)) or
        plan.receiver_mode_id == 0 or view.sink.state != .valid or !view.sink.report.complete()) return error.Stale;
    if (plan.signal.dp_dsc != null or plan.signal.dp_vsc or plan.transport_hdmi or plan.signal.hdmi_frl or
        !view.sink.report.digital or view.sink.report.colors & 1 == 0 or
        (plan.signal.bpc == 10 and view.sink.report.bits_per_color < 10)) return error.Unsupported;
    const sink = try @import("gsp_dp_link.zig").receiverCaps(view.root.dpcd);
    const source = view.root.source.?;
    if (!source.mst or sink.revision < 0x12 or !sink.enhanced) return error.Unsupported;
    var link: budget.payload.Link = .{ .rate = @min(source.rate, sink.rate), .lanes = sink.lanes };
    if (view.root.live.table.count != 0) {
        const active = view.root.live.training orelse return error.Stale;
        if (active.receipt == 0 or active.link.rate > link.rate or active.link.lanes > link.lanes or
            !@import("gsp_dp_link.zig").trained(active.lanes, active.link.lanes)) return error.Stale;
        link = active.link;
    }
    var entry: budget.Entry = .{ .handle = stamp.handle, .key = view.slot.key, .window = @intCast(plan.window),
        .path_count = view.sink.path_count,
        .timing = .{ .clock = color.links.Clock.nvidia(plan.signal.clock), .width = plan.width,
            .total = plan.signal.total & 0xffff, .bpc = plan.signal.bpc },
        .allocation = .{ .display_id = stamp.display_id, .head = @intCast(plan.head) } };
    for (view.sink.path[0..view.sink.path_count], 0..) |edge, index| entry.path[index] = try budget.Edge.capture(&view.root.graph, edge);
    const result = try budget.plan(&view.root.graph, &view.root.live, &view.root.captured_table, link, entry);
    // Shared color admission still enforces the app's signal contract. MST
    // HDR/VSC/DSC are explicitly unsupported by this RGB pipeline.
    _ = try color.admit(plan, &view.sink.report, .{ .displayport = .{
        .payload_bits_per_second = try color.links.dp8b10bPayload(link.rate, link.lanes), .vsc = false, .hdr_sdp = false } });
    return result;
}
