// NVIDIA570.144 topology controls/NVKMS (MIT), with independent Nouveau
// discovery reference (MIT). Original R4OS ownership/relations: Apache-2.0.
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
// Nvidia570.144/src/nvidia-modeset/src/nvkms-rm.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2013-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Bounded discovery of RM display/connector/resource relationships, without
//! modeset or catalog publication. RM IDs, physical connector IDs, DCB slots
//! and communication IDs are distinct namespaces. Dynamic displays never
//! become additional physical sockets merely because they have another ID.
const std = @import("std");
const graph = @import("gsp_rm_graph.zig");
const display = @import("gsp_display_rpc.zig");
const vbios = @import("vbios.zig");
pub const Error = graph.Error;
pub const max_routes = 32;
pub const Rejection = struct { command: display.Command, rpc: ?u32 = null, control: ?u32 = null };
pub const Route = struct {
    id: u32 = 0,
    connectors: ?display.Connectors = null,
    resource: ?display.Resource = null,
    buses: ?display.Buses = null,
    rejections: [3]?Rejection = @splat(null),
};
pub const Catalog = struct {
    epoch: u64 = 0,
    client: u32 = 0,
    revision: u64 = 0,
    receipt_serial: u64 = 0,
    supported: ?display.Supported = null,
    rejected: ?Rejection = null,
    count: usize = 0,
    routes: [max_routes]Route = @splat(.{}),
};
pub const State = enum { supported, connectors, resource, buses, verify, drain, complete, obsolete, failed, released };

/// A relation to the validated passive VBIOS, not an active routing lease.
/// RM's explicit dcb_index selects the original DCB slot, never log2(id).
/// Keep RM physical connector records alongside the DCB connector reference;
/// do not assume these two index namespaces are numerically identical.
pub const Relation = union(enum) { unavailable, dynamic: u32, missing, ambiguous, static: vbios.Port };
pub fn relate(route: *const Route, rom: *const vbios.Result) Relation {
    const resource = route.resource orelse return .unavailable;
    if (resource.dynamic) return .{ .dynamic = resource.root_port_id };
    if (resource.kind == 0) return .unavailable;
    if (rom.port_count > rom.ports.len) return .missing;
    var port: ?vbios.Port = null;
    for (rom.ports[0..rom.port_count]) |item| {
        if (item.index != resource.dcb_index) continue;
        if (port != null) return .ambiguous;
        port = item;
    }
    return if (port) |value| .{ .static = value } else .missing;
}

