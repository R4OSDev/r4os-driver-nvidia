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
//! C67D HDMI FRL owner. Public570.144 interfaces: ctrl0073specific.h,
//! nvHdmiFrlCommon.h and nvhdmipkt_C671.c. RM owns the PHY and normative
//! capacity calculation. No fake training, synthesized success or MMIO.
const std = @import("std");
const boot = @import("gsp_boot_mode.zig");
const display = @import("gsp_display_rpc.zig");
const exchange = @import("gsp_exchange.zig");
const dsc = @import("gsp_hdmi_dsc.zig");
pub const links = @import("r4gfx_outputs").links;
pub const Rate = links.Frl;
pub const max_bytes = 156;
pub const Stage = enum { source, capacity, dsc, admitted, train, recheck, complete, disable, disabled };
pub const Plan = struct { object: display.Object, mode: boot.Plan, sink_max: Rate };
pub const Result = struct {
    source_max: Rate, rate: Rate, audio_48k: bool,
    tri_bytes_borrowed: u32, training_skipped: bool = false,
    training_receipt: u64 = 0,
    compressed: ?dsc.Plan = null,
    dsc_source: @import("gsp_link_caps.zig").DscSource = .{},
    capacity_receipt: u64 = 0,
};

/// TMDS remains the preferred ordinary transport. FRL is selected from a
/// complete current HDMI receiver, only when its uncompressed rate needs it.
pub fn select(saved: boot.Plan, receiver: anytype) !boot.Plan {
    var plan = saved;
    plan.signal.hdmi_frl = false; plan.frl_max_rate = 0; plan.hdmi_dsc_sink = .{};
    plan.signal.hdmi_dsc = null;
    plan.hdmi_dsc_only = false;
    if (!saved.transport_hdmi or saved.displayPort() or saved.receiver_mode_id == 0) return plan;
    if (!receiver.complete() or !receiver.hdmi) return error.Stale;
    const maximum = @min(@as(u64, 600_000_000), if (receiver.max_tmds_hz == 0) @as(u64, 165_000_000) else receiver.max_tmds_hz);
    if (links.tmdsFits(links.Clock.nvidia(saved.signal.clock), saved.signal.bpc, maximum) and
        (saved.signal.bpc == 8 or receiver.hdmi_deep_color & 1 != 0)) return plan;
    //Mode selection preserves the receiver's timing independently of source
    //admission. Without FRL facts, the ordinary TMDS owner still rejects an
    //excessive rate before commit; it must not invent extended capability.
    const caps = receiver.hdmi_links orelse return plan;
    if (caps.max_frl == .none or !receiver.scdc) return plan;
    plan.signal.hdmi_frl = true; plan.frl_max_rate = @intFromEnum(caps.max_frl);
    plan.hdmi_dsc_sink = caps.dsc;
    plan.hdmi_dsc_only = saved.signal.bpc > 8 and receiver.hdmi_deep_color & 1 == 0;
    plan.signal.hdmi_dsc = saved.signal.hdmi_dsc;
    return plan;
}
pub fn derive(saved: boot.Plan, object: display.Object) !Plan {
    try boot.validate(saved.signal, saved.head);
    if (!saved.signal.hdmi_frl or saved.displayPort() or !saved.transport_hdmi or saved.receiver_mode_id == 0) return error.Unsupported;
    if (object.epoch == 0 or object.epoch != saved.epoch or object.client == 0 or object.display == 0) return error.Stale;
    const maximum = try Rate.decode(saved.frl_max_rate);
    if (maximum == .none) return error.Unsupported;
    return .{ .object = object, .mode = saved, .sink_max = maximum };
}
fn put(bytes: []u8, offset: usize, value: u32) void { std.mem.writeInt(u32, bytes[offset..][0..4], value, .little); }
fn word(bytes: []const u8, offset: usize) u32 { return std.mem.readInt(u32, bytes[offset..][0..4], .little); }
pub const Work = struct {
    plan: Plan,
    stage: Stage = .source,
    source_max: Rate = .none,
    rate: Rate = .none,
    result: ?Result = null,
    last_status: u32 = 0,
    rpc_error: bool = false,
    training_attempted: bool = false,
    training_receipt: u64 = 0,
    training_skipped: bool = false,
    dsc_work: ?dsc.Work = null,

    pub fn active(self: *const Work) bool { return switch (self.stage) { .admitted, .complete, .disabled => false, else => true }; }
    fn fitsCoding(self: *const Work, rate: Rate) bool {
        const clock = links.Clock.nvidia(self.plan.mode.signal.clock);
        // FRL reuses horizontal blanking for active data. RM additionally
        // checks the precise blanking/packet/FEC/audio requirements.
        const total = self.plan.mode.signal.total & 0xffff;
        return clock.valid() and total > self.plan.mode.width and rate != .none and
            @as(u128, clock.numerator) * self.plan.mode.width * self.plan.mode.signal.bpc * 3 <
            @as(u128, rate.codingCeiling()) * clock.denominator * total;
    }
    fn nextRate(self: *Work) !void {
        const maximum = @min(@intFromEnum(self.source_max), @intFromEnum(self.plan.sink_max));
        var raw: u8 = @intFromEnum(self.rate) + 1;
        while (raw <= maximum) : (raw += 1) {
            const candidate = try Rate.decode(raw);
            if (self.fitsCoding(candidate)) { self.rate = candidate; self.stage = .capacity; return; }
        }
        try self.beginDsc(null);
    }
    fn beginDsc(self: *Work, fixed: ?dsc.Plan) !void {
        const mode = self.plan.mode;
        if (!mode.hdmi_dsc_sink.advertised or !mode.hdmi_dsc_sink.supported_fields) return error.Bandwidth;
        self.dsc_work = .{ .input = .{ .clock = links.Clock.nvidia(mode.signal.clock), .width = mode.width, .height = mode.height,
            .total = mode.signal.total & 0xffff, .bpc = mode.signal.bpc, .vic = mode.cta_vic,
            .receiver = mode.hdmi_dsc_sink, .maximum = @enumFromInt(@min(@intFromEnum(self.source_max), @intFromEnum(self.plan.sink_max))), .fixed = fixed } };
        self.stage = .dsc;
    }
    pub fn admittedMode(self: *const Work) !boot.Plan {
        const result = self.result orelse return error.State;
        if (self.stage != .admitted and self.stage != .complete) return error.State;
        var mode = self.plan.mode; mode.signal.hdmi_dsc = result.compressed;
        try boot.validate(mode.signal, mode.head);
        return mode;
    }
    pub fn encode(self: *const Work, out: []u8) !usize {
        if (!std.meta.eql(self.plan, try derive(self.plan.mode, self.plan.object)) or out.len < max_bytes) return error.Descriptor;
        @memset(out, 0);
        put(out, 0, self.plan.object.client); put(out, 4, self.plan.object.display);
        const data = out[24..];
        var cmd: u32 = 0;
        var size: u32 = 0;
        switch (self.stage) {
            .source => { cmd = 0x7302a2; size = 8; },
            .dsc => {
                const work = if (self.dsc_work) |*value| value else return error.State;
                cmd = work.command(); size = @intCast(try work.encode(data));
            },
            .capacity, .recheck => {
                if (!self.fitsCoding(self.rate) or @intFromEnum(self.rate) > @min(@intFromEnum(self.source_max), @intFromEnum(self.plan.sink_max))) return error.Bandwidth;
                cmd = 0x7302a8; size = 132;
                data[0] = 1; //Uncompressed video, never a precomputed VIC lookup.
                put(data, 4, self.rate.lanes()); put(data, 8, self.rate.gigabits());
                const clock = links.Clock.nvidia(self.plan.mode.signal.clock);
                const denominator: u128 = @as(u128, clock.denominator) * 10_000;
                put(data, 12, @intCast((@as(u128, clock.numerator) + denominator - 1) / denominator));
                put(data, 16, self.plan.mode.signal.total & 0xffff); put(data, 20, self.plan.mode.width);
                put(data, 24, self.plan.mode.signal.bpc); //RGB packing0, LPCM audio0.
                put(data, 36, 2); put(data, 40, 48); //The existing audio owner uses stereo48kHz.
            },
            .train, .disable => {
                if (self.stage == .train and (self.result == null or self.rate == .none)) return error.State;
                cmd = 0x73029a; size = 16;
                put(data, 4, self.plan.mode.signal.display_id);
                put(data, 8, if (self.stage == .train) @intFromEnum(self.rate) else 0);
                //bFakeLt=false, bLtSkipped=false on input, including cleanup.
            },
            else => return error.State,
        }
        put(out, 8, cmd); put(out, 16, size);
        return 24 + size;
    }
    pub fn consume(self: *Work, record: exchange.message.Record, receipt: u64) !void {
        if (receipt == 0) return error.Stale;
        var expected: [max_bytes]u8 = undefined;
        const size = try self.encode(&expected);
        const bytes = record.payload;
        self.rpc_error = record.rpc.result != 0;
        if (record.rpc.function != 76 or record.rpc.cpu_rm_gfid != 0 or bytes.len != size) return error.Payload;
        if (self.rpc_error) return error.RmRejected;
        if (!std.mem.eql(u8, bytes[0..12], expected[0..12]) or !std.mem.eql(u8, bytes[16..24], expected[16..24])) return error.Unexpected;
        self.last_status = word(bytes, 12);
        if (self.last_status != 0) return error.RmRejected;
        const data = bytes[24..];
        switch (self.stage) {
            .source => {
                if (word(data, 0) != 0) return error.Unexpected;
                self.source_max = try Rate.decode(@intCast(word(data, 4) & 7));
                if (self.source_max == .none) return error.Unsupported;
                if (self.plan.mode.signal.hdmi_dsc) |fixed| try self.beginDsc(fixed)
                else if (self.plan.mode.hdmi_dsc_only) try self.beginDsc(null) else try self.nextRate();
            },
            .dsc => {
                const work = if (self.dsc_work) |*value| value else return error.State;
                try work.consume(data, receipt);
                if (work.stage == .complete) {
                    const compressed = work.result orelse return error.State;
                    self.rate = compressed.rate;
                    self.result = .{ .source_max = self.source_max, .rate = self.rate, .audio_48k = true,
                        .tri_bytes_borrowed = work.tri_bytes_borrowed, .training_skipped = self.training_skipped,
                        .training_receipt = self.training_receipt, .compressed = compressed, .dsc_source = work.source,
                        .capacity_receipt = receipt };
                    self.stage = if (self.training_receipt == 0) .admitted else .complete;
                }
            },
            .capacity, .recheck => {
                if (!std.mem.eql(u8, data[0..60], expected[24..84])) return error.Unexpected;
                const result = data[60..96];
                for (result[8..13]) |flag| if (flag > 1) return error.Payload;
                const returned = word(result, 0);
                //Unused BPP output can be0 for uncompressed video. A
                //different explicit value must not silently change colour.
                if (word(result, 4) != 0 and word(result, 4) != @as(u32, self.plan.mode.signal.bpc) * 48) return error.Unexpected;
                if (result[8] != 0 or returned > 6) return error.Unsupported;
                if (result[9] == 0 or result[10] == 0 or result[11] == 0 or result[12] == 0 or returned == 0) {
                    if (self.stage == .recheck) return error.Bandwidth;
                    return self.nextRate();
                }
                if (returned != @intFromEnum(self.rate)) return error.Unexpected;
                self.result = .{ .source_max = self.source_max, .rate = self.rate, .audio_48k = true,
                    .tri_bytes_borrowed = word(result, 16), .training_skipped = self.training_skipped,
                    .training_receipt = self.training_receipt, .capacity_receipt = receipt };
                self.stage = if (self.stage == .capacity) .admitted else .complete;
            },
            .train, .disable => {
                if (!std.mem.eql(u8, data[0..8], expected[24..32]) or data[12] != 0 or data[13] > 1 or word(data, 8) & ~@as(u32, 7) != 0) return error.Unexpected;
                const rate = try Rate.decode(@intCast(word(data, 8)));
                if (self.stage == .disable) {
                    if (rate != .none) return error.LinkTraining;
                    self.result = null; self.rate = .none; self.stage = .disabled; return;
                }
                self.training_attempted = true;
                if (rate == .none or @intFromEnum(rate) > @min(@intFromEnum(self.source_max), @intFromEnum(self.plan.sink_max))) return error.LinkTraining;
                self.training_receipt = receipt; self.training_skipped = data[13] == 1;
                if (self.result.?.compressed) |compressed| {
                    // IMP and Core contain this exact PPS and HC raster.
                    // A different negotiated rate requires a new transaction.
                    if (rate != compressed.rate) return error.LinkTraining;
                    try self.beginDsc(compressed); return;
                }
                //Even a retained/unchanged rate gets fresh capacity admission
                //after training. bLtSkipped is recorded, not treated as LT.
                self.rate = rate; self.stage = .recheck;
                if (!self.fitsCoding(rate)) return error.Bandwidth;
            },
            else => return error.State,
        }
    }
    pub fn startTraining(self: *Work) !void {
        if (self.stage != .admitted or self.result == null) return error.State;
        self.stage = .train;
    }
    pub fn startDisable(self: *Work) void {
        self.stage = .disable; self.result = null;
    }
};
