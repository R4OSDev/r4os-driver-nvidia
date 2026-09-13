// ExFiles/Reference/GFX/Nvidia/OpenKernelModules-570.144/src/nvidia/src/kernel/gpu/disp/disp_channel.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 1993-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//
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
//
// ExFiles/Reference/GFX/Nvidia/Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/gsp/rm/r570/disp.c
// /* SPDX-License-Identifier: MIT
//  *
//  * Copyright (c) 2025, NVIDIA CORPORATION. All rights reserved.
//  */
//
// ExFiles/Reference/GFX/Nvidia/Nouveau/drivers/gpu/drm/nouveau/nvkm/engine/disp/gv100.c
// /*
//  * Copyright 2018 Red Hat Inc.
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
//! Retained native core/window/WIMM DMA channel. Worker-owned, one RPC at a time.
const std = @import("std");
const r4os = @import("r4os");
const boot = @import("gsp_boot_events.zig");
const exchange = @import("gsp_exchange.zig");
const names = @import("gsp_rm_names.zig");
const engine = @import("gsp_display_engine.zig");
const storage = @import("gsp_display_storage.zig");
pub const push = @import("gsp_display_push.zig");
pub const wire = @import("gsp_display_channel_wire.zig");
pub const Error = wire.Error || names.Error || storage.Error || push.Error;
pub const State = enum { creating, unwinding, ready, handed_off, destroying, closed, finished, failed };
pub const Info = struct { config: wire.Config, rm_allocated: bool };
pub const Owner = struct {
    self_address: usize = 0,
    exchange: exchange.Exchange,
    parent: *engine.Owner,
    parent_slot: usize,
    config: wire.Config,
    config_stamp: ?wire.Config = null,
    reservation: names.Children,
    namespace_live: bool = true,
    ctx: r4os.r4dev.DriverContext,
    adapter: u32,
    backing: storage.Storage = .{},
    ring: push.Ring = .{},
    point: @import("gsp_cursor_pio.zig").Owner = .{},
    state: State = .creating,
    pushbuffer: bool = false,
    live: bool = false,
    allocation_possible: bool = false,
    hardware_retired: bool = false,
    last_control: u32 = 0xffffffff,
    last_state: u32 = 0xffffffff,
    retirement_reads: u32 = 0,
    rejected: ?u32 = null,
    host_rejected: ?anyerror = null,
    last_status: ?u32 = null,
    failure: ?anyerror = null,
    protocol_failure: ?exchange.Error = null,
    operation: ?wire.Operation = null,
    request: [wire.max_bytes]u8 = undefined,
    deadline: u64,

    pub fn init(token: *boot.Handoff, ctx: r4os.r4dev.DriverContext, adapter: u32, parent: *engine.Owner, kind: wire.Kind, index: u32, deadline: u64) Error!Owner {
        const root = parent.info() orelse return error.State;
        const parent_slot = try wire.slot(kind, index);
        if (parent.state != .handed_off or token.session != parent.exchange.session or token.claimed or adapter == 0 or !root.instance_bound or
            parent.instance_storage.info() == null or parent.children[parent_slot] != 0) return error.State;
        if ((kind == .core and !root.core) or (kind == .window and (!root.window or parent.children[0] == 0 or root.hardware.windows & (@as(u32, 1) << @intCast(index)) == 0))) return error.Unsupported;
        if (kind == .immediate and (!root.immediate or !root.window or parent.children[0] == 0 or parent.children[1 + index] == 0 or
            root.hardware.windows & (@as(u32, 1) << @intCast(index)) == 0)) return error.Unsupported;
        if (kind == .cursor and (!root.cursor or !root.core or parent.children[0] == 0 or index >= root.hardware.heads)) return error.Unsupported;
        try token.session.guard(deadline);
        const reservation = try token.session.rm_names.reserveChildren(parent.reservation.parent, 1);
        errdefer token.session.rm_names.retireChildren(reservation) catch {};
        const handle = try reservation.object(0);
        const rpc = try exchange.Exchange.init(token, deadline);
        parent.children[parent_slot] = handle;
        return .{ .exchange = rpc, .parent = parent, .parent_slot = parent_slot, .reservation = reservation, .adapter = adapter,
            .ctx = ctx, .config = .{ .root = root.binding, .kind = kind, .index = index, .handle = handle, .physical = 0 }, .deadline = deadline };
    }
    fn stable(self: *const Owner) Error!void {
        if ((self.self_address != 0 and self.self_address != @intFromPtr(self)) or self.config.root.epoch != self.exchange.session.epoch or
            self.parent.self_address != @intFromPtr(self.parent) or self.parent_slot >= self.parent.children.len or
            !std.meta.eql(self.config.root, self.parent.binding)) return error.Stale;
        if (self.config_stamp) |stamp| if (!std.meta.eql(stamp, self.config)) return error.Stale;
        if (self.namespace_live) {
            try self.exchange.session.rm_names.validateChildren(self.reservation);
            if (self.parent.children[self.parent_slot] != self.config.handle or self.parent.instance_storage.info() == null) return error.Stale;
        }
    }
    fn fail(self: *Owner, err: Error) Error {
        self.quarantine(err); return err;
    }
    pub fn quarantine(self: *Owner, err: anyerror) void {
        self.failure = err; self.state = .failed;
        if (self.backing.self_address != 0) self.backing.retained = true;
        if (self.namespace_live) self.exchange.session.rm_names.retainChildren(self.reservation) catch {};
        self.protocol_failure = self.exchange.fail(error.Handler);
    }
    pub fn info(self: *const Owner) ?Info {
        self.stable() catch return null;
        if (self.self_address != @intFromPtr(self) or !self.live or (self.config.kind != .cursor and self.backing.physical() == null) or self.exchange.session.state != .active or
            (self.state != .ready and self.state != .handed_off)) return null;
        return .{ .config = self.config, .rm_allocated = true };
    }
    pub fn poll(self: *Owner) Error!?exchange.Dispatch {
        try self.stable();
        if (self.state != .creating and self.state != .unwinding and self.state != .destroying) return error.State;
        self.self_address = @intFromPtr(self);
        return self.advance() catch |err| { if (err == error.Pending) return err; return self.fail(err); };
    }
    fn advance(self: *Owner) Error!?exchange.Dispatch {
        try self.exchange.guard(self.deadline);
        if (self.exchange.pending != null) return error.Pending;
        if (self.backing.ready and self.backing.physical() != self.config.physical) return error.Stale;
        if (self.operation == null) {
            if (self.state == .creating and self.config.kind == .cursor and self.config_stamp == null) {
                try wire.validate(self.config); self.config_stamp = self.config;
            }
            if (self.state == .creating and self.config.kind != .cursor and !self.backing.ready) {
                self.backing.prepare(&self.ctx, self.adapter, self.config.root.epoch) catch |err| {
                    if (err == error.Descriptor or err == error.Retained) return err;
                    self.host_rejected = err; self.state = .unwinding; return null;
                };
                self.config.physical = self.backing.physical() orelse return error.Stale;
                try wire.validate(self.config); self.config_stamp = self.config; return null;
            }
            const op: wire.Operation = if (self.state == .creating) blk: {
                if (!self.pushbuffer) break :blk .pushbuffer;
                if (!self.live) break :blk .allocate;
                self.state = .ready; return null;
            } else if (self.live) .free else {
                if (self.retirementPending()) return null;
                if (!self.ring.close(self.hardware_retired)) return error.Retained;
                self.backing.retained = false;
                if (!self.backing.close()) return error.Retained;
                if (self.namespace_live) {
                    try self.exchange.session.rm_names.retireChildren(self.reservation); self.namespace_live = false;
                    self.parent.children[self.parent_slot] = 0;
                }
                self.state = if (self.state == .unwinding) .ready else .closed; return null;
            };
            const data = try wire.encode(self.config, op, &self.request);
            try self.exchange.begin(wire.function(op), data, self.deadline); self.operation = op;
            if (self.config.kind != .cursor) self.backing.retained = true;
            if (op == .allocate) self.allocation_possible = true;
        }
        const dispatch = (try self.exchange.poll(self.deadline)) orelse return null;
        if (!dispatch.response) return dispatch;
        const op = self.operation.?;
        const reply = try wire.decode(self.config, op, self.request[0..wire.lengthFor(self.config.kind, op)], dispatch.record);
        self.last_status = if (reply == .rejected) reply.rejected else 0;
        try self.exchange.complete(dispatch.ticket);
        if (reply == .rejected) {
            if (self.state != .creating) return error.FirmwareResult;
            self.rejected = reply.rejected; self.state = .unwinding;
        } else switch (op) {
            .pushbuffer => self.pushbuffer = true,
            .allocate => self.live = true,
            .free => self.live = false,
        }
        self.operation = null; return null;
    }
    pub fn retirementPending(self: *const Owner) bool {
        return (self.state == .destroying or self.state == .unwinding) and self.operation == null and !self.live and
            self.allocation_possible and !self.hardware_retired;
    }
    pub fn observeRetirement(self: *Owner, control: u32, status: u32) Error!void {
        try self.stable();
        if (!self.retirementPending() or self.exchange.phase != .idle or self.exchange.pending != null) return error.State;
        try self.exchange.guard(self.deadline);
        self.last_control = control; self.last_state = status; self.retirement_reads +|= 1;
        if (wire.retired(self.config.kind, control, status)) { self.hardware_retired = true; self.allocation_possible = false; }
    }
    pub fn beginDestroy(self: *Owner, token: *boot.Handoff, deadline: u64) Error!void {
        try self.stable();
        if (self.state != .handed_off or token.session != self.exchange.session) return error.State;
        if (self.point.pending != null) return error.Retained;
        // Core Free may purge satellites across RM clients. Our windows must
        // retire first, even if a caller claims that the GPU is quiescent.
        if (self.config.kind == .core) for (self.parent.children[1..]) |child| if (child != 0) return error.Retained;
        if (self.config.kind == .window and self.parent.children[9 + self.config.index] != 0) return error.Retained;
        self.exchange = try exchange.Exchange.init(token, deadline); self.deadline = deadline; self.state = .destroying;
    }
    pub fn handoff(self: *Owner) Error!boot.Handoff {
        try self.stable();
        if (self.state != .ready and self.state != .closed) return error.State;
        const token = try self.exchange.handoff(self.deadline);
        self.state = if (self.state == .closed) .finished else .handed_off; return token;
    }
    pub fn matches(self: *const Owner, current: *const exchange.Exchange, deadline: u64) bool {
        self.stable() catch return false;
        const op = self.operation orelse return false;
        var expected: [wire.max_bytes]u8 = undefined;
        const encoded = wire.encode(self.config, op, &expected) catch return false;
        return self.self_address == @intFromPtr(self) and current == &self.exchange and current.deadline == deadline and self.deadline == deadline and
            current.request.ptr == self.request[0..].ptr and current.request.len == wire.lengthFor(self.config.kind, op) and current.function == wire.function(op) and
            std.mem.eql(u8, current.request, encoded) and
            (if (self.config.kind == .cursor) self.config.physical == 0 and self.backing.self_address == 0
                else self.backing.physical() == self.config.physical and self.backing.retained) and
            (self.state == .creating or self.state == .unwinding or self.state == .destroying);
    }
    pub fn admitsRetirement(self: *const Owner, deadline: u64) bool {
        self.stable() catch return false;
        // An idle Exchange deliberately clears its RPC deadline. The fixed
        // channel teardown deadline owns this separate hardware operation.
        return self.self_address == @intFromPtr(self) and self.deadline == deadline and self.exchange.deadline == null and self.exchange.request.len == 0 and
            self.exchange.phase == .idle and self.exchange.pending == null and self.retirementPending() and
            (if (self.config.kind == .cursor) self.config.physical == 0 and self.backing.self_address == 0
                else self.backing.retained and self.backing.physical() == self.config.physical);
    }
};
