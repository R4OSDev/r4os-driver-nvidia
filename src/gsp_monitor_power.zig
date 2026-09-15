// Fixed monitor controls from NVIDIA 570.144 nvkms-rm.c,
// ctrl0073specific.h, ctrl0073dp.h and dp_configcaps.cpp.
// SPDX-FileCopyrightText: Copyright (c) 1993-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 2005-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Sink power is separate from GPU idle and platform suspend. Runtime must
//! prove Core/Window retirement before admitting these fixed controls.
//! MST stops only its own stream; D3 on the shared root is never permitted.
const std = @import("std");
const aux = @import("gsp_aux_wire.zig");
const exchange = @import("gsp_exchange.zig");
pub const function: u32 = 76;
pub const max_bytes = 24 + aux.bytes;
pub const Kind = enum { digital, dp_sst, stream_only };
pub const Plan = struct {
    object: @import("gsp_display_rpc.zig").Object,
    mode: @import("gsp_boot_mode.zig").Plan,
    kind: Kind,
    sink_control: bool,
};
pub const Stage = enum { digital, sink, main_link, complete };
pub const Result = struct { sequence: u64, on: bool, receipt: u64, failure: ?anyerror = null };
pub const Work = struct {
    plan: Plan,
    on: bool,
    sequence: u64,
    deadline: u64,
    stage: Stage,
    pending: bool = false,
    attempts: u8 = 0,
    not_before: u64 = 0,
    receipt: u64 = 0,
    request: [max_bytes]u8 = @splat(0),
    length: usize = 0,

    pub fn init(plan: Plan, on: bool, sequence: u64, deadline: u64) !Work {
        if (plan.object.epoch == 0 or plan.object.epoch != plan.mode.epoch or plan.object.client == 0 or
            plan.object.display == 0 or sequence == 0 or deadline == 0 or plan.mode.window >= 8 or
            plan.mode.signal.display_id == 0 or @popCount(plan.mode.signal.display_id) != 1) return error.Descriptor;
        if ((plan.kind == .dp_sst) != (plan.mode.displayPort() and plan.mode.signal.mst == null) or
            (plan.kind == .stream_only) != (plan.mode.signal.mst != null) or
            (plan.kind == .digital and !plan.sink_control) or
            (plan.kind == .stream_only and plan.sink_control)) return error.Descriptor;
        return .{ .plan = plan, .on = on, .sequence = sequence, .deadline = deadline,
            .stage = switch (plan.kind) {
                .digital => .digital,
                .dp_sst => if (plan.sink_control) .sink else if (on) .complete else .main_link,
                .stream_only => .complete,
            } };
    }
    fn query(self: *const Work) aux.Request {
        // Write D0 directly: a sleeping sink may not answer a preceding read.
        return .{ .display_id = self.plan.mode.signal.display_id,
            .operation = if (self.on) .{ .power_on = 1 } else .power_off };
    }
    pub fn encode(self: *const Work, bytes: *[max_bytes]u8) !usize {
        if (self.stage == .complete) return error.State;
        @memset(bytes, 0);
        put(bytes, 0, self.plan.object.client); put(bytes, 4, self.plan.object.display);
        const params = bytes[24..];
        if (self.stage == .sink) {
            if (self.plan.kind != .dp_sst or !self.plan.sink_control) return error.State;
            put(bytes, 8, aux.command); put(bytes, 16, aux.bytes); put(bytes, 20, aux.rpc_flags);
            _ = try aux.encode(self.query(), params);
            return max_bytes;
        }
        put(params, 4, self.plan.mode.signal.display_id);
        if (self.stage == .digital) {
            if (self.plan.kind != .digital) return error.State;
            put(bytes, 8, 0x730295); put(bytes, 16, 20);
            put(params, 8, @intFromBool(self.on));
            // nvkms-rm.c uses connector ID with zero headIdx and force flag.
            return 44;
        }
        if (self.plan.kind != .dp_sst or self.on) return error.State;
        put(bytes, 8, 0x731356); put(bytes, 16, 12);
        return 36; // Main link off after D3; fresh training owns link-on.
    }
    pub fn matches(self: *const Work, channel: *const exchange.Exchange, deadline: u64) bool {
        if (!self.pending or self.deadline != deadline or channel.phase != .prepared or channel.deadline != deadline or
            channel.function != function or channel.request.ptr != self.request[0..].ptr or channel.request.len != self.length) return false;
        var expected: [max_bytes]u8 = undefined;
        const length = self.encode(&expected) catch return false;
        return length == self.length and std.mem.eql(u8, expected[0..length], self.request[0..length]);
    }
    fn retry(self: *Work, now: u64, delay_ms: u32) !void {
        // Bounded worker slices, including the reference's wake retry count.
        if (self.attempts >= 40 or delay_ms == 0 or delay_ms > 500) return error.RetryExhausted;
        self.not_before = now +| @as(u64, delay_ms) * std.time.ns_per_ms;
        if (self.not_before >= self.deadline) return error.RetryExhausted;
    }
    pub fn consume(self: *Work, record: exchange.message.Record, now: u64, receipt: u64) !void {
        if (!self.pending or receipt == 0 or record.rpc.function != function or record.rpc.cpu_rm_gfid != 0) return error.Unexpected;
        if (record.rpc.result == 0xffffffff) return error.Payload;
        if (record.rpc.result != 0) return error.RmRejected;
        var expected: [max_bytes]u8 = undefined;
        const length = try self.encode(&expected);
        const bytes = record.payload;
        if (bytes.len != length) return error.Payload;
        if (!std.mem.eql(u8, bytes[0..12], expected[0..12]) or !std.mem.eql(u8, bytes[16..24], expected[16..24])) return error.Unexpected;
        const status = std.mem.readInt(u32, bytes[12..16], .little);
        if (self.stage == .sink) {
            const reply = try aux.decode(self.query(), status, bytes[24..]);
            if ((status == 3 or status == 0x66) and reply.retry_ms != 0) return self.retry(now, reply.retry_ms);
            if (status != 0) return error.RmRejected;
            if (reply.kind == .defer_reply or (self.on and reply.kind == .timeout)) return self.retry(now, 1);
            if (reply.kind != .ack or reply.count != 1) return error.Aux;
            self.stage = if (self.on) .complete else .main_link;
        } else {
            if (status != 0) return error.RmRejected;
            if (!std.mem.eql(u8, bytes[24..], expected[24..length])) return error.Unexpected;
            self.stage = .complete;
        }
        self.receipt = receipt;
        self.attempts = 0;
        self.not_before = if (self.on and self.plan.kind == .dp_sst) now +| std.time.ns_per_ms else 0;
    }
};
fn put(bytes: []u8, offset: usize, value: u32) void { std.mem.writeInt(u32, bytes[offset..][0..4], value, .little); }
