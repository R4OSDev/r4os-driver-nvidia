//! Select an exact DSC configuration from the current read-only receiver
//! capture. Uncompressed modes remain preferred. Training revalidates this
//! same configuration before source FEC/encoder or receiver setters.
const std = @import("std");
const boot = @import("gsp_boot_mode.zig");
const receiver = @import("gsp_receiver.zig");
const dsc = @import("gsp_dsc.zig");
const fec = @import("gsp_dp_watermark.zig");
const links = dsc.links;
pub fn select(saved: boot.Plan, capture: *const receiver.Capture) !boot.Plan {
    var plan = saved;
    plan.signal.dp_dsc = null;
    if (!plan.displayPort()) return plan;
    if (plan.signal.mst != null) return plan; // Shared root admission owns MST; never infer DSC from a virtual receiver.
    const clock = links.Clock.nvidia(plan.signal.clock);
    const demand = try links.rgbDemand(clock, plan.signal.bpc);
    const caps = &capture.dp;
    // Missing optional discovery leaves ordinary SST's existing live link
    // admission available. It does not authorize a compressed mode.
    if (caps.source_state != .complete or caps.source == null or caps.dpcd_state != .complete) return plan;
    const source = caps.source.?;
    const raw = caps.dpcd;
    if ((raw[0] < 0x10 or raw[0] > 0x14) and raw[0] != 0x20 or raw[6] & 1 == 0) return plan;
    const sink_lanes = raw[2] & 31;
    if (sink_lanes != 1 and sink_lanes != 2 and sink_lanes != 4) return plan;
    var sink_rate = raw[1];
    _ = links.dp8b10bPayload(sink_rate, sink_lanes) catch return plan;
    if (sink_rate == 30 and raw[3] & 0x80 == 0) sink_rate = 20;
    const rate = @min(source.rate, sink_rate);
    if (demand.fits(try links.dp8b10bPayload(rate, sink_lanes)) and
        (plan.signal.bpc == 8 or capture.report.bits_per_color >= plan.signal.bpc)) return plan;
    if (capture.status != .valid_edid or capture.connected != true or !capture.report.complete() or caps.receipt_serial == 0 or
        !source.dp14 or !source.fec or caps.receiver.fec_state != .complete or !caps.receiver.fec or
        caps.receiver.dsc_state != .complete or !caps.receiver.dsc.usable or
        caps.repeaters_state != .complete or caps.repeaters != 0) return error.Bandwidth;
    const total = plan.signal.total & 0xffff;
    if (total <= plan.width) return error.Descriptor;
    const compressed = try dsc.generate(.{ .clock = clock, .width = plan.width, .height = plan.height, .bpc = plan.signal.bpc, .hblank = total - plan.width, .source = source.dsc, .sink = caps.receiver.dsc, .payload_bps = try fec.payload(rate, sink_lanes), .rate = rate, .lanes = sink_lanes });
    _ = try fec.withFec(.{ .clock = clock, .width = plan.width, .total = total, .bpp_x16 = compressed.bpp_x16, .rate = rate, .lanes = sink_lanes, .enhanced = raw[2] & 0x80 != 0, .increased = source.increased_watermark, .compression = .{ .count = compressed.slices, .width = compressed.slice_width, .chunk_bytes = compressed.chunk_bytes } });
    plan.signal.dp_dsc = .{ .params = compressed, .rate = rate, .lanes = sink_lanes };
    return plan;
}
pub fn validate(saved: boot.Plan, capture: *const receiver.Capture) !void {
    if (!std.meta.eql(saved, try select(saved, capture))) return error.Stale;
}
