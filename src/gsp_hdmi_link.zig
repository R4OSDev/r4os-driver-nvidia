// HDMI protocol/packet reference notices; original R4OS ownership policy is Apache-2.0.
// ExFiles/Reference/GFX/Nvidia/OpenKernelModules-570.144/src/common/sdk/nvidia/inc/ctrl/ctrl0073/ctrl0073specific.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 1993-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//  */
// ExFiles/Reference/GFX/Nvidia/OpenKernelModules-570.144/src/nvidia/generated/g_rpc-structures.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2008-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//  */
// ExFiles/Reference/GFX/Nvidia/OpenKernelModules-570.144/src/common/modeset/timing/nvtiming.h
// //****************************************************************************
// //
// //  SPDX-FileCopyrightText: Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// //  SPDX-License-Identifier: MIT
// //
// //  Permission is hereby granted, free of charge, to any person obtaining a
// //  copy of this software and associated documentation files (the "Software"),
// //  to deal in the Software without restriction, including without limitation
// //  the rights to use, copy, modify, merge, publish, distribute, sublicense,
// //  and/or sell copies of the Software, and to permit persons to whom the
// //  Software is furnished to do so, subject to the following conditions:
// //
// //  The above copyright notice and this permission notice shall be included in
// //  all copies or substantial portions of the Software.
// //
// //  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// //  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// //  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// //  THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// //  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// //  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// //  DEALINGS IN THE SOFTWARE.
// //
// ExFiles/Reference/GFX/Nvidia/OpenKernelModules-570.144/src/common/inc/hdmi_spec.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 1993-2019 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//  */
// ExFiles/Reference/GFX/Nvidia/Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/gsp/rm/r535/disp.c
// /*
//  * Copyright 2023 Red Hat Inc.
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
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//  * THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
//  * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
//  * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  * OTHER DEALINGS IN THE SOFTWARE.
//  */
//! HDMI RM controls belong to the retained display transaction. No I/O here:
//! the runtime owns sequencing/ACKs and Device admits each exact request.
const std = @import("std");
const mode = @import("gsp_boot_mode.zig");
const outputs = @import("gsp_outputs.zig");
const display = @import("gsp_display_rpc.zig");
const exchange = @import("gsp_exchange.zig");
pub const function: u32 = 76;
pub const max_bytes = 84;
pub const Operation = enum { caps, enable, audio_mute, avi, vsi, hdr_disable, gcp };
pub const Phase = enum { before_scanout, scanout, after_scanout, complete };
pub const Plan = struct {
    object: display.Object,
    mode: mode.Plan,
    caps: u32 = 0,
    max_tmds_hz: u64 = 0,
    receiver_known: bool = false,
    hdmi_vic: u8 = 0,
};
pub const Work = struct {
    plan: Plan,
    phase: Phase = .before_scanout,
    operation: Operation = .caps,
    pending: bool = false,
    acknowledged: u8 = 0,
    last_receipt: u64 = 0,
    last_status: ?u32 = null,
    rpc_error: bool = false,
    request: [max_bytes]u8 = @splat(0),
    length: usize = 0,

    pub fn afterAck(self: *Work, serial: u64) !void {
        if (!self.pending or serial == 0 or serial <= self.last_receipt) return error.Stale;
        self.last_receipt = serial;
        self.acknowledged += 1;
        self.pending = false;
        switch (self.operation) {
            .caps => self.operation = .enable,
            .enable => if (self.plan.mode.transport_hdmi) { self.operation = .audio_mute; } else { self.phase = .scanout; },
            .audio_mute => self.phase = .scanout,
            .avi => self.operation = .vsi,
            .vsi => self.operation = .hdr_disable,
            .hdr_disable => self.operation = .gcp,
            .gcp => self.phase = .complete,
        }
    }
    pub fn scanoutComplete(self: *Work) !void {
        if (self.phase != .scanout or self.pending or self.acknowledged != @as(u8, if (self.plan.mode.transport_hdmi) 3 else 2)) return error.State;
        self.phase = if (self.plan.mode.transport_hdmi) .after_scanout else .complete;
        self.operation = .avi;
    }
    pub fn matches(self: *const Work, channel: *const exchange.Exchange, deadline: u64) bool {
        if (!self.pending or (self.phase != .before_scanout and self.phase != .after_scanout) or
            channel.phase != .prepared or channel.deadline != deadline or channel.function != function or
            channel.request.ptr != self.request[0..].ptr or channel.request.len != self.length) return false;
        const expected_index: u8 = switch (self.operation) { .caps => 0, .enable => 1, .audio_mute => 2, .avi => 3, .vsi => 4, .hdr_disable => 5, .gcp => 6 };
        if (self.acknowledged != expected_index or (self.phase == .before_scanout) != (expected_index < 3) or
            (!self.plan.mode.transport_hdmi and expected_index > 1)) return false;
        var expected: [max_bytes]u8 = undefined;
        const length = encode(self.plan, self.operation, &expected) catch return false;
        return length == self.length and std.mem.eql(u8, expected[0..length], self.request[0..length]);
    }
};

