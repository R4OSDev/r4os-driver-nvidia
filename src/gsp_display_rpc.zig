// RM wire ABI and query fields: NVIDIA 570.144 (MIT).
// Notification/request separation also informed by Nouveau r535 (MIT).
// Original R4OS bounded state/ownership/generation policy: Apache-2.0.
// src/nvidia/generated/g_rpc-structures.h
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
// src/common/sdk/nvidia/inc/ctrl/ctrl0073/ctrl0073system.h
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
// src/common/sdk/nvidia/inc/ctrl/ctrl0073/ctrl0073specific.h
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
// drivers/gpu/drm/nouveau/nvkm/subdev/gsp/rm/r535/rpc.c
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
//! Bounded RM display controls over one post-boot GSP queue owner.
//! Fixed flat NV0073 queries only; no object allocation, FINN serialization,
//! continuation records, register access, callback execution or DMA release.
//! The native caller must supply an actually allocated, retained RM object.
const std = @import("std");
const boot_events = @import("gsp_boot_events.zig");
const exchange = @import("gsp_exchange.zig");
const transport = exchange.transport;
const message = transport.message;
pub const Error = boot_events.Error || error{ Handle, Query, Unexpected, Obsolete, Bounds };
pub const function: u32 = 76;
pub const header_bytes = 24;
pub const max_edid_bytes = 2048;
pub const max_request_bytes = header_bytes + 16 + max_edid_bytes;
pub const Command = enum(u32) { supported = 0x730107, connected = 0x730108, edid = 0x730245, connectors = 0x730250, resource = 0x73028b, buses = 0x730211 };
pub const Query = union(Command) { supported: void, connected: u32, edid: u32, connectors: u32, resource: u32, buses: u32 };
pub const Object = struct { epoch: u64, client: u32, display: u32 };
pub const Supported = struct { displays: u32, ddc: u32 };
pub const Connector = struct { index: u32 = 0, kind: u32 = 0, location: u32 = 0 };
pub const Connectors = struct {
    flags: u32,
    ddc_partners: u32,
    count: u32,
    data: [4]Connector = @splat(.{}),
    platform: u32,
    pub fn present(self: Connectors) bool {
        return self.flags & 1 != 0;
    }
};
pub const Resource = struct {
    // The current RM resource index can be unassigned (ffffffff); it is
    // neither a VBIOS candidate mask nor proof of a live head assignment.
    index: u32,
    kind: u32,
    protocol: u32,
    dither_type: u32,
    dither_algo: u32,
    location: u32,
    root_port_id: u32,
    dcb_index: u32,
    vbios_address: u64,
    lit_by_vbios: bool,
    dynamic: bool,
};
pub const Buses = struct { communication: u32, ddc: u32 }; // RM port IDs; zero means NONE, not CCB index 0.
pub const Reply = union(enum) {
    supported: Supported,
    connected: u32,
    connectors: Connectors,
    resource: Resource,
    buses: Buses,
    // Raw, bounded bytes only. An empty blob is not an EDID; the receiver
    // parser must validate the header, all advertised blocks and checksums.
    edid: []const u8,
    rpc_error: u32,
    control_error: u32,
    obsolete: void,
};
pub const Dispatch = struct {
    ticket: transport.Ticket,
    rpc: message.Rpc,
    value: union(enum) { reply: Reply, notification: []const u8 },
};
pub const Phase = exchange.Phase;
pub const Failure = exchange.Failure;

fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
fn put(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn paramsSize(query: Query) usize {
    return switch (query) {
        .supported => 12,
        .connected => 16,
        .edid => 16 + max_edid_bytes,
        .connectors => 72,
        .resource => 56,
        .buses => 16,
    };
}
fn oneBit(mask: u32) bool {
    return mask != 0 and mask & (mask - 1) == 0;
}

/// Encode only these pointer-free, fixed-size vendor structures. RPC flags
/// remain NONE: neither serialized data nor copyout-on-error is requested.
/// Output-only fields and the complete EDID array start at zero.
pub fn encode(object: Object, query: Query, output: []u8) Error![]const u8 {
    if (object.epoch == 0 or object.client == 0 or object.display == 0) return error.Handle;
    switch (query) {
        .supported => {},
        .connected => |mask| if (mask == 0) return error.Query,
        .edid, .connectors, .resource, .buses => |id| if (!oneBit(id)) return error.Query,
    }
    const size = paramsSize(query);
    if (output.len < header_bytes + size) return error.Bounds;
    const bytes = output[0 .. header_bytes + size];
    @memset(bytes, 0);
    put(bytes, 0, object.client);
    put(bytes, 4, object.display);
    put(bytes, 8, @intFromEnum(std.meta.activeTag(query)));
    put(bytes, 16, @intCast(size));
    // subDeviceInstance=0, default CONNECT_STATE (not cached), EDID RAW
    // with COPY_CACHE=NO and DISPMUX=DEFAULT. Display IDs are RM masks,
    // never VBIOS physical connector indices or GPIO numbers.
    switch (query) {
        .supported => {},
        .connected => |mask| put(bytes, header_bytes + 8, mask),
        .connectors, .resource, .buses => |id| put(bytes, header_bytes + 4, id),
        .edid => |id| {
            put(bytes, header_bytes + 4, id);
            put(bytes, header_bytes + 12, 2);
        },
    }
    return bytes;
}

/// Validate a single complete reply, after outer framing/checksum admission.
/// The serialized channel and returned object/command identify the response;
/// RPC sequence/private are raw diagnostics, not an assumed echoed request ID.
pub fn decode(object: Object, query: Query, record: message.Record) Error!Reply {
    if (record.rpc.function != function) return error.Unexpected;
    if (record.rpc.cpu_rm_gfid != 0) return error.Guest;
    if (record.rpc.result == 0xffffffff) return error.Payload;
    if (record.rpc.result != 0) return .{ .rpc_error = record.rpc.result };
    const bytes = record.payload;
    const size = paramsSize(query);
    if (bytes.len != header_bytes + size) return error.Payload;
    if (word(bytes, 0) != object.client or word(bytes, 4) != object.display or
        word(bytes, 8) != @intFromEnum(std.meta.activeTag(query))) return error.Unexpected;
    if (word(bytes, 16) != size or word(bytes, 20) != 0) return error.Payload;
    const status = word(bytes, 12);
    // NONE disallows using even retry-time/output bytes on a control error.
    if (status != 0) return .{ .control_error = status };
    const params = bytes[header_bytes..];
    if (word(params, 0) != 0) return error.Unexpected;
    return switch (query) {
        .supported => blk: {
            const supported = Supported{ .displays = word(params, 4), .ddc = word(params, 8) };
            if (supported.ddc & ~supported.displays != 0) return error.Payload;
            break :blk .{ .supported = supported };
        },
        .connected => |mask| blk: {
            if (word(params, 4) != 0 or word(params, 8) & ~mask != 0) return error.Payload;
            break :blk .{ .connected = word(params, 8) };
        },
        .edid => |id| blk: {
            if (word(params, 4) != id or word(params, 12) != 2) return error.Unexpected;
            const count = word(params, 8);
            if (count > max_edid_bytes) return error.Payload;
            break :blk .{ .edid = params[16..][0..count] };
        },
        .connectors => |id| blk: {
            if (word(params, 4) != id) return error.Unexpected;
            const count = word(params, 16);
            if (count > 4) return error.Payload;
            var value = Connectors{ .flags = word(params, 8), .ddc_partners = word(params, 12), .count = count, .platform = word(params, 68) };
            for (value.data[0..count], 0..) |*item, i| item.* = .{ .index = word(params, 20 + i * 12), .kind = word(params, 24 + i * 12), .location = word(params, 28 + i * 12) };
            break :blk .{ .connectors = value };
        },
        .resource => |id| blk: {
            if (word(params, 4) != id) return error.Unexpected;
            if (params[48] > 1 or params[49] > 1) return error.Payload;
            // Six trailing C padding bytes carry no fields or constraints.
            break :blk .{ .resource = .{ .index = word(params, 8), .kind = word(params, 12), .protocol = word(params, 16), .dither_type = word(params, 20), .dither_algo = word(params, 24), .location = word(params, 28), .root_port_id = word(params, 32), .dcb_index = word(params, 36), .vbios_address = std.mem.readInt(u64, params[40..48], .little), .lit_by_vbios = params[48] != 0, .dynamic = params[49] != 0 } };
        },
        .buses => |id| blk: {
            if (word(params, 4) != id) return error.Unexpected;
            break :blk .{ .buses = .{ .communication = word(params, 8), .ddc = word(params, 12) } };
        },
    };
}

pub const Channel = struct {
    exchange: exchange.Exchange,
    object: Object,
    request: ?Query = null,
    request_bytes: [max_request_bytes]u8 = undefined,
    request_revision: u64 = 0,
    supported: ?Supported = null,
    connected: u32 = 0,
    pending: ?Dispatch = null,

    /// Claim the sole runtime queue after actual RM object allocation. Handles
    /// and all backing remain retained in this epoch; this API does not create
    /// them. Keep this value stable while a request or dispatch is outstanding.
    pub fn init(runtime: *boot_events.Handoff, object: Object, deadline: u64) Error!Channel {
        if (object.epoch != runtime.session.epoch or object.client == 0 or object.display == 0) return error.Handle;
        return .{ .exchange = try exchange.Exchange.init(runtime, deadline), .object = object };
    }
    fn fail(self: *Channel, reason: Error) Error {
        self.connected = 0;
        return self.exchange.fail(reason);
    }
    pub fn invalidate(self: *Channel) Error!void {
        try self.exchange.invalidate();
        self.connected = 0;
    }
    pub fn begin(self: *Channel, query: Query, deadline: u64) Error!void {
        if (self.exchange.phase != .idle) return error.State;
        if (self.pending != null) return error.Pending;
        self.exchange.guard(@min(self.exchange.deadline orelse deadline, deadline)) catch |err| return self.fail(err);
        switch (query) {
            .supported => {},
            .connected => |mask| {
                const available = self.supported orelse return error.Query;
                if (mask == 0 or mask & ~available.displays != 0) return error.Query;
            },
            .edid => |id| if (!oneBit(id) or id & self.connected == 0) return error.Query,
            .connectors, .resource, .buses => |id| {
                const available = self.supported orelse return error.Query;
                if (!oneBit(id) or id & available.displays == 0) return error.Query;
            },
        }
        const bytes = try encode(self.object, query, &self.request_bytes);
        try self.exchange.begin(function, bytes, deadline);
        self.request = query;
        self.request_revision = self.exchange.revision;
        if (query == .connected) self.connected &= ~query.connected;
    }
    pub fn poll(self: *Channel, deadline: u64) Error!?Dispatch {
        if (self.exchange.phase == .prepared and self.pending == null and
            self.request.? != .supported and self.request_revision != self.exchange.revision)
        {
            const end = @min(self.exchange.deadline.?, deadline);
            self.exchange.guard(end) catch |err| return self.fail(err);
            self.exchange.deadline = end;
            self.exchange.cancelPrepared() catch |err| return self.fail(err);
            self.request = null;
            return error.Obsolete;
        }
        const old_revision = self.exchange.revision;
        const received = self.exchange.poll(deadline) catch |err| {
            if (err == error.Pending) return err;
            return self.fail(err);
        } orelse return null;
        if (self.exchange.revision != old_revision) self.connected = 0;
        var dispatch = Dispatch{ .ticket = received.ticket, .rpc = received.record.rpc, .value = undefined };
        if (received.response) {
            var reply = decode(self.object, self.request.?, received.record) catch |err| return self.fail(err);
            if (reply != .supported and self.request_revision != self.exchange.revision) reply = .obsolete;
            dispatch.value = .{ .reply = reply };
        } else {
            dispatch.value = .{ .notification = received.record.payload };
        }
        self.pending = dispatch;
        return dispatch;
    }
    pub fn borrow(self: *Channel, ticket: transport.Ticket) Error!Dispatch {
        _ = self.exchange.borrow(ticket) catch |err| {
            if (err == error.Stale and self.exchange.phase != .failed) return err;
            return self.fail(err);
        };
        var dispatch = self.pending orelse return error.Stale;
        if (dispatch.value == .reply and
            dispatch.value.reply != .supported and self.request_revision != self.exchange.revision)
        {
            dispatch.value = .{ .reply = .obsolete };
            self.pending = dispatch;
        }
        return dispatch;
    }
    pub fn complete(self: *Channel, ticket: transport.Ticket) Error!void {
        const dispatch = try self.borrow(ticket);
        self.exchange.complete(ticket) catch |err| return self.fail(err);
        switch (dispatch.value) {
            .reply => |reply| {
                switch (reply) {
                    .supported => |value| {
                        self.supported = value;
                        self.connected = 0;
                    },
                    .connected => |mask| self.connected = (self.connected & ~self.request.?.connected) | mask,
                    else => {},
                }
                self.request = null;
            },
            .notification => {},
        }
        self.pending = null;
    }
    pub fn reject(self: *Channel, ticket: transport.Ticket) Error!void {
        _ = try self.borrow(ticket);
        return self.fail(error.Handler);
    }
    pub fn handoff(self: *Channel, deadline: u64) Error!boot_events.Handoff {
        if (self.pending != null) return error.State;
        const runtime = try self.exchange.handoff(deadline);
        self.connected = 0;
        self.supported = null;
        return runtime;
    }
};
