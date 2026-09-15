//! NVIDIA570.144 ctrl0073dp.h/ctrl0073common.h and dpcd14.h capability
//! fields. Captured facts stay separate from the implemented transport and
//! from any successful link/encoder transaction.
const std = @import("std");
pub const Error = error{ Payload, Unsupported };
pub const DscSource = struct {
    advertised: bool = false,
    usable: bool = false,
    formats: u32 = 0,
    //The RM field is named lineBufferSizeKB, but nvt_dsc_pps.c2166
    //defines these hardware units as1024 pixels, not1024 bytes.
    line_buffer_pixels: u64 = 0,
    rate_buffer_bytes: u64 = 0,
    bpp_increment_x16: u8 = 0,
    max_slices: u32 = 0,
    line_buffer_bits: u32 = 0,
    /// The DSC tail of DP_GET_CAPS is the GPU-wide encoder query for both
    /// HDMI and DP. HDMI does not acquire DP link/FEC capabilities from it.
    pub fn decode(data: []const u8) Error!DscSource {
        if (data.len != 28 or data[0] > 1) return error.Payload;
        if (data[0] == 0) return .{};
        var result: DscSource = .{ .advertised = true, .formats = word(data, 4),
            .line_buffer_pixels = @as(u64, word(data, 8)) * 1024,
            .rate_buffer_bytes = @as(u64, word(data, 12)) * 1024,
            .max_slices = word(data, 20), .line_buffer_bits = word(data, 24) };
        const precision = word(data, 16);
        if (precision >= 1 and precision <= 5) result.bpp_increment_x16 = @as(u8, 1) << @as(u3, @intCast(precision - 1));
        result.usable = result.formats & 1 != 0 and result.bpp_increment_x16 != 0 and
            result.line_buffer_pixels != 0 and result.rate_buffer_bytes != 0 and result.max_slices != 0 and
            result.line_buffer_bits >= 8 and result.line_buffer_bits <= 16;
        return result;
    }
};
pub const DpSource = struct {
    rate: u8,
    increased_watermark: bool,
    dp14: bool = false,
    mst: bool = false,
    single_head_mst: bool = false,
    fec: bool = false,
    uhbr_mask: u32 = 0,
    dsc: DscSource = .{},

    pub fn decode(data: []const u8) Error!DpSource {
        if (data.len != 64) return error.Payload;
        const raw_rate = word(data, 8);
        if (raw_rate < 1 or raw_rate > 4) return error.Unsupported;
        for (data[24..34]) |flag| if (flag > 1) return error.Payload;
        if (data[36] > 1) return error.Payload;
        const rates = [_]u8{ 6, 10, 20, 30 };
        var result: DpSource = .{ .rate = rates[raw_rate - 1], .increased_watermark = data[26] == 1,
            .dp14 = word(data, 12) & 2 != 0, .mst = data[24] == 1,
            .single_head_mst = data[28] == 1, .fec = data[29] == 1, .uhbr_mask = word(data, 16) };
        result.dsc = try DscSource.decode(data[36..64]);
        result.dsc.usable = result.dp14 and result.dsc.usable;
        return result;
    }
};
fn word(bytes: []const u8, offset: usize) u32 { return std.mem.readInt(u32, bytes[offset..][0..4], .little); }
pub const DscSink = struct {
    raw: [16]u8 = @splat(0),
    advertised: bool = false,
    usable: bool = false,
    version_major: u8 = 0,
    version_minor: u8 = 0,
    rc_buffer_bytes: u32 = 0,
    slice_mask: u32 = 0, //BitN means N horizontal slices, including16/20/24.
    line_buffer_bits: u8 = 0,
    block_prediction: bool = false,
    max_bpp_x16: u16 = 0,
    formats: u8 = 0,
    bpc_mask: u8 = 0, //8/10/12bpc
    slice_clock_mhz: u16 = 0,
    max_slice_width: u16 = 0,
    bpp_increment_x16: u8 = 0,

    pub fn decode(data: [16]u8) DscSink {
        var result: DscSink = .{ .raw = data, .advertised = data[0] & 1 != 0 };
        if (!result.advertised) return result;
        result.version_major = data[1] & 15; result.version_minor = data[1] >> 4;
        result.rc_buffer_bytes = (@as(u32, data[3]) + 1) * (@as(u32, 1024) << @as(u5, @intCast((data[2] & 3) * 2)));
        const counts = [_]u5{ 1, 2, 0, 4, 6, 8, 10, 12, 16, 20, 24 };
        const raw_mask: u16 = data[4] | (@as(u16, data[13] & 7) << 8);
        for (counts, 0..) |count, bit| if (count != 0 and raw_mask & (@as(u16, 1) << @as(u4, @intCast(bit))) != 0) {
            result.slice_mask |= @as(u32, 1) << count;
        };
        const depth = data[5] & 15;
        result.line_buffer_bits = if (depth < 8) depth + 9 else if (depth == 8) 8 else 0;
        result.block_prediction = data[6] & 1 != 0;
        result.max_bpp_x16 = data[7] | (@as(u16, data[8] & 3) << 8);
        result.formats = data[9] & 31;
        result.bpc_mask = (data[10] >> 1) & 7;
        const throughput = data[11] & 15;
        result.slice_clock_mhz = if (throughput == 15) 170 else if (throughput == 1) 340 else if (throughput >= 2 and throughput <= 14)
            400 + @as(u16, throughput - 2) * 50 else 0;
        result.max_slice_width = @as(u16, data[12]) * 320;
        const increment = data[15] & 7;
        if (increment <= 4) result.bpp_increment_x16 = @as(u8, 1) << @as(u3, @intCast(increment));
        result.usable = result.version_major == 1 and (result.version_minor == 1 or result.version_minor == 2) and
            result.slice_mask != 0 and result.line_buffer_bits != 0 and result.formats & 1 != 0 and
            result.bpc_mask != 0 and result.slice_clock_mhz != 0 and result.max_slice_width >= 320 and
            result.bpp_increment_x16 != 0;
        return result;
    }
};
pub const Capture = enum { unqueried, complete, unavailable, invalid };
pub const HdmiCapture = struct {
    state: Capture = .unqueried,
    source_max: @import("r4gfx_outputs").links.Frl = .none,
    receipt_serial: u64 = 0,
    dsc_state: Capture = .unqueried,
    dsc: DscSource = .{},
};
pub const DpReceiver = struct {
    dsc_state: Capture = .unqueried,
    dsc: DscSink = .{},
    mst_state: Capture = .unqueried,
    mst: bool = false,
    fec_state: Capture = .unqueried,
    fec: bool = false,
};
/// Read-only capabilities belong to one coherent receiver capture. They
/// allow mode admission but never prove training, FEC or a running encoder.
pub const DpCapture = struct {
    source_state: Capture = .unqueried,
    source: ?DpSource = null,
    dpcd_state: Capture = .unqueried,
    dpcd: [16]u8 = @splat(0),
    receiver: DpReceiver = .{},
    repeaters_state: Capture = .unqueried,
    repeaters: u8 = 0,
    receipt_serial: u64 = 0,
};
