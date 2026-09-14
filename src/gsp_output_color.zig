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
            const transport: @import("gsp_color_signal.zig").color.Transport = if (link.dp != null) .displayport else if (link.plan.mode.transport_hdmi) .hdmi else .dvi;
            var source = @import("gsp_color_signal.zig").source(transport);
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
        if (link.dp) |dp| {
            // Current trained lane count/rate after8b10b coding. A receiver
            // maximum or a failed training attempt never supplies this budget.
            state.dp_payload_bits_per_second = @as(u64, dp.config.rate) * 27_000_000 * 8 * dp.config.lanes;
        } else {
            state.max_tmds_clock_hz = if (link.plan.mode.transport_hdmi) 600_000_000 else 165_000_000;
            if (link.plan.mode.transport_hdmi) state.flags |= a.gfx_output_color_scdc;
        }
        if (self.reported) |old| if (std.meta.eql(old, state)) return false;
        // Caller reaches this only after its physical/common activation and
        // online hotplug state. Publication is bounded metadata, without I/O.
        self.last_status = outputs.publishColor(&state);
        if (self.last_status != a.gfx_output_ok) return false;
        self.reported = state;
        return true;
    }
};