/// Catalog storage and graph remain exclusively borrowed until release.
/// One serialized worker polls; notification handlers use channel's ordinary
/// or CPU bridges. No recursive queue pump, IRQ work or automatic retry.
pub const Discovery = struct {
    owner: *graph.Owner,
    channel: display.Channel,
    catalog: *Catalog,
    state: State = .supported,
    deadline: u64,
    cursor: usize = 0,
    self_address: usize = 0,
    invalidated: bool = false,
    failure: ?Error = null,

    pub fn init(owner: *graph.Owner, catalog: *Catalog, deadline: u64) Error!Discovery {
        var loan = try owner.loan(deadline);
        errdefer owner.reclaim(&loan.runtime, deadline) catch {};
        const channel = try display.Channel.init(&loan.runtime, loan.object, deadline);
        catalog.* = .{ .epoch = loan.object.epoch, .client = loan.object.client, .revision = channel.exchange.revision };
        return .{ .owner = owner, .channel = channel, .catalog = catalog, .deadline = deadline };
    }
    fn binding(self: *Discovery) Error!void {
        if (self.state == .failed or self.state == .released) return error.State;
        if (self.self_address != 0 and self.self_address != @intFromPtr(self)) return error.Stale;
        if (self.owner.state != .loaned or self.owner.base.exchange.session != self.channel.exchange.session or
            self.owner.reservation.epoch != self.catalog.epoch or self.owner.reservation.client != self.catalog.client) return error.Stale;
    }
    fn guard(self: *Discovery) Error!void {
        try self.binding();
        try self.channel.exchange.guard(self.deadline);
        self.invalidated = self.invalidated or self.channel.exchange.revision != self.catalog.revision;
    }
    fn fail(self: *Discovery, reason: Error) Error {
        if ((self.self_address != 0 and self.self_address != @intFromPtr(self)) or self.state == .released) return error.State;
        if (self.failure == null) self.failure = reason;
        self.channel.exchange.session.stop();
        self.state = .failed;
        return reason;
    }
    pub fn invalidate(self: *Discovery) Error!void {
        try self.binding();
        self.invalidated = true;
    }
    fn query(self: *Discovery) Error!display.Query {
        return switch (self.state) {
            .supported, .verify => .supported,
            .connectors => .{ .connectors = self.catalog.routes[self.cursor].id },
            .resource => .{ .resource = self.catalog.routes[self.cursor].id },
            .buses => .{ .buses = self.catalog.routes[self.cursor].id },
            else => error.State,
        };
    }
    fn advance(self: *Discovery) void {
        switch (self.state) {
            .connectors => self.state = .resource,
            .resource => self.state = .buses,
            .buses => {
                self.cursor += 1;
                self.state = if (self.cursor == self.catalog.count) .verify else .connectors;
            },
            else => unreachable,
        }
    }
    fn consume(self: *Discovery, reply: display.Reply) Error!void {
        if (reply == .obsolete) {
            self.invalidated = true;
            return;
        }
        if (reply == .rpc_error or reply == .control_error) {
            const rejection = Rejection{ .command = std.meta.activeTag(try self.query()), .rpc = if (reply == .rpc_error) reply.rpc_error else null, .control = if (reply == .control_error) reply.control_error else null };
            if (self.state == .supported or self.state == .verify) {
                // No successful final supported-mask comparison: no usable
                // catalog, even if earlier per-display queries succeeded.
                self.catalog.rejected = rejection;
                self.catalog.count = 0;
                self.catalog.supported = null;
                self.state = .drain;
            } else {
                const index: usize = switch (self.state) {
                    .connectors => 0,
                    .resource => 1,
                    .buses => 2,
                    else => return error.State,
                };
                self.catalog.routes[self.cursor].rejections[index] = rejection;
                self.advance();
            }
            return;
        }
        switch (self.state) {
            .supported => {
                if (reply != .supported) return error.Unexpected;
                self.catalog.supported = reply.supported;
                for (0..max_routes) |bit| {
                    const id = @as(u32, 1) << @as(u5, @intCast(bit));
                    if (reply.supported.displays & id == 0) continue;
                    self.catalog.routes[self.catalog.count] = .{ .id = id };
                    self.catalog.count += 1;
                }
                self.state = if (self.catalog.count == 0) .verify else .connectors;
            },
            .verify => {
                if (reply != .supported) return error.Unexpected;
                if (!std.meta.eql(reply.supported, self.catalog.supported.?)) self.invalidated = true;
                self.state = .drain;
            },
            .connectors => {
                if (reply != .connectors) return error.Unexpected;
                self.catalog.routes[self.cursor].connectors = reply.connectors;
                self.advance();
            },
            .resource => {
                if (reply != .resource) return error.Unexpected;
                self.catalog.routes[self.cursor].resource = reply.resource;
                self.advance();
            },
            .buses => {
                if (reply != .buses) return error.Unexpected;
                self.catalog.routes[self.cursor].buses = reply.buses;
                self.advance();
            },
            else => return error.State,
        }
    }
    pub fn poll(self: *Discovery) Error!?display.Dispatch {
        if (self.state == .complete or self.state == .obsolete or self.state == .failed or self.state == .released) return error.State;
        if (self.self_address != 0 and self.self_address != @intFromPtr(self)) return error.Stale;
        self.self_address = @intFromPtr(self);
        self.guard() catch |err| return self.fail(err);
        if (self.channel.pending != null) return error.Pending;
        if (self.invalidated and self.channel.exchange.phase == .idle) {
            self.state = .obsolete;
            return null;
        }
        if (self.channel.exchange.phase == .idle and self.state != .drain) self.channel.begin(try self.query(), self.deadline) catch |err| return self.fail(err);
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
            self.catalog.receipt_serial = dispatch.ticket.serial;
            self.guard() catch |err| return self.fail(err);
            if (self.invalidated) self.state = .obsolete;
        } else if (self.state == .drain) {
            self.state = if (self.invalidated) .obsolete else .complete;
        }
        return null;
    }
    pub fn borrow(self: *Discovery, deadline: u64) Error!*const Catalog {
        if (self.state != .complete) return error.State;
        try self.binding();
        self.channel.exchange.guard(deadline) catch |err| return self.fail(err);
        if (self.invalidated or self.channel.exchange.revision != self.catalog.revision) return error.Obsolete;
        return self.catalog;
    }
    pub fn release(self: *Discovery, deadline: u64) Error!void {
        if (self.state != .complete and self.state != .obsolete and !(self.state == .supported and self.self_address == 0)) return error.State;
        try self.binding();
        var token = self.channel.handoff(deadline) catch |err| return self.fail(err);
        self.owner.reclaim(&token, deadline) catch |err| return self.fail(err);
        self.state = .released;
    }
};
