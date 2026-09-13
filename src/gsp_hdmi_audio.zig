// Wire controls from NVIDIA 570.144 ctrl0073dfp.h/ctrl0073specific.h.
// SPDX-FileCopyrightText: Copyright (c) 2005-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 1993-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Independent finite audio controls on the existing serialized RM exchange.
//! A rejected audio setter degrades audio without failing a video modeset.
const std = @import("std");
const link = @import("gsp_hdmi_link.zig");
const display = @import("gsp_display_rpc.zig");
const mode = @import("gsp_boot_mode.zig");
const outputs = @import("gsp_outputs.zig");
const exchange = @import("gsp_exchange.zig");
const eld = @import("r4gfx_edid").eld;
pub const function: u32 = 76;
pub const max_bytes = 144;
pub const Operation = enum { mute, clear, publish, unmute };
pub const Plan = struct {
    object: display.Object,
    mode: mode.Plan,
    data: ?eld.Data = null,
    pub fn portId(self: Plan) [8]u8 {
        var result: [8]u8 = @splat(0);
        std.mem.writeInt(u32, result[0..4], self.mode.signal.display_id, .little);
        return result;
    }
};
pub const Work = struct {
    plan: Plan,
    operation: Operation,
    sequence: u64,
    deadline: u64,
    pending: bool = false,
    request: [max_bytes]u8 = @splat(0),
    length: usize = 0,
    pub fn matches(self: *const Work, channel: *const exchange.Exchange, deadline: u64) bool {
        if (!self.pending or self.sequence == 0 or self.deadline != deadline or channel.phase != .prepared or
            channel.deadline != deadline or channel.function != function or channel.request.ptr != self.request[0..].ptr or
            channel.request.len != self.length) return false;
        var expected: [max_bytes]u8 = undefined;
        const length = encode(self.plan, self.operation, &expected) catch return false;
        return length == self.length and std.mem.eql(u8, expected[0..length], self.request[0..length]);
    }
};
pub const Result = struct { sequence: u64, operation: Operation, receipt: u64, status: u32, rpc_error: bool };

pub fn derive(saved: mode.Plan, object: display.Object, snapshot: *const outputs.Snapshot) !Plan {
    _ = try link.derive(saved, object, snapshot);
    if (!saved.transport_hdmi) return error.Unsupported;
    var result: Plan = .{ .object = object, .mode = saved };
    for (snapshot.receivers[0..snapshot.count]) |*receiver| if (receiver.display_id == saved.signal.display_id) {
        if (receiver.connected == true and receiver.status == .valid_edid and receiver.report.complete()) {
            result.data = eld.encode(&receiver.report, result.portId()) catch null;
        }
        return result;
    };
    return error.Stale;
}
fn put(bytes: []u8, offset: usize, value: u32) void { std.mem.writeInt(u32, bytes[offset..][0..4], value, .little); }
fn word(bytes: []const u8, offset: usize) u32 { return std.mem.readInt(u32, bytes[offset..][0..4], .little); }
pub fn encode(plan: Plan, operation: Operation, bytes: *[max_bytes]u8) !usize {
    if (plan.object.client == 0 or plan.object.display == 0 or plan.object.epoch == 0 or plan.object.epoch != plan.mode.epoch or
        !plan.mode.transport_hdmi) return error.Descriptor;
    try mode.validate(plan.mode.signal, plan.mode.head);
    if (operation == .publish and plan.data == null) return error.Unsupported;
    if (operation == .unmute and (plan.data == null or !plan.data.?.stereo_48k_s16)) return error.Unsupported;
    const eld_command = operation == .clear or operation == .publish;
    const size: u32 = if (eld_command) 120 else 12;
    @memset(bytes, 0);
    put(bytes, 0, plan.object.client); put(bytes, 4, plan.object.display);
    put(bytes, 8, if (eld_command) 0x731144 else 0x730275); put(bytes, 16, size);
    const params = bytes[24..];
    put(params, 4, plan.mode.signal.display_id);
    if (eld_command) {
        // HDMI and DP-SST use device entry 0 even when the display head is
        // nonzero. nvkms-hdmi.c:GetAudioDeviceEntry reserves head-indexed
        // entries for MST. R4OS currently enables only HDMI here.
        put(params, 116, 0);
        if (operation == .publish) {
            const data = plan.data.?;
            if (data.max_frequency == 0 or data.max_frequency > 7 or data.baselineBytes() > 80 or
                !std.mem.eql(u8, data.bytes[8..16], &plan.portId())) return error.Descriptor;
            put(params, 8, eld.max_bytes);
            @memcpy(params[12..108], &data.bytes);
            put(params, 108, data.max_frequency);
            put(params, 112, 3); // PD/ELDV only after the complete ELD write.
        }
    } else params[8] = @intFromBool(operation == .mute);
    return 24 + size;
}
pub const Reply = struct { status: u32, rpc_error: bool = false };
pub fn decode(plan: Plan, operation: Operation, record: exchange.message.Record) !Reply {
    if (record.rpc.function != function or record.rpc.cpu_rm_gfid != 0) return error.Unexpected;
    if (record.rpc.result == 0xffffffff) return error.Payload;
    if (record.rpc.result != 0) return .{ .status = record.rpc.result, .rpc_error = true };
    var expected: [max_bytes]u8 = undefined;
    const length = try encode(plan, operation, &expected);
    const bytes = record.payload;
    if (bytes.len != length) return error.Payload;
    if (!std.mem.eql(u8, bytes[0..12], expected[0..12]) or !std.mem.eql(u8, bytes[16..24], expected[16..24])) return error.Unexpected;
    const status = word(bytes, 12);
    if (status == 0 and !std.mem.eql(u8, bytes[24..], expected[24..length])) return error.Unexpected;
    return .{ .status = status };
}
