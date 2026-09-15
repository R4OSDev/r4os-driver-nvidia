// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2021 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//  * SPDX-License-Identifier: MIT
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be included in
//  * all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  *
//  * File:      nvhdmipkt_C671.c
//  *
//  * Purpose:   Provides packet write functions for HDMI library  for Ampere+ chips
//  */
//! HDMI DSC parameters, using NVIDIA570.144 nvhdmipkt_C671.c
//! populateDscCaps/calcBppMinMax and the original MIT PPS generator.
//! RM capacity calculation must first choose the exact rate, BPP and slices.
//! This helper produces PPS only; it never proves capacity or activation.
const dsc = @import("gsp_dsc.zig");
const std = @import("std");
const caps = @import("gsp_link_caps.zig");
pub const links = dsc.links;
pub const Plan = dsc.HdmiPlan;
pub const Request = struct {
    clock: links.Clock,
    width: u32,
    height: u32,
    hblank: u32,
    bpc: u8,
    source: caps.DscSource,
    receiver: links.HdmiDsc,
    rate: links.Frl,
    bpp_x16: u16,
    slice_width: u16,
    slices: u8,
};
pub fn pps(request: Request) !dsc.Plan {
    const receiver = request.receiver;
    if (!receiver.advertised or !receiver.supported_fields or request.rate == .none or
        @intFromEnum(request.rate) > @intFromEnum(receiver.max_frl) or
        (request.bpc != 8 and request.bpc != 10) or receiver.bpc_mask & (if (request.bpc == 8) @as(u8, 1) else 2) == 0)
        return error.Unsupported;
    const maximum: u16 = if (receiver.all_bpp) @as(u16, request.bpc) * 48 - 1 else 192;
    if (request.bpp_x16 < 128 or request.bpp_x16 > maximum or request.slice_width == 0 or
        request.slices == 0 or request.slices > receiver.max_slices or receiver.max_chunk_bytes == 0 or
        (@as(u64, request.width) + request.slice_width - 1) / request.slice_width != request.slices) return error.Parameter;
    var mask: u32 = 0;
    for ([_]u5{ 1, 2, 4, 8, 12, 16 }) |count| if (count <= receiver.max_slices) {
        mask |= @as(u32, 1) << count;
    };
    // HDMI's decoder profile defines13-bit line storage and2720-pixel slice
    // width. These are HDMI parameters; no DPCD read or RC-buffer claim is
    // synthesized. Source RC storage is still checked from the real RM caps.
    const sink: caps.DscSink = .{ .advertised = true, .usable = true, .version_major = 1, .version_minor = 2, .slice_mask = mask, .line_buffer_bits = 13, .block_prediction = true, .max_bpp_x16 = maximum, .formats = 1, .bpc_mask = receiver.bpc_mask & 7, .slice_clock_mhz = receiver.max_slice_clock_mhz, .max_slice_width = 2720, .bpp_increment_x16 = 1 };
    const plan = try dsc.generate(.{ .clock = request.clock, .width = request.width, .height = request.height, .bpc = request.bpc, .hblank = request.hblank, .source = request.source, .sink = sink, .transport = .hdmi, .payload_bps = @as(u64, request.rate.lanes()) * request.rate.gigabits() * 1_000_000_000, .forced_bpp_x16 = request.bpp_x16, .forced_slice_width = request.slice_width });
    if (plan.slices != request.slices or @as(u64, plan.chunk_bytes) * plan.slices > receiver.max_chunk_bytes) return error.Bandwidth;
    return plan;
}

