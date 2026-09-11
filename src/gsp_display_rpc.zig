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
const transport = @import("gsp_transport.zig");
const message = transport.message;
pub const Error = boot_events.Error || error{ Handle, Query, Unexpected, Obsolete, Bounds };
pub const function: u32 = 76;
pub const header_bytes = 24;
pub const max_edid_bytes = 2048;
pub const max_request_bytes = header_bytes + 16 + max_edid_bytes;
pub const Command = enum(u32) { supported = 0x730107, connected = 0x730108, edid = 0x730245 };
pub const Query = union(Command) { supported: void, connected: u32, edid: u32 };
pub const Object = struct { epoch: u64, client: u32, display: u32 };
pub const Supported = struct { displays: u32, ddc: u32 };
pub const Reply = union(enum) {
    supported: Supported,
    connected: u32,
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
pub const Phase = enum { idle, prepared, waiting, handed_off, failed };
pub const Failure = struct { reason: Error, rpc: ?message.Rpc, ticket: ?transport.Ticket };

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
        .edid => |id| if (!oneBit(id)) return error.Query,
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
    };
}

pub const Channel = struct {
    session: *transport.Session,
    object: Object,
    phase: Phase = .idle,
    deadline: ?u64 = null,
    request: ?Query = null,
    request_bytes: [max_request_bytes]u8 = undefined,
    request_size: usize = 0,
    request_revision: u64 = 0,
    revision: u64 = 1,
    supported: ?Supported = null,
    connected: u32 = 0,
    in_lockdown: bool,
    pending: ?Dispatch = null,
    last_rpc: ?message.Rpc = null,
    failure: ?Failure = null,

    /// Claim the post-boot runtime queue once, after its preceding owner has
    /// allocated the RM client and NV04_DISPLAY_COMMON object. Keep those
    /// actual handles and all backing alive in this epoch. This API does not
    /// allocate or prove handles; it permits the required allocation phase
    /// between INIT_DONE and display controls without a second queue owner.
    pub fn init(runtime: *boot_events.Handoff, object: Object, deadline: u64) Error!Channel {
        const session = runtime.session;
        if (runtime.claimed or session.state != .active or session.pending != null) return error.State;
        if (object.epoch != session.epoch or object.client == 0 or object.display == 0) return error.Handle;
        try session.guard(deadline);
        runtime.claimed = true;
        return .{ .session = session, .object = object, .in_lockdown = runtime.in_lockdown };
    }
    fn fail(self: *Channel, reason: Error) Error {
        self.failure = .{ .reason = reason, .rpc = if (self.session.pending != null) self.last_rpc else null, .ticket = self.session.pending };
        self.phase = .failed;
        self.connected = 0;
        self.session.stop();
        return reason;
    }
    fn guard(self: *Channel, end: u64) Error!void {
        if (self.phase == .failed or self.phase == .handed_off) return error.State;
        self.session.guard(end) catch |err| return self.fail(err);
    }
    /// Invalidate discovery after a topology/lifetime event, including one
    /// received outside this dispatcher. An in-flight result then stays obsolete
    /// even if its bytes arrive successfully; explicit fresh queries are needed.
    pub fn invalidate(self: *Channel) Error!void {
        if (self.phase == .failed or self.phase == .handed_off) return error.State;
        if (self.revision == std.math.maxInt(u64)) return self.fail(error.Exhausted);
        self.revision += 1;
        self.connected = 0;
    }
    pub fn begin(self: *Channel, query: Query, deadline: u64) Error!void {
        if (self.phase != .idle) return error.State;
        if (self.pending != null) return error.Pending;
        const end = @min(self.deadline orelse deadline, deadline);
        try self.guard(end);
        switch (query) {
            .supported => {},
            .connected => |mask| {
                const available = self.supported orelse return error.Query;
                if (mask == 0 or mask & ~available.displays != 0) return error.Query;
            },
            .edid => |id| if (!oneBit(id) or id & self.connected == 0) return error.Query,
        }
        const bytes = try encode(self.object, query, &self.request_bytes);
        self.request_size = bytes.len;
        self.request = query;
        self.request_revision = self.revision;
        self.deadline = end;
        self.phase = .prepared;
        // An unsuccessful fresh probe cannot leave the queried displays marked
        // connected using the preceding probe's result.
        if (query == .connected) self.connected &= ~query.connected;
    }

    /// One receive or send attempt. Drain notifications before publishing a
    /// prepared command. Busy queues and lockdown keep the original deadline;
    /// callers may shorten but never extend it through rescheduling. Idle polls
    /// use their own budget, pinned until a returned dispatch is completed.
    pub fn poll(self: *Channel, deadline: u64) Error!?Dispatch {
        const end = @min(self.deadline orelse deadline, deadline);
        try self.guard(end);
        self.deadline = end;
        if (self.pending != null) return error.Pending;
        const received = self.session.receive(end) catch |err| {
            if (err == error.NotReady) return null;
            return self.fail(err);
        };
        if (received) |item| {
            const rpc = item.record.rpc;
            self.last_rpc = rpc;
            if (rpc.cpu_rm_gfid != 0) return self.fail(error.Guest);
            var dispatch = Dispatch{ .ticket = item.ticket, .rpc = rpc, .value = undefined };
            if (rpc.function == function) {
                if (self.phase != .waiting) return self.fail(error.Unexpected);
                var reply = decode(self.object, self.request.?, item.record) catch |err| return self.fail(err);
                if ((reply == .connected or reply == .edid) and self.request_revision != self.revision) reply = .obsolete;
                dispatch.value = .{ .reply = reply };
            } else {
                // Pinned event range excludes sentinels and a second INIT_DONE.
                // Other RPC functions (including continuation 71) are never
                // silently treated as notifications or matching responses.
                if (rpc.function < 0x1002 or rpc.function >= 0x1023) return self.fail(error.Unexpected);
                if (rpc.function == @intFromEnum(boot_events.Kind.lockdown)) {
                    const bytes = item.record.payload;
                    if (bytes.len != 1 or bytes[0] > 1) return self.fail(error.Payload);
                    if (bytes[0] == 1) self.in_lockdown = true;
                }
                // Text-only LIBOS output cannot change topology. All other
                // events conservatively retire discovery; their actual effects
                // still require the caller's matching handler before ACK.
                if (rpc.function != @intFromEnum(boot_events.Kind.libos_print)) try self.invalidate();
                dispatch.value = .{ .notification = item.record.payload };
            }
            self.pending = dispatch;
            return dispatch;
        }
        if (self.phase == .prepared and self.request.? != .supported and self.request_revision != self.revision) {
            self.request = null;
            self.phase = .idle;
            self.deadline = null;
            return error.Obsolete;
        }
        if (self.phase == .prepared and !self.in_lockdown) {
            // Diagnostic RPC sequence follows this retained session's complete
            // publication count, including the preceding object-owner traffic.
            self.session.send(end, .{ .function = function, .sequence = self.session.tx_sequence }, self.request_bytes[0..self.request_size]) catch |err| {
                if (err == error.Unavailable) return null;
                return self.fail(err);
            };
            self.phase = .waiting;
        }
        if (self.phase == .idle) self.deadline = null;
        return null;
    }

    pub fn borrow(self: *Channel, ticket: transport.Ticket) Error!Dispatch {
        var dispatch = self.pending orelse return error.Stale;
        try self.guard(self.deadline.?);
        if (!std.meta.eql(dispatch.ticket, ticket)) return error.Stale;
        if (dispatch.value == .reply and
            (dispatch.value.reply == .connected or dispatch.value.reply == .edid) and self.request_revision != self.revision)
        {
            dispatch.value = .{ .reply = .obsolete };
            self.pending = dispatch;
        }
        return dispatch;
    }
    /// Reply bytes have been consumed, or the notification's actual handler
    /// completed. Parsing a notification does not satisfy this contract.
    /// An ambiguous ACK retains all receipts/backing and is never retried.
    pub fn complete(self: *Channel, ticket: transport.Ticket) Error!void {
        const dispatch = try self.borrow(ticket);
        self.session.acknowledge(self.deadline.?, ticket) catch |err| return self.fail(err);
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
                self.phase = .idle;
            },
            .notification => |bytes| {
                if (dispatch.rpc.function == @intFromEnum(boot_events.Kind.lockdown)) self.in_lockdown = bytes[0] == 1;
            },
        }
        self.pending = null;
        if (self.phase == .idle) self.deadline = null;
    }
    pub fn reject(self: *Channel, ticket: transport.Ticket) Error!void {
        _ = try self.borrow(ticket);
        return self.fail(error.Handler);
    }
    /// Return sole queue ownership to the runtime, e.g. for actual RM object
    /// destruction. Only an idle, fully acknowledged channel can transfer.
    /// Failed or in-flight work cannot be recycled into another live owner.
    pub fn handoff(self: *Channel, deadline: u64) Error!boot_events.Handoff {
        if (self.phase != .idle or self.pending != null or self.session.pending != null) return error.State;
        try self.guard(@min(self.deadline orelse deadline, deadline));
        self.phase = .handed_off;
        self.connected = 0;
        self.supported = null;
        return .{ .session = self.session, .in_lockdown = self.in_lockdown };
    }
};
