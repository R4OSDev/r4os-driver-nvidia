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
const signal_color = @import("gsp_color_signal.zig");
pub const link_caps = @import("gsp_link_caps.zig");
const dsc = @import("gsp_dsc.zig");
const fec = @import("gsp_dp_watermark.zig");
pub const max_bytes = 108;
pub const Plan = struct { object: display.Object, mode: mode.Plan, receiver: ?signal_color.Receiver = null };
pub const Stage = enum { source, caps, extended_caps, repeaters, power, power_on, train, link_config, link_status, stream, mute, complete,
    color_caps, vsc, hdr, post_complete, dsc_caps, fec_caps, mst_caps,
    fec_clear, fec_enable, fec_status, dsc_enable, dsc_verify };
pub const Config = struct { rate: u8, lanes: u8 };
pub const Source = link_caps.DpSource;
pub const Sink = struct { revision: u8, rate: u8, lanes: u8, enhanced: bool, post_adjust: bool };
pub const Stream = struct { watermark: u32, hblank: u32, vblank: u32, audio_48k: bool };
pub const Result = struct { source: Source, sink: Sink, config: Config, stream: Stream, dpcd: [16]u8, lane_status: [8]u8, attempts: u8,
    receiver_caps: link_caps.DpReceiver = .{}, compressed: ?dsc.DpPlan = null, fec_receipt: u64 = 0, decoder_receipt: u64 = 0,
    pub fn complete(self: Result, saved: mode.Plan) bool {
        if (!std.meta.eql(self.compressed, saved.signal.dp_dsc) or !trained(self.lane_status, self.config.lanes)) return false;
        if (self.compressed) |value| return self.fec_receipt != 0 and self.decoder_receipt > self.fec_receipt and
            value.rate == self.config.rate and value.lanes == self.config.lanes;
        return self.fec_receipt == 0 and self.decoder_receipt == 0;
    }
};
pub fn derive(saved: mode.Plan, object: display.Object, snapshot: *const outputs.Snapshot) !Plan {
    try mode.validate(saved.signal, saved.head);
    try signal_color.validate(saved);
    if (!saved.displayPort() or saved.signal.mst != null or saved.transport_hdmi or saved.cta_vic != 0) return error.Unsupported;
    if (object.client == 0 or object.display == 0 or object.epoch != saved.epoch or object.client != snapshot.topology.client or
        !std.meta.eql(saved, try mode.bind(saved, snapshot, saved.epoch, saved.held_generation))) return error.Stale;
    for (snapshot.receivers[0..snapshot.count]) |*receiver| if (receiver.display_id == saved.signal.display_id) {
        if (receiver.connected != true or receiver.status != .valid_edid or !receiver.report.complete()) return error.Stale;
        if (!receiver.report.digital or receiver.report.colors & 1 == 0) return error.Unsupported;
        try @import("gsp_dp_mode.zig").validate(saved,receiver);
        // Preflight only against the implementation's HBR3x4 ceiling.
        // No color plan is installed until source/DPCD capabilities and
        // the actually trained configuration pass admission again.
        const compressed=saved.signal.dp_dsc;
        _ = try signal_color.admit(saved, &receiver.report, .{ .displayport = .{
            .payload_bits_per_second = if(compressed) |value| try @import("gsp_dp_watermark.zig").payload(value.rate,value.lanes) else 25_920_000_000,
            .compressed_bpp_x16 = if (compressed) |value| value.params.bpp_x16 else 0,
            .compressed_bpc = if (compressed != null) saved.signal.bpc else 0, .vsc = true, .hdr_sdp = true } });
        return .{ .object = object, .mode = saved, .receiver = if (saved.color != null) signal_color.Receiver.capture(receiver.report) else null };
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
    return signal_color.clockHz(saved);
}
pub fn stream(saved: mode.Plan, source: Source, sink: Sink, config: Config) !Stream {
    if (!validRate(config.rate) or config.rate > source.rate or config.rate > sink.rate or
        (config.lanes != 1 and config.lanes != 2 and config.lanes != 4) or config.lanes > sink.lanes) return error.Unsupported;
    if (saved.signal.dp_dsc) |value| {
        if (!source.dp14 or !source.fec or !source.dsc.usable or config.rate != value.rate or config.lanes != value.lanes)
            return error.Bandwidth;
        const params = value.params;
        const result = try fec.withFec(.{ .clock = signal_color.links.Clock.nvidia(saved.signal.clock),
            .width = saved.width, .total = saved.signal.total & 0xffff, .bpp_x16 = params.bpp_x16,
            .rate = config.rate, .lanes = config.lanes, .enhanced = sink.enhanced, .increased = source.increased_watermark,
            .compression = .{ .count = params.slices, .width = params.slice_width, .chunk_bytes = params.chunk_bytes } });
        return .{ .watermark = result.watermark, .hblank = result.hblank, .vblank = result.vblank, .audio_48k = result.audio_48k };
    }
    const pclk = clockHz(saved);
    const width: u64 = saved.width;
    const raster: u64 = saved.signal.total & 0xffff;
    const lanes: u64 = config.lanes;
    const link: u64 = @as(u64, config.rate) * 27_000_000; // 8 payload bits per 10-bit symbol.
    const bpp: u64 = @as(u64, saved.signal.bpc) * 3;
    const demand = try signal_color.links.rgbDemand(signal_color.links.Clock.nvidia(saved.signal.clock), saved.signal.bpc);
    if ((saved.signal.bpc != 8 and saved.signal.bpc != 10) or !saved.displayPort() or saved.transport_hdmi or pclk == 0 or width <= 60 or raster <= width or
        !demand.fits(try signal_color.links.dp8b10bPayload(config.rate, config.lanes)))
        return error.Bandwidth;
    const precision = 100_000;
    const ratio = pclk * bpp * precision / (8 * link * lanes);
    const watermark_fraction = ratio * 64 * (precision - ratio) / precision;
    const adjust: u64 = if (source.increased_watermark) 8 else 2;
    const minimum: u64 = if (source.increased_watermark) 22 else 20;
    const watermark = @max(minimum, adjust + (2 * (bpp * precision / (8 * lanes)) + watermark_fraction) / precision);
    if (watermark > 39 or watermark > width * bpp / (8 * lanes)) return error.Bandwidth;
    const steering: u64 = if (width % lanes != 0) (lanes - width % lanes) * bpp else 0;
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
    receiver_caps: link_caps.DpReceiver = .{},
    status: [8]u8 = @splat(0),
    result: ?Result = null,
    vsc_supported: bool = false,
    color: ?signal_color.color.Plan = null,
    last_rm_status: u32 = 0,
    last_train_error: u32 = 0,
    last_aux_reply: ?aux.ReplyType = null,
    fec_receipt: u64 = 0,
    decoder_receipt: u64 = 0,
    fec_polls: u8 = 0,

    pub fn mutating(self: *const Work) bool {
        return switch (self.stage) { .power_on, .train, .stream, .mute, .vsc, .hdr,
            .fec_clear, .fec_enable, .dsc_enable => true, else => false };
    }

    pub fn ready(self: *const Work, now: u64) bool { return self.stage != .complete and self.stage != .post_complete and now >= self.not_before; }
    pub fn scanoutComplete(self: *Work) !void {
        if (self.stage != .complete or self.result == null) return error.State;
        self.stage = .vsc;
    }
    fn request(self: *const Work) ?aux.Request {
        const operation: aux.Operation = switch (self.stage) {
            .caps => .caps, .extended_caps => .extended_caps, .color_caps => .color_caps,
            .dsc_caps => .dsc_caps, .fec_caps => .fec_caps, .mst_caps => .mst_caps, .repeaters => .repeaters, .power => .power,
            .power_on => .{ .power_on = self.power_value }, .link_config => .link_config, .link_status => .link_status,
            .fec_clear => .fec_clear, .fec_status => .fec_status,
            .dsc_enable => .{ .dsc_enable = true }, .dsc_verify => .dsc_control,
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
                    @as(u32, if (self.sink.?.post_adjust) 1 << 10 else 0) |
                    @as(u32, if (self.plan.mode.signal.dp_dsc != null) 1 << 15 else 0));
                put(params, 12, config.lanes | (@as(u32, config.rate) << 8)); // SST, sink target 0; never fake/skip training.
            },
            .stream => {
                const value = try stream(self.plan.mode, self.source.?, self.sink.?, self.candidates[self.index]);
                if (self.plan.mode.color != null) _ = try self.admitColor(self.candidates[self.index]);
                command = 0x731362; size = 84;
                put(params, 4, self.plan.mode.head); put(params, 8, self.plan.mode.signal.sor);
                put(params, 12, @intFromBool((self.plan.mode.signal.sor_control >> 8) & 15 == 9));
                params[16] = 1; // Override only this SST head/SOR. MST and the second panel remain zero.
                put(params, 24, value.hblank); put(params, 28, value.vblank);
                params[68] = @intFromBool(self.sink.?.enhanced);
                put(params, 72, 64); put(params, 76, value.watermark);
            },
            .fec_enable => {
                if (self.plan.mode.signal.dp_dsc == null or !trained(self.status, self.candidates[self.index].lanes)) return error.State;
                command = 0x73137a; size = 12; put(params, 4, self.plan.mode.signal.display_id); params[8] = 1;
            },
            .mute => { command = 0x731359; size = 12; put(params, 4, self.plan.mode.signal.display_id); put(params, 8, 1); },
            .vsc => {
                if (self.result == null) return error.State;
                put(params, 4, self.plan.mode.signal.display_id);
                if (self.plan.mode.signal.dp_vsc) {
                    if (!self.vsc_supported or self.color == null) return error.Unsupported;
                    command = 0x730288; size = 60;
                    put(params, 8, 1); put(params, 12, 23); // Generic0, every vblank.
                    params[21..57].* = try signal_color.color.dpVsc(self.plan.mode.color.?);
                } else {
                    command = 0x730289; size = 16;
                    put(params, 8, 7); // Disable inherited VSC/Generic0; MSA uses ordinary RGB.
                }
            },
            .hdr => {
                if (self.result == null) return error.State;
                const enabled = self.color != null and !self.color.?.clear_hdr;
                command = 0x730288; size = 60;
                put(params, 4, self.plan.mode.signal.display_id);
                put(params, 8, if (enabled) 0x101 else 0x105); // Generic1, HDR repeated / SDR once.
                put(params, 12, 32); // HB4 + DB2 +26-byte static metadata, as NVIDIA's SDP sender.
                params[21..57].* = if (enabled) self.color.?.metadata else signal_color.color.dpSdrMetadata();
            },
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
        if (self.plan.mode.signal.dp_dsc) |value| {
            // IMP admitted this exact PPS/rate/lane combination. A lower
            // training fallback needs fresh mode admission, not a silent
            // compression ratio change while the old Core is still live.
            if (!self.source.?.fec or self.receiver_caps.fec_state != .complete or !self.receiver_caps.fec or
                self.receiver_caps.dsc_state != .complete or !self.receiver_caps.dsc.usable) return error.Bandwidth;
            const saved = self.plan.mode;
            const fresh = try dsc.generate(.{ .clock = signal_color.links.Clock.nvidia(saved.signal.clock),
                .width = saved.width, .height = saved.height, .bpc = saved.signal.bpc,
                .hblank = (saved.signal.total & 0xffff) - saved.width, .source = self.source.?.dsc,
                .sink = self.receiver_caps.dsc, .payload_bps = try fec.payload(value.rate, value.lanes),
                .rate = value.rate, .lanes = value.lanes });
            if (!std.meta.eql(fresh, value.params)) return error.Stale;
        }
        for ([_]u8{ 30, 20, 10, 6 }) |rate| for ([_]u8{ 4, 2, 1 }) |lanes| {
            const config: Config = .{ .rate = rate, .lanes = lanes };
            _ = stream(self.plan.mode, self.source.?, self.sink.?, config) catch continue;
            if (self.plan.mode.color != null) _ = self.admitColor(config) catch continue;
            self.candidates[self.count] = config; self.count += 1;
        };
        if (self.count == 0) return error.Bandwidth;
        self.stage = if (self.sink.?.revision >= 0x11) .power else self.trainingStart();
    }
    fn trainingStart(self: *const Work) Stage { return if (self.plan.mode.signal.dp_dsc != null) .fec_clear else .train; }
    fn admitColor(self: *const Work, config: Config) !?signal_color.color.Plan {
        const receiver = self.plan.receiver orelse return error.Stale;
        const capabilities = self.source orelse return error.State;
        return try signal_color.admit(self.plan.mode, receiver, .{ .displayport = .{
            .payload_bits_per_second = if (self.plan.mode.signal.dp_dsc != null) try fec.payload(config.rate, config.lanes)
                else @as(u64, config.rate) * 27_000_000 * 8 * config.lanes,
            .compressed_bpp_x16 = if (self.plan.mode.signal.dp_dsc) |value| value.params.bpp_x16 else 0,
            .compressed_bpc = if (self.plan.mode.signal.dp_dsc != null) self.plan.mode.signal.bpc else 0,
            .vsc = self.vsc_supported and capabilities.dp14, .hdr_sdp = capabilities.dp14 } });
    }
    fn afterCaps(self: *Work) void {
        if (self.source.?.mst) { self.stage = .mst_caps; return; }
        self.afterMst();
    }
    fn afterMst(self: *Work) void {
        if (self.source.?.dp14 and self.source.?.dsc.advertised) { self.stage = .dsc_caps; return; }
        self.afterDsc();
    }
    fn afterDsc(self: *Work) void {
        if (self.source.?.dp14 and self.source.?.fec) { self.stage = .fec_caps; return; }
        self.afterExtended();
    }
    fn afterExtended(self: *Work) void {
        self.stage = if (self.plan.mode.signal.dp_vsc) .color_caps else .repeaters;
    }
    fn optionalUnavailable(self: *Work) void {
        switch (self.stage) {
            .mst_caps => { self.receiver_caps.mst_state = .unavailable; self.afterMst(); },
            .dsc_caps => { self.receiver_caps.dsc_state = .unavailable; self.afterDsc(); },
            .fec_caps => { self.receiver_caps.fec_state = .unavailable; self.afterExtended(); },
            else => unreachable,
        }
        self.retries = 0; self.not_before = 0;
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
            if (self.stage == .mst_caps or self.stage == .dsc_caps or self.stage == .fec_caps) {
                // Optional extended discovery cannot withdraw a sound SST
                // mode. Failed reads remain explicitly unavailable, never
                // a positive capability or a fabricated all-zero capture.
                if (((status == 3 or status == 0x66) and reply.retry_ms != 0) or (status == 0 and reply.kind == .defer_reply)) {
                    self.retry(now, if (status != 0) reply.retry_ms else 1) catch self.optionalUnavailable();
                    return;
                }
                if (status != 0 or reply.kind != .ack or reply.count != aux.length(query.operation)) {
                    self.optionalUnavailable(); return;
                }
            }
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
                    if (reply.data[14] & 0x80 != 0) { self.stage = .extended_caps; } else self.afterCaps();
                },
                .extended_caps => { self.sink = try receiverCaps(reply.data); self.dpcd = reply.data; self.afterCaps(); },
                .mst_caps => {
                    self.receiver_caps.mst_state = .complete; self.receiver_caps.mst = reply.data[0] & 1 != 0;
                    self.afterMst();
                },
                .dsc_caps => {
                    self.receiver_caps.dsc = link_caps.DscSink.decode(reply.data);
                    self.receiver_caps.dsc_state = if (self.receiver_caps.dsc.advertised and !self.receiver_caps.dsc.usable) .invalid else .complete;
                    self.afterDsc();
                },
                .fec_caps => {
                    self.receiver_caps.fec_state = .complete; self.receiver_caps.fec = reply.data[0] & 1 != 0;
                    self.afterExtended();
                },
                .color_caps => {
                    self.vsc_supported = reply.data[0] & 8 != 0;
                    if (!self.vsc_supported or !self.source.?.dp14) return error.Unsupported;
                    self.stage = .repeaters;
                },
                .repeaters => {
                    // Non-transparent repeaters and tunnel/branch topology
                    // are not implied by a working AUX/EDID transaction.
                    if (reply.data[2] != 0) return error.Unsupported;
                    try self.select();
                },
                .power => { self.power_value = (reply.data[0] & ~@as(u8, 7)) | 1; self.stage = .power_on; },
                .power_on => { self.stage = self.trainingStart(); self.not_before = now +| std.time.ns_per_ms; },
                .fec_clear => self.stage = .train,
                .fec_status => {
                    if (reply.data[0] & 1 == 0) {
                        if (self.fec_polls >= 2) return error.LinkTraining;
                        self.fec_polls += 1; self.not_before = now +| std.time.ns_per_ms; return;
                    }
                    self.stage = .dsc_enable;
                },
                .dsc_enable => self.stage = .dsc_verify,
                .dsc_verify => {
                    if (reply.data[0] & 3 != 1) return error.LinkTraining;
                    self.stage = .stream;
                },
                .link_config => {
                    const config = self.candidates[self.index];
                    if (reply.data[0] != config.rate or reply.data[1] & 31 != config.lanes or
                        (reply.data[1] & 0x80 != 0) != self.sink.?.enhanced) return self.fallback();
                    self.stage = .link_status;
                },
                .link_status => {
                    @memcpy(&self.status, reply.data[0..8]);
                    if (!trained(self.status, self.candidates[self.index].lanes)) return self.fallback();
                    self.stage = if (self.plan.mode.signal.dp_dsc != null) .fec_enable else .stream;
                },
                else => return error.State,
            }
        } else {
            switch (self.stage) {
                .source => {
                    if (status != 0) return error.RmRejected;
                    if (!std.mem.eql(u8, data[0..8], expected[24..32])) return error.Unexpected;
                    self.source = try Source.decode(data);
                    if (self.plan.mode.signal.dp_vsc and !self.source.?.dp14) return error.Unsupported;
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
                .fec_enable, .stream, .mute, .vsc, .hdr => {
                    if (status != 0) return error.RmRejected;
                    if (!std.mem.eql(u8, data, expected[24..length])) return error.Unexpected;
                    if (self.stage == .fec_enable) { self.stage = .fec_status; }
                    else if (self.stage == .stream) { self.stage = .mute; }
                    else if (self.stage == .vsc) { self.stage = .hdr; }
                    else if (self.stage == .hdr) { self.stage = .post_complete; }
                    else {
                        self.color = if (self.plan.mode.color != null) try self.admitColor(self.candidates[self.index]) else null;
                        self.result = .{ .source = self.source.?, .sink = self.sink.?, .config = self.candidates[self.index],
                            .stream = try stream(self.plan.mode, self.source.?, self.sink.?, self.candidates[self.index]),
                            .dpcd = self.dpcd, .lane_status = self.status, .attempts = self.attempts, .receiver_caps = self.receiver_caps,
                            .compressed = self.plan.mode.signal.dp_dsc, .fec_receipt = self.fec_receipt, .decoder_receipt = self.decoder_receipt };
                        self.stage = .complete;
                    }
                },
                else => return error.State,
            }
            self.retries = 0; self.not_before = 0;
        }
    }
};
