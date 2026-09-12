// DDC/I2C reference notices: unchanged NVIDIA 570.144 attribution.
// Nvidia570.144/src/common/sdk/nvidia/inc/nvstatuscodes.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2014-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// Query prerequisites and limits: NVIDIA570.144 (MIT); display sequence
// also informed by Nouveau (MIT). R4OS capture ownership: Apache-2.0.
// Nvidia570.144/src/common/sdk/nvidia/inc/ctrl/ctrl0073/ctrl0073system.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2005-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// Nvidia570.144/src/common/sdk/nvidia/inc/ctrl/ctrl0073/ctrl0073specific.h
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
// Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/gsp/rm/r535/disp.c
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
//! One bounded receiver refresh through the canonical RM graph. EDID/CTA
//! semantics belong to the shared R4GFX parser; no duplicate driver parser.
//! Caller-owned capture storage stays off the worker stack and is readable
//! only after the full query/validation/drain sequence completes. No modeset,
//! power inference or cached boot EDID substitution. Only an explicit DDC
//! read rejection can retry, within three attempts and the original deadline.
const std = @import("std");
const graph = @import("gsp_rm_graph.zig");
const display = @import("gsp_display_rpc.zig");
pub const edid = @import("r4gfx_edid");
pub const Error = graph.Error;
pub const State = enum { supported, connected, edid, buses, ports, ddc, ddc_verify, bus_verify, verify, drain, complete, obsolete, failed, released };
pub const Status = enum { pending, not_supported, disconnected, edid_missing, edid_rejected, invalid_edid, unsupported_data, incomplete_edid, valid_edid, query_rejected };
pub const Capture = struct {
    epoch: u64 = 0,
    client: u32 = 0,
    display_id: u32 = 0,
    // Last ACKed reply's unique session receipt, not a guessed RM sequence.
    receipt_serial: u64 = 0,
    status: Status = .pending,
    connected: ?bool = null,
    supported_ddc: bool = false,
    rpc_status: ?u32 = null,
    control_status: ?u32 = null,
    rejected_command: ?display.Command = null,
    parse_error: ?edid.Error = null,
    edid_bytes: usize = 0,
    bytes: [edid.max_blocks * 128]u8 = @splat(0),
    report: edid.Report = .{},
    source: enum { rm_raw, ddc } = .rm_raw,
    buses: ?display.Buses = null,
    port_info: ?u8 = null,
    ddc_retries: u16 = 0,
    ddc_rpc_status: ?u32 = null,
    ddc_control_status: ?u32 = null,
};
pub const Refresh = struct {
    owner: *graph.Owner,
    channel: display.Channel,
    capture: *Capture,
    state: State = .supported,
    revision: u64,
    deadline: u64,
    self_address: usize = 0,
    invalidated: bool = false,
    failure: ?Error = null,
    block: u8 = 0,
    blocks: u8 = 1,
    attempts: u8 = 0,
    retry_at_ns: u64 = 0,

    /// Storage and graph remain exclusively borrowed until release. Moving
    /// this value is allowed only before its first poll; never copy it live.
    pub fn init(owner: *graph.Owner, display_id: u32, capture: *Capture, deadline: u64) Error!Refresh {
        if (display_id == 0 or display_id & (display_id - 1) != 0) return error.Query;
        var loan = try owner.loan(deadline);
        errdefer owner.reclaim(&loan.runtime, deadline) catch {};
        const channel = try display.Channel.init(&loan.runtime, loan.object, deadline);
        capture.* = .{ .epoch = loan.object.epoch, .client = loan.object.client, .display_id = display_id };
        return .{ .owner = owner, .channel = channel, .capture = capture, .revision = channel.exchange.revision, .deadline = deadline };
    }
    fn binding(self: *Refresh) Error!void {
        if (self.state == .failed or self.state == .released) return error.State;
        if (self.self_address != 0 and self.self_address != @intFromPtr(self)) return error.Stale;
        if (self.owner.state != .loaned or self.owner.base.exchange.session != self.channel.exchange.session or
            self.owner.reservation.epoch != self.capture.epoch or self.owner.reservation.client != self.capture.client) return error.Stale;
    }
    fn guard(self: *Refresh) Error!void {
        try self.binding();
        try self.channel.exchange.guard(self.deadline);
        self.invalidated = self.invalidated or self.channel.exchange.revision != self.revision;
    }
    fn fail(self: *Refresh, reason: Error) Error {
        if ((self.self_address != 0 and self.self_address != @intFromPtr(self)) or self.state == .released) return error.State;
        if (self.failure == null) self.failure = reason;
        self.channel.exchange.session.stop();
        self.state = .failed;
        return reason;
    }
    /// A caller invalidation never drops an outstanding RPC or ACKs a notice.
    /// poll drains the response within the original budget before release.
    pub fn invalidate(self: *Refresh) Error!void {
        try self.binding();
        self.invalidated = true;
    }
    fn query(self: *Refresh) Error!display.Query {
        return switch (self.state) {
            .supported => .supported,
            .connected, .verify => .{ .connected = self.capture.display_id },
            .edid => .{ .edid = self.capture.display_id },
            .buses, .bus_verify => .{ .buses = self.capture.display_id },
            .ports => .ports,
            .ddc, .ddc_verify => .{ .ddc = .{ .display_id = self.capture.display_id,
                .port = @intCast(self.capture.buses.?.ddc - 1), .block = if (self.state == .ddc_verify) 0 else self.block } },
            else => error.State,
        };
    }
    fn parseCapture(self: *Refresh) void {
        self.capture.report = .{};
        self.capture.parse_error = null;
        if (self.capture.edid_bytes == 0) { self.capture.status = .edid_missing; return; }
        edid.parse(self.capture.bytes[0..self.capture.edid_bytes], &self.capture.report) catch |err| {
            self.capture.parse_error = err;
            self.capture.status = if (err == error.TooLarge or err == error.Capacity) .unsupported_data else .invalid_edid;
            return;
        };
        self.capture.status = if (self.capture.report.complete()) .valid_edid else .incomplete_edid;
    }
    fn fallback(self: *Refresh) void {
        self.state = if (self.capture.status != .valid_edid and self.channel.object.i2c != 0 and self.capture.supported_ddc) .buses else .verify;
    }
    pub fn waiting(self: *const Refresh) bool {
        return self.retry_at_ns > self.channel.exchange.session.last_clock;
    }
    pub fn matches(self: *Refresh, current: *const @import("gsp_exchange.zig").Exchange, deadline: u64) bool {
        if (self.self_address != @intFromPtr(self) or self.failure != null or self.deadline != deadline) return false;
        const request = self.query() catch return false;
        return self.channel.matches(current, request, deadline);
    }
    fn consume(self: *Refresh, reply: display.Reply) Error!void {
        if (reply == .obsolete) {
            self.invalidated = true;
            return;
        }
        if (reply == .rpc_error or reply == .control_error) {
            if (self.state == .ddc or self.state == .ddc_verify) {
                if (reply == .rpc_error) self.capture.ddc_rpc_status = reply.rpc_error else self.capture.ddc_control_status = reply.control_error;
                // Only complete, ACKable RM results can retry. No copyout,
                // transport timeout, malformed reply or uncertain ACK retries.
                if (reply == .control_error and (reply.control_error == 3 or reply.control_error == 0x14 or
                    reply.control_error == 0x65 or reply.control_error == 0x66) and self.attempts < 2) {
                    self.attempts += 1;
                    self.capture.ddc_retries += 1;
                    self.retry_at_ns = std.math.add(u64, self.channel.exchange.session.last_clock, std.time.ns_per_ms) catch return error.Clock;
                    return;
                }
                self.attempts = 0;
                self.retry_at_ns = 0;
                if (self.state == .ddc_verify) self.invalidated = true else {
                    self.parseCapture();
                    if (self.capture.edid_bytes == 0) self.capture.status = .edid_rejected;
                    self.state = if (self.capture.edid_bytes != 0) .ddc_verify else .verify;
                }
                return;
            }
            if (self.state == .buses or self.state == .ports or self.state == .bus_verify) {
                if (reply == .rpc_error) self.capture.ddc_rpc_status = reply.rpc_error else self.capture.ddc_control_status = reply.control_error;
                if (self.state == .bus_verify) self.invalidated = true;
                self.state = .verify;
                return;
            }
            if (reply == .rpc_error) self.capture.rpc_status = reply.rpc_error else self.capture.control_status = reply.control_error;
            self.capture.rejected_command = std.meta.activeTag(try self.query());
            if (self.state == .edid) {
                self.capture.status = .edid_rejected;
                self.fallback();
            } else {
                self.capture.status = .query_rejected;
                self.capture.connected = null;
                self.capture.edid_bytes = 0;
                self.capture.report = .{};
                self.state = .drain;
            }
            return;
        }
        switch (self.state) {
            .supported => {
                if (reply != .supported) return error.Unexpected;
                self.capture.supported_ddc = reply.supported.ddc & self.capture.display_id != 0;
                if (reply.supported.displays & self.capture.display_id == 0) {
                    self.capture.status = .not_supported;
                    self.state = .drain;
                } else self.state = .connected;
            },
            .connected => {
                if (reply != .connected) return error.Unexpected;
                const connected = reply.connected & self.capture.display_id != 0;
                self.capture.connected = connected;
                if (connected) self.state = .edid else {
                    self.capture.status = .disconnected;
                    self.state = .drain;
                }
            },
            .edid => {
                if (reply != .edid) return error.Unexpected;
                @memcpy(self.capture.bytes[0..reply.edid.len], reply.edid);
                self.capture.edid_bytes = reply.edid.len;
                self.parseCapture();
                self.fallback();
            },
            .buses => {
                if (reply != .buses) return error.Unexpected;
                self.capture.buses = reply.buses;
                // NONE/dynamic and unknown RM IDs never become guessed bus
                // indices. NV402C has exactly sixteen zero-based ports.
                self.state = if (reply.buses.ddc > 0 and reply.buses.ddc <= 16) .ports else .verify;
            },
            .ports => {
                if (reply != .ports) return error.Unexpected;
                const info = reply.ports[self.capture.buses.?.ddc - 1];
                self.capture.port_info = info;
                if (info & 5 != 5) { self.state = .verify; return; }
                self.capture.source = .ddc;
                self.capture.edid_bytes = 0;
                self.capture.report = .{};
                self.capture.parse_error = null;
                self.capture.rpc_status = null;
                self.capture.control_status = null;
                self.capture.rejected_command = null;
                self.capture.status = .pending;
                @memset(&self.capture.bytes, 0);
                self.state = .ddc;
            },
            .ddc, .ddc_verify => {
                if (reply != .ddc) return error.Unexpected;
                self.attempts = 0;
                self.retry_at_ns = 0;
                if (self.state == .ddc_verify) {
                    if (!std.mem.eql(u8, self.capture.bytes[0..128], &reply.ddc)) self.invalidated = true;
                    self.state = .bus_verify;
                    return;
                }
                @memcpy(self.capture.bytes[@as(usize, self.block) * 128 ..][0..128], &reply.ddc);
                self.capture.edid_bytes += 128;
                if (self.block == 0) {
                    self.parseCapture(); // The shared parser admits the base before its count is used.
                    if (self.capture.parse_error != null) { self.state = .verify; return; }
                    self.blocks = @intCast(@min(@as(u16, self.capture.bytes[126]) + 1, edid.max_blocks));
                }
                self.block += 1;
                if (self.block == self.blocks) { self.parseCapture(); self.state = .ddc_verify; }
            },
            .bus_verify => {
                if (reply != .buses) return error.Unexpected;
                if (!std.meta.eql(self.capture.buses.?, reply.buses)) self.invalidated = true;
                self.state = .verify;
            },
            .verify => {
                if (reply != .connected) return error.Unexpected;
                if (reply.connected & self.capture.display_id == 0) self.invalidated = true;
                self.state = .drain;
            },
            else => return error.State,
        }
    }
    /// Returned notices must complete through channel (ordinary/CPU display
    /// bridges), with the real admitted event/health/etc. owner. No auto-ACK.
    pub fn poll(self: *Refresh) Error!?display.Dispatch {
        if (self.state == .complete or self.state == .obsolete or self.state == .failed or self.state == .released) return error.State;
        if (self.self_address != 0 and self.self_address != @intFromPtr(self)) return error.Stale;
        self.self_address = @intFromPtr(self);
        self.guard() catch |err| return self.fail(err);
        if (self.channel.pending != null) return error.Pending;
        if (self.invalidated and self.channel.exchange.phase == .idle) {
            self.state = .obsolete;
            return null;
        }
        if (self.channel.exchange.phase == .idle and self.state != .drain and !self.waiting()) {
            self.channel.begin(try self.query(), self.deadline) catch |err| return self.fail(err);
        }
        const pending = self.channel.poll(self.deadline) catch |err| {
            if (err == error.Pending) return err;
            if (err == error.Obsolete) {
                self.invalidated = true;
                self.state = .obsolete;
                return null;
            }
            return self.fail(err);
        };
        self.guard() catch |err| return self.fail(err);
        if (pending) |dispatch| {
            if (dispatch.value == .notification) return dispatch;
            if (!self.invalidated) self.consume(dispatch.value.reply) catch |err| return self.fail(err);
            self.channel.complete(dispatch.ticket) catch |err| return self.fail(err);
            self.capture.receipt_serial = dispatch.ticket.serial;
            self.guard() catch |err| return self.fail(err);
            if (self.invalidated) self.state = .obsolete;
        } else if (self.state == .drain) {
            // A final idle receive closes queued-notice races before exposing
            // the capture. Later physical changes still require normal HPD work.
            if (self.invalidated) self.state = .obsolete else self.state = .complete;
        }
        return null;
    }
    /// Complete means a coherent queried capture, including explicit no-data
    /// results. Check status/report warnings before using EDID capabilities.
    pub fn borrow(self: *Refresh, deadline: u64) Error!*const Capture {
        if (self.state != .complete) return error.State;
        try self.binding();
        self.channel.exchange.guard(deadline) catch |err| return self.fail(err);
        if (self.invalidated or self.channel.exchange.revision != self.revision) return error.Obsolete;
        return self.capture;
    }
    /// Release only after completion/drain, or before any poll. Failed or
    /// ambiguous runs retain their graph/queues for independent recovery.
    pub fn release(self: *Refresh, deadline: u64) Error!void {
        if (self.state != .complete and self.state != .obsolete and !(self.state == .supported and self.self_address == 0)) return error.State;
        try self.binding();
        var token = self.channel.handoff(deadline) catch |err| return self.fail(err);
        self.owner.reclaim(&token, deadline) catch |err| return self.fail(err);
        self.state = .released;
    }
};
