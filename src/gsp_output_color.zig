//! Confirmed source color facts. Pixel encoding follows the acknowledged
//! Core/Window/link transaction. Programmable LUT/CTM caps remain zero.
const std = @import("std");
const a = @import("r4os").abi;
pub fn rgb8(identity: a.GfxOutputId) a.GfxOutputColorState {
    return .{ .identity = identity,
        .flags = a.gfx_output_color_known | a.gfx_output_color_active | a.gfx_output_color_identity,
        .format = a.gfx_buffer_format_xrgb8888, .bpc = 8,
        .primaries = 1, .transfer = 1, .range = 1, .reference_white = 1_000_000, .peak = 1_000_000,
        .formats = 1, .depths = 1, .color_spaces = 1, .transfers = 1, .ranges = 1 };
}
pub const Owner = struct {
    reported: ?a.GfxOutputColorState = null,
    last_status: i32 = 0,
    pub fn step(self: *Owner, product: anytype) bool {
        const outputs = product.outputs orelse return false;
        if (!outputs.supportsColor() or product.output.connector_id == 0) return false;
        const mode = product.mode orelse return false;
        const running = product.running orelse return false;
        if (running.outputPaused(mode.window)) return false;
        const active = running.display_images[mode.window] orelse return false;
        const link = active.link orelse return false;
        if (!link.complete()) return false;
        var state = rgb8(product.output);
        if (outputs.supportsModeColor()) {
            const transport: @import("gsp_color_signal.zig").color.Transport = if (link.plan.mode.displayPort()) .displayport else if (link.plan.mode.transport_hdmi) .hdmi else .dvi;
            var source = @import("gsp_color_signal.zig").source(transport);
            if (link.mst != null) {
                source.eotf = 1; source.primaries = 1; source.ranges = 1; source.static_metadata = false; source.dp_vsc = false;
            }
            if (link.dp) |dp| if (!dp.source.dp14) {
                source.eotf = 1; source.primaries = 1; source.ranges = 1; source.static_metadata = false; source.dp_vsc = false;
            };
            state.formats = source.formats; state.depths = source.bpc; state.color_spaces = source.primaries;
            state.transfers = source.eotf; state.ranges = source.ranges;
            if (source.static_metadata) state.flags |= if (transport == .hdmi) a.gfx_output_color_hdmi_metadata else a.gfx_output_color_dp_metadata;
            if (source.dp_vsc) state.flags |= a.gfx_output_color_dp_vsc;
        }
        if (link.plan.mode.color) |signal| {
            state.format = if (signal.format == .xr30) a.gfx_buffer_format_xrgb2101010 else a.gfx_buffer_format_xrgb8888;
            state.bpc = signal.bpc; state.primaries = if (signal.primaries == .bt2020) 3 else 1;
            state.transfer = switch (signal.transfer) { .srgb => 1, .pq => 3, .hlg => 4 };
            state.range = if (signal.range == .limited) 2 else 1;
            state.reference_white = signal.reference_white; state.peak = signal.peak; state.black = signal.black;
        }
        if (active.image.format != state.format) return false;
        linkFacts(&state, link) catch return false;
        if (link.plan.mode.transport_hdmi) if (running.nativeOutputs()) |snapshot| {
            for (snapshot.receivers[0..snapshot.count]) |*receiver| {
                if (receiver.display_id != link.plan.mode.signal.display_id or receiver.connected != true or receiver.status != .valid_edid or
                    receiver.frl.state != .complete or receiver.frl.receipt_serial == 0) continue;
                const sink = receiver.report.hdmi_links orelse continue;
                state.max_frl_rate = @min(@intFromEnum(receiver.frl.source_max), @intFromEnum(sink.max_frl));
                if (receiver.frl.dsc_state == .complete and receiver.frl.dsc.usable and receiver.frl.dsc.bpp_increment_x16 == 1 and
                    state.max_frl_rate != 0 and sink.dsc.advertised and sink.dsc.supported_fields and sink.dsc.max_frl != .none) {
                    state.dsc_depths = sink.dsc.bpc_mask & state.depths & 3;
                    if (receiver.frl.dsc.line_buffer_bits < 10) state.dsc_depths &= 1;
                }
                break;
            }
        };
        if (self.reported) |old| if (std.meta.eql(old, state)) return false;
        // Caller reaches this only after its physical/common activation and
        // online hotplug state. Publication is bounded metadata, without I/O.
        self.last_status = outputs.publishColor(&state);
        if (self.last_status != a.gfx_output_ok) return false;
        self.reported = state;
        return true;
    }
};
pub fn linkFacts(state: *a.GfxOutputColorState, link: @import("gsp_runtime.zig").DisplayLink) !void {
    if (!link.complete()) return error.Stale;
    const saved = link.plan.mode;
    const links = @import("gsp_color_signal.zig").links;
    const clock = links.Clock.nvidia(saved.signal.clock);
    state.h_active = saved.width; state.h_total = saved.signal.total & 0xffff; state.v_active = saved.height;
    state.pixel_clock_numerator = clock.numerator; state.pixel_clock_denominator = clock.denominator;
    if (link.mst) |mst| {
        state.link_kind = a.gfx_output_link_dp_mst;
        state.dp_payload_bits_per_second = try links.dp8b10bPayload(mst.training.link.rate, mst.training.link.lanes);
        state.link_payload_bits_per_second = state.dp_payload_bits_per_second;
        state.link_lanes = mst.training.link.lanes; state.link_rate_mbps = @as(u32, mst.training.link.rate) * 270;
    } else if (link.dp) |dp| {
        state.link_kind = a.gfx_output_link_dp_sst;
        // The compatible prefix stays an uncompressed physical budget. The
        // extension reports the current FEC reserve and exact admitted PPS.
        state.dp_payload_bits_per_second = try links.dp8b10bPayload(dp.config.rate, dp.config.lanes);
        state.link_payload_bits_per_second = state.dp_payload_bits_per_second;
        state.link_lanes = dp.config.lanes; state.link_rate_mbps = @as(u32, dp.config.rate) * 270;
        if (dp.source.dp14 and dp.source.fec and dp.source.dsc.usable and dp.receiver_caps.fec_state == .complete and dp.receiver_caps.fec and
            dp.receiver_caps.dsc_state == .complete and dp.receiver_caps.dsc.usable) {
            state.dsc_depths = dp.receiver_caps.dsc.bpc_mask & state.depths & 3;
            if (dp.source.dsc.line_buffer_bits < 10) state.dsc_depths &= 1;
        }
        if (dp.compressed) |compressed| {
            state.link_flags = a.gfx_output_link_fec | a.gfx_output_link_dsc;
            state.compressed_bpp_x16 = compressed.params.bpp_x16;
            state.link_payload_bits_per_second = try @import("gsp_dp_watermark.zig").payload(dp.config.rate, dp.config.lanes);
        }
    } else {
        state.link_kind = a.gfx_output_link_tmds;
        state.max_tmds_clock_hz = if (saved.transport_hdmi) 600_000_000 else 165_000_000;
        if (saved.transport_hdmi) state.flags |= a.gfx_output_color_scdc;
        if (link.frl) |frl| {
            state.link_kind = a.gfx_output_link_frl;
            state.link_flags = a.gfx_output_link_fec;
            state.max_frl_rate = @min(@intFromEnum(frl.source_max), @intFromEnum(link.plan.frl.?.sink_max));
            state.link_lanes = frl.rate.lanes(); state.link_rate_mbps = @as(u32, frl.rate.gigabits()) * 1000;
            state.link_payload_bits_per_second = frl.rate.codingCeiling();
            if (frl.dsc_source.usable and saved.hdmi_dsc_sink.advertised and saved.hdmi_dsc_sink.supported_fields) {
                state.dsc_depths = saved.hdmi_dsc_sink.bpc_mask & state.depths & 3;
                if (frl.dsc_source.line_buffer_bits < 10) state.dsc_depths &= 1;
            }
            if (frl.compressed) |compressed| {
                state.link_flags |= a.gfx_output_link_dsc;
                state.compressed_bpp_x16 = compressed.params.bpp_x16;
            }
        }
    }
}