/// Capabilities come only from one complete, current receiver capture. The
/// saved RGB8 clock is a rational TMDS character rate, including 1000/1001.
pub fn derive(saved: mode.Plan, object: display.Object, snapshot: *const outputs.Snapshot) !Plan {
    try mode.validate(saved.signal, saved.head);
    if (object.client == 0 or object.display == 0 or object.epoch != saved.epoch or snapshot.topology.client != object.client or
        !std.meta.eql(saved, try mode.bind(saved, snapshot, saved.epoch, saved.held_generation))) return error.Stale;
    var result: Plan = .{ .object = object, .mode = saved };
    const format = saved.signal.hdmi & 15;
    const vic = saved.signal.hdmi >> 4;
    if (format > 1 or vic > 4 or (format == 0 and vic != 0) or (format == 1 and (vic == 0 or !saved.transport_hdmi))) return error.Unsupported;
    result.hdmi_vic = @intCast(vic);
    for (snapshot.receivers[0..snapshot.count]) |*receiver| if (receiver.display_id == saved.signal.display_id) {
        if (receiver.status == .pending or receiver.status == .not_supported or receiver.status == .disconnected) return error.Stale;
        if (receiver.status == .valid_edid and receiver.report.complete()) {
            const report = &receiver.report;
            result.receiver_known = true;
            result.max_tmds_hz = report.max_tmds_hz;
            if (!report.digital or (saved.transport_hdmi and !report.hdmi)) return error.Unsupported;
            if (report.hdmi) {
                if (report.scdc) result.caps |= 4;
                if (report.max_tmds_hz > 340_000_000) result.caps |= 1;
                if (report.scrambling_low_rates) result.caps |= 2;
                if (result.caps & 3 != 0 and result.caps & 4 == 0) return error.Unsupported;
            }
        }
        break;
    };
    const adjusted = saved.signal.clock & 0x80000000 != 0;
    const numerator = @as(u64, saved.signal.clock & 0x7fffffff) * @as(u64, if (adjusted) 1000 else 1);
    const denominator: u64 = if (adjusted) 1001 else 1;
    const limit: u64 = if (saved.transport_hdmi) 600_000_000 else 165_000_000;
    if (numerator > limit * denominator or (result.max_tmds_hz != 0 and numerator > result.max_tmds_hz * denominator) or
        (numerator > 340_000_000 * denominator and result.caps & 5 != 5)) return error.Unsupported;
    return result;
}

