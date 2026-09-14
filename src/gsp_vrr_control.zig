// NVIDIA570.144 protocol/method definitions (MIT): ctrl0073system.h,
// ctrl0073specific.h, clc67d.h, nvt_edidext_861.c and nvkms-vrr.c.
// Copyright (c) 2005-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 1993-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2020 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2015-2020 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
//! One bounded VRR switch on an existing retained mode. No allocation/MMIO
//! and no change to the image, HDR metadata, audio clock or mode identity.
const std = @import("std");
const boot = @import("gsp_boot_mode.zig");
const display = @import("gsp_display_rpc.zig");
const outputs = @import("gsp_outputs.zig");
const exchange = @import("gsp_exchange.zig");
const aux = @import("gsp_aux_wire.zig");
pub const edid = @import("r4gfx_edid");
pub const commands = @import("gsp_display_commands.zig");
pub const function: u32 = 76;
pub const max_bytes = 84;
pub const Plan = struct { object: display.Object, mode: boot.Plan, refresh: edid.vrr.Plan };

pub fn timing(mode: boot.Plan) !edid.timing.Timing {
    try boot.validate(mode.signal, mode.head);
    const s = mode.signal;
    const ht = s.total & 65535;
    const vt = s.total >> 16;
    const hs = ht - (s.blank_end & 65535) - 1;
    const vs = vt - (s.blank_end >> 16) - 1;
    const hz: u64 = s.clock & 0x7fffffff;
    const value: edid.timing.Timing = .{ .width = mode.width, .height = mode.height, .h_total = ht, .v_total = vt, .h_start = hs, .h_end = hs + (s.sync_end & 65535) + 1, .v_start = vs, .v_end = vs + (s.sync_end >> 16) + 1, .clock_hz = if (s.clock & 0x80000000 != 0) hz * 1000 / 1001 else hz };
    if (!value.valid()) return error.Timing;
    return value;
}
pub fn derive(mode: boot.Plan, object: display.Object, snapshot: *const outputs.Snapshot, link: anytype, core_class: u32) !Plan {
    if (core_class != 0xc67d or !link.complete()) return error.Unsupported;
    if (object.epoch == 0 or object.client == 0 or object.display == 0 or object.epoch != mode.epoch or
        !snapshot.coherent or snapshot.generation != mode.output_generation or !std.meta.eql(mode, link.plan.mode) or
        !std.meta.eql(object, link.plan.object)) return error.Stale;
    if (!mode.transport_hdmi and !mode.displayPort()) return error.Unsupported;
    const source: edid.vrr.Source = .{ .adaptive = true, .hdmi_emp = true, .direct_sst = true, .dp_ignore_msa = if (link.dp) |dp| dp.source.dp14 and dp.dpcd[7] & 64 != 0 else false, .max_vtotal = 65535, .max_timeout_us = 0x3fffff, .minimum_span_permille = 1100 };
    for (snapshot.receivers[0..snapshot.count]) |*receiver| {
        if (receiver.display_id != mode.signal.display_id) continue;
        if (receiver.epoch != object.epoch or receiver.client != object.client or receiver.connected != true or
            receiver.status != .valid_edid) return error.Incomplete;
        return .{ .object = object, .mode = mode, .refresh = try edid.vrr.admit(&receiver.report, try timing(mode), if (mode.displayPort()) .displayport else .hdmi, source) };
    }
    return error.Incomplete;
}
pub const Phase = enum { link_read, link_write, link_verify, link_packet, notify, pstate_initial, pstate_active, arm, clear_elv, core, disarm, pstate_inactive, pstate_off, complete };
pub const Work = struct {
    plan: Plan,
    enabled: bool,
    deadline: u64,
    phase: Phase,
    pending: bool = false,
    request: [max_bytes]u8 = @splat(0),
    length: usize = 0,
    last_receipt: u64 = 0,
    last_status: u32 = 0,
    downspread: ?u8 = null,
    retries: u8 = 0,
    not_before: u64 = 0,
    core_point: u64 = 0,
    core_completed: bool = false,
    supervisor_armed: bool = false,
    cleanup_disarm: bool = false,

    pub fn init(plan: Plan, enabled: bool, now: u64, deadline: u64) !Work {
        try boot.validate(plan.mode.signal, plan.mode.head);
        if (now == 0 or deadline <= now or deadline - now > 3_000_000_000 or plan.object.epoch != plan.mode.epoch or
            plan.object.epoch == 0 or plan.object.client == 0 or plan.object.display == 0 or !plan.refresh.range.valid() or
            plan.refresh.timeout_us == 0 or plan.refresh.timeout_us > 0x3fffff or plan.refresh.lfc or
            plan.refresh.max_vtotal <= plan.mode.signal.total >> 16) return error.Descriptor;
        return .{ .plan = plan, .enabled = enabled, .deadline = deadline, .phase = if (enabled) (if (plan.mode.displayPort()) .link_read else .link_packet) else .notify };
    }
    pub fn ready(self: *const Work, now: u64) bool {
        return self.phase != .core and self.phase != .complete and !self.pending and now >= self.not_before and now < self.deadline;
    }
    fn auxRequest(self: *const Work) !?aux.Request {
        const operation: aux.Operation = switch (self.phase) {
            .link_read, .link_verify => .downspread_read,
            .link_write => .{ .downspread_write = self.downspread orelse return error.State },
            else => return null,
        };
        if (!self.plan.mode.displayPort()) return error.State;
        return .{ .display_id = self.plan.mode.signal.display_id, .operation = operation };
    }
    pub fn encode(self: *const Work, bytes: *[max_bytes]u8) !usize {
        @memset(bytes, 0);
        const cmd: u32 = switch (self.phase) {
            .link_read, .link_write, .link_verify => aux.command,
            .link_packet => 0x730288,
            .notify => 0x73012c,
            .pstate_initial, .pstate_active, .pstate_inactive, .pstate_off => 0x730134,
            .arm, .disarm => 0x73012f,
            .clear_elv => 0x73012e,
            else => return error.State,
        };
        const size: u32 = switch (cmd) {
            aux.command => 48,
            0x730288 => 60,
            0x73012c => 12,
            0x730134 => 24,
            0x73012f => 20,
            0x73012e => 8,
            else => unreachable,
        };
        put(bytes, 0, self.plan.object.client);
        put(bytes, 4, self.plan.object.display);
        put(bytes, 8, cmd);
        put(bytes, 16, size);
        const p = bytes[24..];
        put(p, 4, self.plan.mode.signal.display_id);
        if (try self.auxRequest()) |request| {
            put(bytes, 20, aux.rpc_flags);
            _ = try aux.encode(request, p[0..48]);
        } else switch (self.phase) {
            .notify => p[8] = @intFromBool(self.enabled),
            .arm, .disarm => {
                p[8] = @intFromBool(self.phase == .arm);
                p[9] = @intFromBool(self.enabled or self.cleanup_disarm);
                put(p, 12, self.plan.mode.height);
                put(p, 16, (self.plan.mode.signal.total >> 16) - (self.plan.mode.signal.blank_start >> 16));
            },
            .pstate_initial, .pstate_active, .pstate_inactive, .pstate_off => {
                p[8] = @intFromBool(self.phase == .pstate_active);
                p[9] = @intFromBool(self.phase == .pstate_initial or self.phase == .pstate_off);
                p[10] = @intFromBool(self.phase != .pstate_off);
                if (self.phase == .pstate_initial) put(p, 12, self.plan.refresh.max_vtotal - (self.plan.mode.signal.total >> 16));
            },
            .link_packet => {
                if (!self.plan.mode.transport_hdmi or self.plan.mode.displayPort()) return error.State;
                put(p, 8, if (self.enabled) 1 else 5); // Every frame / a single END packet, on vblank.
                put(p, 12, 31); // EMP has no inserted checksum byte.
                const packet = p[21..];
                @memcpy(packet[0..10], &[_]u8{ 0x7f, 0xc0, 0, if (self.enabled) 0x84 else 0xc4, 0, 1, 0, 1, 0, if (self.enabled) 4 else 0 });
                packet[10] = @intFromBool(self.enabled);
            },
            .clear_elv => {},
            else => return error.State,
        }
        return 24 + size;
    }
    pub fn matches(self: *const Work, channel: *const exchange.Exchange, deadline: u64) bool {
        if (!self.pending or deadline != self.deadline or channel.deadline != deadline or channel.function != function or
            channel.phase != .prepared or channel.request.ptr != self.request[0..].ptr or channel.request.len != self.length) return false;
        var expected: [max_bytes]u8 = undefined;
        const n = self.encode(&expected) catch return false;
        return n == self.length and std.mem.eql(u8, expected[0..n], self.request[0..n]);
    }
    pub fn consume(self: *Work, record: exchange.message.Record, receipt: u64, now: u64) !void {
        if (!self.pending or receipt == 0 or receipt <= self.last_receipt or now >= self.deadline) return error.Stale;
        if (record.rpc.function != function or record.rpc.cpu_rm_gfid != 0) return error.Unexpected;
        if (record.rpc.result == 0xffffffff) return error.Payload;
        self.last_status = record.rpc.result;
        if (self.last_status != 0) return error.RmRejected;
        const data = record.payload;
        if (data.len != self.length or !std.mem.eql(u8, data[0..12], self.request[0..12]) or
            !std.mem.eql(u8, data[16..24], self.request[16..24])) return error.Unexpected;
        self.last_receipt = receipt;
        self.pending = false;
        const status = word(data, 12);
        self.last_status = status;
        if (try self.auxRequest()) |request| {
            const reply = try aux.decode(request, status, data[24..]);
            if (status == 3 or status == 0x66 or (status == 0 and reply.kind == .defer_reply)) {
                if (self.retries == 3) return error.Aux;
                self.retries += 1;
                const delay = @max(@as(u64, reply.retry_ms) * 1_000_000, 100_000);
                if (delay >= self.deadline - now) return error.Timeout;
                self.not_before = now + delay;
                return;
            }
            if (status != 0 or reply.kind != .ack or reply.count != 1) return error.Aux;
            if (self.phase == .link_read) self.downspread = (reply.data[0] & ~@as(u8, 128)) | (if (self.enabled) @as(u8, 128) else 0);
            if (self.phase == .link_verify and reply.data[0] != self.downspread.?) return error.Aux;
        } else {
            if (status != 0) return error.RmRejected;
            if (!std.mem.eql(u8, data[24..], self.request[24..self.length])) return error.Unexpected;
        }
        self.retries = 0;
        self.not_before = 0;
        if (self.phase == .arm) self.supervisor_armed = true;
        if (self.phase == .disarm) {
            self.supervisor_armed = false;
            if (self.cleanup_disarm) {
                self.cleanup_disarm = false; self.phase = .notify; return;
            }
        }
        self.phase = switch (self.phase) {
            .link_read => .link_write,
            .link_write => .link_verify,
            .link_verify, .link_packet => if (self.enabled) .notify else .complete,
            .notify => if (self.enabled) .pstate_initial else .arm,
            .pstate_initial => .pstate_active,
            .pstate_active => .arm,
            .arm => if (self.enabled) .core else .clear_elv,
            .clear_elv => .core,
            .disarm => if (self.enabled) .complete else .pstate_inactive,
            .pstate_inactive => .pstate_off,
            .pstate_off => if (self.plan.mode.displayPort()) .link_read else .link_packet,
            else => return error.State,
        };
    }
    pub fn coreConfig(self: *const Work, notifier: u32, windows: u32) !commands.Config {
        if (self.phase != .core or self.pending or self.core_completed or !self.supervisor_armed) return error.State;
        return .{ .notifier = notifier, .windows = windows, .initialize = false, .refresh_control = .{ .head = self.plan.mode.head, .enabled = self.enabled, .timeout_us = if (self.enabled) self.plan.refresh.timeout_us else 0 } };
    }
    pub fn submitted(self: *Work, point: u64) !void {
        if (self.phase != .core or self.pending or self.core_point != 0 or point == 0) return error.State;
        self.core_point = point;
    }
    pub fn completed(self: *Work, point: u64) !void {
        if (self.phase != .core or self.core_completed or point == 0 or point != self.core_point) return error.Stale;
        self.core_completed = true;
        self.phase = .disarm;
    }
};
fn put(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
