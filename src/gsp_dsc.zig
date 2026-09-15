//! Bounded RGB DSC admission around the original NVIDIA 570.144 MIT PPS
//! generator. A generated PPS is configuration data, never an encoder/link
//! completion receipt. DP callers must separately prove source/sink FEC.
const std = @import("std");
const caps = @import("gsp_link_caps.zig");
pub const links = @import("r4gfx_edid").links;
const c = @cImport({
    @cInclude("r4os_dsc.h");
});
pub const Error = error{ Unsupported, Bandwidth, Parameter, Pps };
pub const Transport = enum(u32) { dp_sst, dp_mst, hdmi };
pub const Request = struct {
    clock: links.Clock,
    width: u32,
    height: u32,
    bpc: u8,
    hblank: u32,
    source: caps.DscSource,
    sink: caps.DscSink,
    payload_bps: u64,
    transport: Transport = .dp_sst,
    rate: u8 = 0,
    lanes: u8 = 0,
    forced_bpp_x16: u16 = 0,
    forced_slice_width: u16 = 0,
};
pub const Plan = struct {
    pps: [32]u32,
    bpp_x16: u16,
    slices: u8,
    slice_width: u16,
    slice_height: u16,
    chunk_bytes: u16,
    rc_buffer_bytes: u16,
    pub fn bytes(self: Plan) [128]u8 {
        var result: [128]u8 = undefined;
        for (self.pps, 0..) |word, i| std.mem.writeInt(u32, result[i * 4 ..][0..4], word, .little);
        return result;
    }
    pub fn flatnessThreshold(self: Plan) u8 {
        const bpc = self.bytes()[3] >> 4;
        // Upstream DP setter incorrectly used bppX16 in this shift. The PPS
        // generator and HDMI setter both derive it from component depth.
        return @as(u8, 2) << @as(u3, @intCast(bpc - 8));
    }
};
pub const DpPlan = struct { params: Plan, rate: u8, lanes: u8 };
pub const HdmiPlan = struct {
    params: Plan,
    rate: links.Frl,
    hc_active_bytes: u16,
    hc_active_tri_bytes: u16,
    hc_blank_tri_bytes: u16,
    blank_ratio_x1k: u16,
};
pub fn fecPayload(rate: u8, lanes: u8) Error!u64 {
    const raw = links.dp8b10bPayload(rate, lanes) catch return error.Parameter;
    return raw * 976 / 1000; // NVIDIA DP 8b/10b FEC overhead, not UHBR.
}
fn powerStep(value: u32) bool {
    return value != 0 and value <= 16 and @popCount(value) == 1;
}
pub fn generate(request: Request) Error!Plan {
    const source = request.source;
    const sink = request.sink;
    if (!source.advertised or !source.usable or !sink.advertised or !sink.usable or
        source.formats & 1 == 0 or sink.formats & 1 == 0 or
        sink.version_major != 1 or (sink.version_minor != 1 and sink.version_minor != 2) or
        (request.bpc != 8 and request.bpc != 10 and request.bpc != 12) or
        sink.bpc_mask & (@as(u8, 1) << @as(u3, @intCast((request.bpc - 8) / 2))) == 0) return error.Unsupported;
    if (!powerStep(source.bpp_increment_x16) or !powerStep(sink.bpp_increment_x16) or
        source.line_buffer_pixels == 0 or source.line_buffer_pixels > 65536 or source.line_buffer_pixels % 1024 != 0 or
        source.max_slices == 0 or source.max_slices > 24 or source.line_buffer_bits < 8 or source.line_buffer_bits > 16 or
        sink.line_buffer_bits < 8 or sink.line_buffer_bits > 16 or sink.max_slice_width == 0 or sink.slice_mask == 0 or
        request.width == 0 or request.width > 65535 or request.height < 8 or request.height > 65535 or
        request.hblank > 65535 or request.clock.numerator == 0 or request.clock.denominator == 0) return error.Parameter;
    const pclk = request.clock.ceilHz() catch return error.Parameter;
    if (request.transport == .hdmi) {
        if (request.forced_bpp_x16 < 128 or request.forced_bpp_x16 >= @as(u16, request.bpc) * 48 or
            request.forced_bpp_x16 % @max(source.bpp_increment_x16, sink.bpp_increment_x16) != 0 or
            request.forced_slice_width == 0 or request.forced_slice_width > sink.max_slice_width) return error.Parameter;
    } else if (request.forced_bpp_x16 != 0 or request.forced_slice_width != 0) return error.Parameter;
    // Bound original integer arithmetic, including DP's 96*bandwidth*16.
    if (pclk > 4_000_000_000 or request.payload_bps == 0 or request.payload_bps > 64_000_000_000) return error.Parameter;
    if (request.transport != .hdmi and request.payload_bps > try fecPayload(request.rate, request.lanes)) return error.Bandwidth;
    const minimum: links.Demand = .{ .clock = request.clock, .bpp_x16 = 128 };
    if (!minimum.fits(request.payload_bps)) return error.Bandwidth;
    var mask: u32 = 0;
    const counts = [_]u5{ 1, 2, 0, 4, 6, 8, 10, 12, 16, 20, 24 };
    for (counts, 0..) |count, bit| if (count != 0 and sink.slice_mask & (@as(u32, 1) << count) != 0) {
        mask |= @as(u32, 1) << @as(u5, @intCast(bit));
    };
    const throughput: u32 = switch (sink.slice_clock_mhz) {
        170 => 15,
        340 => 1,
        else => if (sink.slice_clock_mhz >= 400 and sink.slice_clock_mhz <= 1000 and sink.slice_clock_mhz % 50 == 0)
            2 + @as(u32, sink.slice_clock_mhz - 400) / 50
        else
            return error.Unsupported,
    };
    const input: c.R4OS_DSC_INPUT = .{
        .pixel_clock_hz = pclk,
        .payload_bps = request.payload_bps,
        .link_rate_10mhz = @as(u64, request.rate) * 27,
        .width = request.width,
        .height = request.height,
        .bpc = request.bpc,
        .lanes = request.lanes,
        .hblank = request.hblank,
        .transport = @intFromEnum(request.transport),
        .sink_formats = sink.formats,
        .sink_step_x16 = sink.bpp_increment_x16,
        .max_slice_width = sink.max_slice_width,
        .slice_mask = mask,
        .sink_line_bits = sink.line_buffer_bits,
        .bpc_mask = sink.bpc_mask,
        .revision_minor = sink.version_minor,
        .block_prediction = @intFromBool(sink.block_prediction),
        .throughput_code = throughput,
        .max_bpp_x16 = sink.max_bpp_x16,
        .source_formats = source.formats,
        .source_line_units = @intCast(source.line_buffer_pixels / 1024),
        .source_step_x16 = source.bpp_increment_x16,
        .source_slices = source.max_slices,
        .source_line_bits = source.line_buffer_bits,
        .forced_bpp_x16 = request.forced_bpp_x16,
        .forced_slice_width = request.forced_slice_width,
    };
    var output: c.R4OS_DSC_OUTPUT = std.mem.zeroes(c.R4OS_DSC_OUTPUT);
    if (c.r4os_dsc_generate(&input, &output) != 0) return error.Unsupported;
    if (request.transport == .hdmi and output.bpp_x16 != request.forced_bpp_x16) return error.Pps;
    if (output.bpp_x16 < 128 or output.bpp_x16 >= @as(u32, request.bpc) * 3 * 16 or output.bpp_x16 > 1023) return error.Pps;
    var plan: Plan = .{ .pps = output.pps, .bpp_x16 = @intCast(output.bpp_x16), .slices = 0, .slice_width = 0, .slice_height = 0, .chunk_bytes = 0, .rc_buffer_bytes = 0 };
    const bytes = plan.bytes();
    if (bytes[0] != (0x10 | sink.version_minor) or bytes[3] >> 4 != request.bpc or bytes[4] & 0x1c != 0x10 or bytes[88] != 0 or
        ((@as(u16, bytes[4] & 3) << 8) | bytes[5]) != plan.bpp_x16 or be(&bytes, 6) != request.height or be(&bytes, 8) != request.width or
        (bytes[4] & 0x20 != 0 and !sink.block_prediction)) return error.Pps;
    plan.slice_width = be(&bytes, 12);
    plan.slice_height = be(&bytes, 10);
    plan.chunk_bytes = be(&bytes, 14);
    plan.rc_buffer_bytes = @intCast((@as(u32, be(&bytes, 38)) + 7) / 8);
    if (plan.slice_width == 0 or plan.slice_width > sink.max_slice_width or plan.slice_width > source.line_buffer_pixels or
        plan.slice_height < 8 or request.height % plan.slice_height != 0 or plan.chunk_bytes == 0 or plan.rc_buffer_bytes == 0 or
        plan.rc_buffer_bytes > source.rate_buffer_bytes or
        (request.transport != .hdmi and plan.rc_buffer_bytes > sink.rc_buffer_bytes) or
        (request.transport == .hdmi and plan.slice_width != request.forced_slice_width)) return error.Pps;
    const slices = (request.width + plan.slice_width - 1) / plan.slice_width;
    if (slices > 24 or slices > source.max_slices or sink.slice_mask & (@as(u32, 1) << @as(u5, @intCast(slices))) == 0 or
        request.clock.numerator > @as(u128, slices) * sink.slice_clock_mhz * 1_000_000 * request.clock.denominator or
        plan.bpp_x16 % @max(sink.bpp_increment_x16, source.bpp_increment_x16) != 0 or
        (sink.max_bpp_x16 != 0 and plan.bpp_x16 > sink.max_bpp_x16)) return error.Pps;
    plan.slices = @intCast(slices);
    const demand: links.Demand = .{ .clock = request.clock, .bpp_x16 = plan.bpp_x16 };
    // Chunk rounding can consume more than ideal bpp. Check both exact
    // rational rates before the caller may prepare encoder/FEC setters.
    if (!demand.fits(request.payload_bps) or @as(u128, plan.chunk_bytes) * slices * 8 * request.clock.numerator >=
        @as(u128, request.payload_bps) * request.width * request.clock.denominator) return error.Bandwidth;
    return plan;
}
fn be(bytes: *const [128]u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}
