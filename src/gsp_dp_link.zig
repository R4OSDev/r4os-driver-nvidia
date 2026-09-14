// NVIDIA 570.144 ctrl0073dp.h and displayport/src/dp_watermark.cpp.
// SPDX-FileCopyrightText: Copyright (c) 2005-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 1993-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: MIT
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
//
// GSP training sequence: Nouveau nvkm/subdev/gsp/rm/r535/disp.c.
// Copyright 2023 Red Hat Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
// OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
//! External SST / 8b10b link work. Runtime owns the exchange, deadline and
//! receiver generation. GSP performs CR/CE and the generation-specific PHY
//! programming; DPCD readback proves the selected configuration and lanes.
const std = @import("std");
const mode = @import("gsp_boot_mode.zig");
const display = @import("gsp_display_rpc.zig");
const outputs = @import("gsp_outputs.zig");
const exchange = @import("gsp_exchange.zig");
const aux = @import("gsp_aux_wire.zig");
pub const max_bytes = 108;
pub const Plan = struct { object: display.Object, mode: mode.Plan };
pub const Stage = enum { source, caps, extended_caps, repeaters, power, power_on, train, link_config, link_status, stream, mute, complete };
pub const Config = struct { rate: u8, lanes: u8 };
pub const Source = struct { rate: u8, increased_watermark: bool };
pub const Sink = struct { revision: u8, rate: u8, lanes: u8, enhanced: bool, post_adjust: bool };
pub const Stream = struct { watermark: u32, hblank: u32, vblank: u32, audio_48k: bool };
pub const Result = struct { source: Source, sink: Sink, config: Config, stream: Stream, dpcd: [16]u8, lane_status: [8]u8, attempts: u8 };
pub fn derive(saved: mode.Plan, object: display.Object, snapshot: *const outputs.Snapshot) !Plan {
    try mode.validate(saved.signal, saved.head);
    if (!saved.displayPort() or saved.transport_hdmi or saved.cta_vic != 0) return error.Unsupported;
    if (object.client == 0 or object.display == 0 or object.epoch != saved.epoch or object.client != snapshot.topology.client or
        !std.meta.eql(saved, try mode.bind(saved, snapshot, saved.epoch, saved.held_generation))) return error.Stale;
    for (snapshot.receivers[0..snapshot.count]) |*receiver| if (receiver.display_id == saved.signal.display_id) {
        if (receiver.connected != true or receiver.status != .valid_edid or !receiver.report.complete()) return error.Stale;
        if (!receiver.report.digital or receiver.report.colors & 1 == 0) return error.Unsupported;
        return .{ .object = object, .mode = saved };
    };
    return error.Stale;
}
pub fn receiverCaps(bytes: [16]u8) !Sink {
    if ((bytes[0] < 0x10 or bytes[0] > 0x14) and bytes[0] != 0x20 or bytes[6] & 1 == 0) return error.Unsupported;
    const lanes = bytes[2] & 31;
    if (lanes != 1 and lanes != 2 and lanes != 4) return error.Unsupported;
    var rate = bytes[1];
    if (!validRate(rate)) return error.Unsupported;
    // HBR3 requires TPS4. A missing capability grants only the lower rates.
    if (rate == 0x1e and bytes[3] & 0x80 == 0) rate = 0x14;
    return .{ .revision = bytes[0], .rate = rate, .lanes = lanes, .enhanced = bytes[2] & 0x80 != 0,
        .post_adjust = bytes[2] & 0x20 != 0 and bytes[3] & 0x80 == 0 };
}
fn validRate(rate: u8) bool { return rate == 6 or rate == 10 or rate == 20 or rate == 30; }
fn clockHz(saved: mode.Plan) u64 {
    const nominal: u64 = saved.signal.clock & 0x7fffffff;
    // Round upward for conservative bandwidth and TU arithmetic.
    return if (saved.signal.clock >> 31 != 0) (nominal * 1000 + 1000) / 1001 else nominal;
}
pub fn stream(saved: mode.Plan, source: Source, sink: Sink, config: Config) !Stream {
    if (!validRate(config.rate) or config.rate > source.rate or config.rate > sink.rate or
        (config.lanes != 1 and config.lanes != 2 and config.lanes != 4) or config.lanes > sink.lanes) return error.Unsupported;
    const pclk = clockHz(saved);
    const width: u64 = saved.width;
    const raster: u64 = saved.signal.total & 0xffff;
    const lanes: u64 = config.lanes;
    const link: u64 = @as(u64, config.rate) * 27_000_000; // 8 payload bits per 10-bit symbol.
    if (!saved.displayPort() or saved.transport_hdmi or pclk == 0 or width <= 60 or raster <= width or pclk * 24 >= 8 * link * lanes)
        return error.Bandwidth;
    const precision = 100_000;
    const ratio = pclk * 24 * precision / (8 * link * lanes);
    const watermark_fraction = ratio * 64 * (precision - ratio) / precision;
    const adjust: u64 = if (source.increased_watermark) 8 else 2;
    const minimum: u64 = if (source.increased_watermark) 22 else 20;
    const watermark = @max(minimum, adjust + (2 * (24 * precision / (8 * lanes)) + watermark_fraction) / precision);
    if (watermark > 39 or watermark > width * 24 / (8 * lanes)) return error.Bandwidth;
    const steering: u64 = if (width % lanes != 0) (lanes - width % lanes) * 24 else 0;
    const blank_bits = 24 * lanes * @as(u64, if (sink.enhanced) 2 else 1) + 96 + steering;
    const min_blank = (blank_bits * precision / (8 * lanes)) * pclk / link / precision + 12;
    if (min_blank > raster - width) return error.Bandwidth;
    const hblank = ((raster - width - min_blank) * link / pclk) -| (4 + @as(u64, if (lanes == 1) 9 else if (lanes == 2) 6 else 3));
    const vblank = ((width - 40) * link / pclk) -| (1 + @as(u64, if (lanes == 1) 39 else if (lanes == 2) 21 else 12));
    const available = ((hblank * lanes) -| (4 * lanes + 8)) / 20;
    const required = (48_000 * raster + pclk * 2 - 1) / (pclk * 2);
    return .{ .watermark = @intCast(watermark), .hblank = @intCast(hblank), .vblank = @intCast(vblank), .audio_48k = available >= required };
}
pub fn trained(status: [8]u8, lanes: u8) bool {
    if (lanes != 1 and lanes != 2 and lanes != 4) return false;
    if (status[0] & 0xbf == 0 or status[4] & 1 == 0) return false;
    for (0..lanes) |lane| {
        const shift: u3 = @intCast((lane & 1) * 4);
        if ((status[2 + lane / 2] >> shift) & 7 != 7) return false;
    }
    return true;
}
fn put(bytes: []u8, offset: usize, value: u32) void { std.mem.writeInt(u32, bytes[offset..][0..4], value, .little); }
fn word(bytes: []const u8, offset: usize) u32 { return std.mem.readInt(u32, bytes[offset..][0..4], .little); }
pub const Work = struct {
    plan: Plan,
    stage: Stage = .source,
    source: ?Source = null,
    sink: ?Sink = null,
    candidates: [12]Config = @splat(.{ .rate = 0, .lanes = 0 }),
    count: u8 = 0,
    index: u8 = 0,
    attempts: u8 = 0,
    retries: u8 = 0,
    not_before: u64 = 0,
    power_value: u8 = 1,
    dpcd: [16]u8 = @splat(0),
    status: [8]u8 = @splat(0),
    result: ?Result = null,
    last_rm_status: u32 = 0,
    last_train_error: u32 = 0,
    last_aux_reply: ?aux.ReplyType = null,

    pub fn ready(self: *const Work, now: u64) bool { return self.stage != .complete and now >= self.not_before; }
    fn request(self: *const Work) ?aux.Request {
        const operation: aux.Operation = switch (self.stage) {
            .caps => .caps, .extended_caps => .extended_caps, .repeaters => .repeaters, .power => .power,
            .power_on => .{ .power_on = self.power_value }, .link_config => .link_config, .link_status => .link_status,
            else => return null,
        };
        return .{ .display_id = self.plan.mode.signal.display_id, .operation = operation };
    }
    pub fn encode(self: *const Work, out: []u8) !usize {
        try mode.validate(self.plan.mode.signal, self.plan.mode.head);
        if (!self.plan.mode.displayPort() or self.plan.object.epoch == 0 or self.plan.object.epoch != self.plan.mode.epoch or
            self.plan.object.client == 0 or self.plan.object.display == 0 or out.len < max_bytes) return error.Descriptor;
        @memset(out, 0);
        put(out, 0, self.plan.object.client); put(out, 4, self.plan.object.display);
        var command: u32 = 0;
        var size: u32 = 0;
        const params = out[24..];
        if (self.request()) |query| {
            command = aux.command; size = aux.bytes;
            put(out, 20, aux.rpc_flags);
            _ = try aux.encode(query, params);
        } else switch (self.stage) {
            .source => { command = 0x731369; size = 64; put(params, 4, self.plan.mode.signal.sor); },
            .train => {
                if (self.index >= self.count or self.count > self.candidates.len or self.sink == null) return error.State;
                const config = self.candidates[self.index];
                command = 0x731343; size = 28;
                put(out, 20, 1); // COPYOUT_ON_ERROR: retryTimeMs is valid on BUSY/NOT_READY.
                put(params, 4, self.plan.mode.signal.display_id);
                put(params, 8, 3 | (1 << 13) | @as(u32, if (self.sink.?.enhanced) 128 else 0) |
                    @as(u32, if (self.sink.?.post_adjust) 1 << 10 else 0));
                put(params, 12, config.lanes | (@as(u32, config.rate) << 8)); // SST, sink target 0; never fake/skip training.
            },
            .stream => {
                const value = try stream(self.plan.mode, self.source.?, self.sink.?, self.candidates[self.index]);
                command = 0x731362; size = 84;
                put(params, 4, self.plan.mode.head); put(params, 8, self.plan.mode.signal.sor);
                put(params, 12, @intFromBool((self.plan.mode.signal.sor_control >> 8) & 15 == 9));
                params[16] = 1; // Override only this SST head/SOR. MST and the second panel remain zero.
                put(params, 24, value.hblank); put(params, 28, value.vblank);
                params[68] = @intFromBool(self.sink.?.enhanced);
                put(params, 72, 64); put(params, 76, value.watermark);
            },
            .mute => { command = 0x731359; size = 12; put(params, 4, self.plan.mode.signal.display_id); put(params, 8, 1); },
            else => return error.State,
        }
        put(out, 8, command); put(out, 16, size);
        return 24 + size;
    }
    fn retry(self: *Work, now: u64, delay_ms: u32) !void {
        // At most three requests per operation; never sleep in the owner.
        if (delay_ms == 0 or delay_ms > 500 or self.retries >= 2) return error.RetryExhausted;
        self.retries += 1;
        self.not_before = now +| (@as(u64, delay_ms) * std.time.ns_per_ms);
    }
    fn fallback(self: *Work) !void {
        if (self.index + 1 >= self.count) return error.LinkTraining;
        self.index += 1; self.retries = 0; self.not_before = 0; self.stage = .train;
    }
    fn select(self: *Work) !void {
        self.count = 0;
        for ([_]u8{ 30, 20, 10, 6 }) |rate| for ([_]u8{ 4, 2, 1 }) |lanes| {
            const config: Config = .{ .rate = rate, .lanes = lanes };
            _ = stream(self.plan.mode, self.source.?, self.sink.?, config) catch continue;
            self.candidates[self.count] = config; self.count += 1;
        };
        if (self.count == 0) return error.Bandwidth;
        self.stage = if (self.sink.?.revision >= 0x11) .power else .train;
    }
    pub fn consume(self: *Work, record: exchange.message.Record, now: u64) !void {
        var expected: [max_bytes]u8 = undefined;
        const length = try self.encode(&expected);
        const bytes = record.payload;
        if (record.rpc.function != 76 or record.rpc.cpu_rm_gfid != 0) return error.Unexpected;
        if (record.rpc.result != 0) return error.RmRejected;
        if (bytes.len != length) return error.Payload;
        if (!std.mem.eql(u8, bytes[0..12], expected[0..12]) or !std.mem.eql(u8, bytes[16..24], expected[16..24])) return error.Unexpected;
        const status = word(bytes, 12);
        self.last_rm_status = status;
        const data = bytes[24..];
        if (self.request()) |query| {
            const reply = try aux.decode(query, status, data);
            self.last_aux_reply = reply.kind;
            if ((status == 3 or status == 0x66) and reply.retry_ms != 0) return self.retry(now, reply.retry_ms);
            if (status != 0) return error.RmRejected;
            if (reply.kind == .defer_reply) return self.retry(now, 1);
            // A direct pre-LTTPR receiver may explicitly NACK this optional
            // range. Timeout or unknown response must not invent no repeater.
            if (self.stage == .repeaters and reply.kind == .nack) { try self.select(); return; }
            if (reply.kind != .ack or reply.count != aux.length(query.operation)) return error.Aux;
            self.retries = 0; self.not_before = 0;
            switch (self.stage) {
                .caps => {
                    self.sink = try receiverCaps(reply.data);
                    self.dpcd = reply.data;
                    self.stage = if (reply.data[14] & 0x80 != 0) .extended_caps else .repeaters;
                },
                .extended_caps => { self.sink = try receiverCaps(reply.data); self.dpcd = reply.data; self.stage = .repeaters; },
                .repeaters => {
                    // Non-transparent repeaters and tunnel/branch topology
                    // are not implied by a working AUX/EDID transaction.
                    if (reply.data[2] != 0) return error.Unsupported;
                    try self.select();
                },
                .power => { self.power_value = (reply.data[0] & ~@as(u8, 7)) | 1; self.stage = .power_on; },
                .power_on => { self.stage = .train; self.not_before = now +| std.time.ns_per_ms; },
                .link_config => {
                    const config = self.candidates[self.index];
                    if (reply.data[0] != config.rate or reply.data[1] & 31 != config.lanes or
                        (reply.data[1] & 0x80 != 0) != self.sink.?.enhanced) return self.fallback();
                    self.stage = .link_status;
                },
                .link_status => {
                    @memcpy(&self.status, reply.data[0..8]);
                    if (!trained(self.status, self.candidates[self.index].lanes)) return self.fallback();
                    self.stage = .stream;
                },
                else => return error.State,
            }
        } else {
            switch (self.stage) {
                .source => {
                    if (status != 0) return error.RmRejected;
                    if (!std.mem.eql(u8, data[0..8], expected[24..32]) or word(data, 8) < 1 or word(data, 8) > 4 or
                        data[26] > 1 or data[30] != 1) return error.Unsupported;
                    const rates = [_]u8{ 6, 10, 20, 30 };
                    self.source = .{ .rate = rates[word(data, 8) - 1], .increased_watermark = data[26] == 1 };
                    self.stage = .caps;
                },
                .train => {
                    if (!std.mem.eql(u8, data[0..16], expected[24..40]) or word(data, 24) != 0) return error.Unexpected;
                    self.last_train_error = word(data, 16);
                    if ((status == 3 or status == 0x66) and word(data, 20) != 0) return self.retry(now, word(data, 20));
                    self.attempts += 1;
                    if (status != 0) return error.RmRejected;
                    if (self.last_train_error != 0) return self.fallback();
                    self.stage = .link_config;
                },
                .stream, .mute => {
                    if (status != 0) return error.RmRejected;
                    if (!std.mem.eql(u8, data, expected[24..length])) return error.Unexpected;
                    if (self.stage == .stream) { self.stage = .mute; } else {
                        self.result = .{ .source = self.source.?, .sink = self.sink.?, .config = self.candidates[self.index],
                            .stream = try stream(self.plan.mode, self.source.?, self.sink.?, self.candidates[self.index]),
                            .dpcd = self.dpcd, .lane_status = self.status, .attempts = self.attempts };
                        self.stage = .complete;
                    }
                },
                else => return error.State,
            }
            self.retries = 0; self.not_before = 0;
        }
    }
};