/// Read-only RM admission, preceding IMP and any hardware mutation. The
/// original primary-compressed-format search uses the lowest viable rate,
/// then the highest BPP, with coarse and fine descending probes. A fixed
/// plan repeats source, layout and exact capacity checks before activation.
pub const Input = struct {
    clock: links.Clock,
    width: u32,
    height: u32,
    total: u32,
    bpc: u8,
    vic: u8,
    receiver: links.HdmiDsc,
    maximum: links.Frl,
    fixed: ?Plan = null,
};
pub const Stage = enum { source, layout, precalc, preconfig, capacity, complete };
pub const Work = struct {
    input: Input,
    stage: Stage = .source,
    source: caps.DscSource = .{},
    rate: links.Frl = .none,
    bpp: u16 = 128,
    slices: u8 = 0,
    slice_width: u16 = 0,
    search: enum { rate, coarse, fine, fixed } = .rate,
    result: ?Plan = null,
    tri_bytes_borrowed: u32 = 0,
    receipt: u64 = 0,
    probes: u8 = 0,

    pub fn command(self: *const Work) u32 {
        return if (self.stage == .source) 0x731369 else 0x7302a8;
    }
    pub fn length(self: *const Work) usize {
        return if (self.stage == .source) 64 else 132;
    }
    pub fn maximum(self: *const Work) links.Frl {
        return @enumFromInt(@min(@intFromEnum(self.input.maximum), @intFromEnum(self.input.receiver.max_frl)));
    }
    fn maxBpp(self: *const Work) u16 {
        return if (self.input.receiver.all_bpp) @as(u16, self.input.bpc) * 48 - 1 else 192;
    }
    pub fn encode(self: *const Work, bytes: []u8) !usize {
        const input = self.input;
        if (bytes.len < self.length() or self.stage == .complete or !input.clock.valid() or input.total <= input.width or
            input.width == 0 or input.width > 65535 or input.height < 8 or input.height > 65535 or
            !input.receiver.advertised or !input.receiver.supported_fields or self.maximum() == .none or
            (input.bpc != 8 and input.bpc != 10) or input.receiver.bpc_mask & (if (input.bpc == 8) @as(u8, 1) else 2) == 0 or
            input.receiver.max_chunk_bytes == 0 or input.receiver.max_chunk_bytes % 1024 != 0) return error.Unsupported;
        const data = bytes[0..self.length()];
        @memset(data, 0);
        if (self.stage == .source) return data.len; //subdevice0, SOR0: documented GPU-wide DSC caps.
        if (self.stage == .precalc or self.stage == .preconfig) {
            data[0] = if (self.stage == .precalc) 3 else 5;
            put(data, 96, input.vic);
            put(data, 104, input.bpc);
            return data.len;
        }
        data[0] = if (self.stage == .layout) 6 else 2;
        if (self.stage == .capacity) {
            if (self.rate == .none or @intFromEnum(self.rate) > @intFromEnum(self.maximum()) or self.bpp < 128 or self.bpp > self.maxBpp()) return error.Bandwidth;
            put(data, 4, self.rate.lanes());
            put(data, 8, self.rate.gigabits());
            put(data, 44, self.bpp);
            put(data, 48, self.slices);
            put(data, 52, self.slice_width);
        } else {
            put(data, 120, @min(self.source.max_slices, input.receiver.max_slices));
            put(data, 124, 5120); //C67D per-head DSC buffer width, NVIDIA C671 source.
        }
        const denominator: u128 = @as(u128, input.clock.denominator) * 10_000;
        const pclk = (@as(u128, input.clock.numerator) + denominator - 1) / denominator;
        if (pclk > 400_000) return error.Unsupported;
        put(data, 12, @intCast(pclk));
        put(data, 16, input.total);
        put(data, 20, input.width);
        put(data, 24, input.bpc);
        put(data, 36, 2);
        put(data, 40, 48); //RGB and stereo LPCM48kHz.
        put(data, 56, input.receiver.max_chunk_bytes / 1024);
        return data.len;
    }
    pub fn consume(self: *Work, data: []const u8, receipt: u64) !void {
        if (receipt == 0 or receipt <= self.receipt or self.probes >= 64) return error.Stale;
        var expected: [132]u8 = undefined;
        const size = try self.encode(&expected);
        if (data.len != size) return error.Payload;
        switch (self.stage) {
            .source => {
                if (!std.mem.eql(u8, data[0..8], expected[0..8])) return error.Unexpected;
                self.source = try caps.DscSource.decode(data[36..64]);
                // Other encoder precisions need their own PCF selection;
                // silently rounding a normative primary format is forbidden.
                if (!self.source.usable or self.source.bpp_increment_x16 != 1) return error.Unsupported;
                self.stage = .layout;
            },
            .layout => {
                if (!std.mem.eql(u8, data[0..48], expected[0..48]) or !std.mem.eql(u8, data[56..128], expected[56..128]) or data[128] > 1)
                    return error.Unexpected;
                if (data[128] == 0) return error.Unsupported;
                const slices = word(data, 48);
                const width = word(data, 52);
                if (slices == 0 or slices > @min(self.source.max_slices, self.input.receiver.max_slices) or slices > 16 or
                    width == 0 or width > 2720 or (self.input.width + width - 1) / width != slices) return error.Payload;
                self.slices = @intCast(slices);
                self.slice_width = @intCast(width);
                if (self.input.fixed) |fixed| {
                    if (fixed.params.slices != self.slices or fixed.params.slice_width != self.slice_width) return error.Stale;
                    self.rate = fixed.rate;
                    self.bpp = fixed.params.bpp_x16;
                    self.search = .fixed;
                    self.stage = .capacity;
                } else self.stage = .precalc;
            },
            .precalc => {
                if (!std.mem.eql(u8, data[0..108], expected[0..108]) or !std.mem.eql(u8, data[120..], expected[120..size]) or data[116] > 1)
                    return error.Unexpected;
                if (data[116] == 1) self.stage = .preconfig else self.startSearch();
            },
            .preconfig => {
                if (!std.mem.eql(u8, data[0..108], expected[0..108]) or !std.mem.eql(u8, data[120..], expected[120..size])) return error.Unexpected;
                const rate = word(data, 108);
                if (rate == 7) self.startSearch() else {
                    if (rate == 0 or rate > @intFromEnum(self.maximum()) or word(data, 112) < 128 or word(data, 112) > self.maxBpp()) return error.Bandwidth;
                    self.rate = @enumFromInt(rate);
                    self.bpp = @intCast(word(data, 112));
                    self.search = .fixed;
                    self.stage = .capacity;
                }
            },
            .capacity => {
                if (!std.mem.eql(u8, data[0..60], expected[0..60]) or !std.mem.eql(u8, data[96..], expected[96..size])) return error.Unexpected;
                for (data[68..73]) |flag| if (flag > 1) return error.Payload;
                // RM's video/audio result is authoritative; a coding ceiling
                // or precomputed VIC alone cannot prove this exact raster.
                const possible = data[68] == 1 and data[69] == 1 and data[70] == 1 and data[71] == 1 and data[72] == 1;
                if ((word(data, 60) != 0 and word(data, 60) != @intFromEnum(self.rate)) or
                    (word(data, 64) != 0 and word(data, 64) != self.bpp)) return error.Unexpected;
                if (possible) {
                    if (self.search == .rate and self.bpp != self.maxBpp()) {
                        self.bpp = self.maxBpp();
                        self.search = .coarse;
                    } else if (self.search == .coarse and self.bpp != self.maxBpp()) {
                        self.bpp = @min(self.maxBpp(), self.bpp + 15);
                        self.search = .fine;
                    } else try self.finish(data);
                } else switch (self.search) {
                    .fixed => return error.Bandwidth,
                    .rate => {
                        if (self.rate == self.maximum()) return error.Bandwidth;
                        self.rate = @enumFromInt(@intFromEnum(self.rate) + 1);
                    },
                    .coarse, .fine => {
                        if (self.bpp == 128) return error.Bandwidth;
                        self.bpp = @max(128, self.bpp - @as(u16, if (self.search == .coarse) 16 else 1));
                    },
                }
            },
            .complete => return error.State,
        }
        self.receipt = receipt;
        self.probes += 1;
    }
    fn startSearch(self: *Work) void {
        self.rate = .lanes3_3g;
        self.bpp = 128;
        self.search = .rate;
        self.stage = .capacity;
    }
    fn finish(self: *Work, data: []const u8) !void {
        const input = self.input;
        const params = try pps(.{ .clock = input.clock, .width = input.width, .height = input.height, .hblank = input.total - input.width, .bpc = input.bpc, .source = self.source, .receiver = input.receiver, .rate = self.rate, .bpp_x16 = self.bpp, .slice_width = self.slice_width, .slices = self.slices });
        if (word(data, 80) == 0 or word(data, 80) > 65535 or word(data, 84) == 0 or word(data, 84) > 65535 or
            word(data, 88) > 65535 or word(data, 92) > 1000) return error.Payload;
        const plan: Plan = .{ .params = params, .rate = self.rate, .hc_active_bytes = @intCast(word(data, 80)), .hc_active_tri_bytes = @intCast(word(data, 84)), .hc_blank_tri_bytes = @intCast(word(data, 88)), .blank_ratio_x1k = @intCast(word(data, 92)) };
        if (input.fixed) |fixed| if (!std.meta.eql(plan, fixed)) return error.Stale;
        self.result = plan;
        self.tri_bytes_borrowed = word(data, 76);
        self.stage = .complete;
    }
};
fn put(data: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, data[at..][0..4], value, .little);
}
fn word(data: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, data[at..][0..4], .little);
}