pub fn command(op: Operation, plan: Plan) u32 {
    return switch (op) { .caps => 0x730293, .enable => 0x730273, .audio_mute => 0x730275,
        .avi, .gcp => 0x730288, .vsi => if (plan.hdmi_vic == 0) 0x730289 else 0x730288, .hdr_disable => 0x730289 };
}
fn put(bytes: []u8, offset: usize, value: u32) void { std.mem.writeInt(u32, bytes[offset..][0..4], value, .little); }
fn word(bytes: []const u8, offset: usize) u32 { return std.mem.readInt(u32, bytes[offset..][0..4], .little); }
fn checksum(packet: []u8) void {
    var sum: u8 = 0;
    for (packet) |byte| sum +%= byte;
    packet[3] = 0 -% sum;
}
pub fn encode(plan: Plan, op: Operation, bytes: *[max_bytes]u8) !usize {
    if (plan.object.epoch == 0 or plan.object.client == 0 or plan.object.display == 0 or plan.object.epoch != plan.mode.epoch or
        plan.caps & ~@as(u32, 7) != 0 or (!plan.mode.transport_hdmi and op != .caps and op != .enable)) return error.Descriptor;
    try mode.validate(plan.mode.signal, plan.mode.head);
    @memset(bytes, 0);
    const cmd = command(op, plan);
    const size: usize = if (cmd == 0x730288) 60 else if (cmd == 0x730289) 16 else 12;
    put(bytes, 0, plan.object.client); put(bytes, 4, plan.object.display); put(bytes, 8, cmd); put(bytes, 16, @intCast(size));
    const params = bytes[24..];
    put(params, 4, plan.mode.signal.display_id);
    switch (op) {
        .caps => put(params, 8, plan.caps),
        .enable => params[8] = @intFromBool(plan.mode.transport_hdmi),
        .audio_mute => params[8] = 1, // Audio programming belongs to its later owner.
        .hdr_disable => put(params, 8, 0x87),
        .vsi => if (plan.hdmi_vic == 0) { put(params, 8, 0x81); },
        .avi, .gcp => {},
    }
    if (cmd == 0x730288) {
        put(params, 8, 1); // Every frame, vblank, software video format; no legacy mode.
        const packet = params[21..]; // NvBool before the inline 36-byte packet.
        const length: u32 = switch (op) {
            .avi => blk: {
                packet[0] = 0x82; packet[1] = 2; packet[2] = 13;
                // RGB8 identity output: full range, no scaling/repetition,
                // unclaimed CTA VIC/aspect. Legacy HDMI VIC is in its VSI.
                packet[6] = 8;
                checksum(packet[0..17]); break :blk 17;
            },
            .vsi => blk: {
                packet[0] = 0x81; packet[1] = 1; packet[2] = 5;
                packet[4] = 3; packet[5] = 12; packet[7] = 0x20; packet[8] = plan.hdmi_vic;
                checksum(packet[0..9]); break :blk 9;
            },
            .gcp => blk: { packet[0] = 3; packet[3] = 0x10; break :blk 10; }, // Clear video AVMUTE, RGB8/default packing.
            else => return error.Descriptor,
        };
        put(params, 12, length);
        // Derive the active head from the real display ID after scanout ACK.
        // bUsePsrHeadforSdp is never used to bypass head assignment.
    }
    return 24 + size;
}
pub const Reply = struct { status: u32, rpc_error: bool = false };
pub fn decode(plan: Plan, op: Operation, record: exchange.message.Record) !Reply {
    if (record.rpc.function != function or record.rpc.cpu_rm_gfid != 0) return error.Unexpected;
    if (record.rpc.result == 0xffffffff) return error.Payload;
    if (record.rpc.result != 0) return .{ .status = record.rpc.result, .rpc_error = true };
    var expected: [max_bytes]u8 = undefined;
    const length = try encode(plan, op, &expected);
    const bytes = record.payload;
    if (bytes.len != length) return error.Payload;
    if (!std.mem.eql(u8, bytes[0..12], expected[0..12]) or !std.mem.eql(u8, bytes[16..24], expected[16..24])) return error.Unexpected;
    const status = word(bytes, 12);
    if (status == 0 and !std.mem.eql(u8, bytes[24..], expected[24..length])) return error.Unexpected;
    return .{ .status = status };
}
