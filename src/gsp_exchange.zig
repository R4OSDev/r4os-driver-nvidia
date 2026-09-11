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
//! Sole runtime RPC owner shared by RM object and display-control lifecycles.
//! Borrowed request data stays stable until completion/cancel; queue backing
//! stays retained even on ambiguous failure. No semantic RPC decoding, actual
//! notification handler, hardware I/O port, allocation or device quiescence.
const std = @import("std");
const boot = @import("gsp_boot_events.zig");
pub const transport = @import("gsp_transport.zig");
pub const message = transport.message;
pub const Error = boot.Error || error{ Unexpected, Handle, Query, Obsolete, Bounds };
pub const Phase = enum { idle, prepared, waiting, handed_off, failed };
pub const Dispatch = struct { ticket: transport.Ticket, record: message.Record, response: bool };
pub const Failure = struct { reason: Error, rpc: ?message.Rpc, ticket: ?transport.Ticket };
pub const Exchange = struct {
    session: *transport.Session,
    phase: Phase = .idle,
    deadline: ?u64 = null,
    function: u32 = 0,
    request: []const u8 = &.{},
    revision: u64 = 1,
    in_lockdown: bool,
    pending: ?Dispatch = null,
    last_rpc: ?message.Rpc = null,
    failure: ?Failure = null,

    pub fn init(runtime: *boot.Handoff, deadline: u64) Error!Exchange {
        const session = runtime.session;
        if (runtime.claimed or session.state != .active or session.pending != null) return error.State;
        try session.guard(deadline);
        runtime.claimed = true;
        return .{ .session = session, .in_lockdown = runtime.in_lockdown };
    }
    /// Terminal semantic or I/O failure retains the exact receipt and first
    /// failure. This stops the CPU session, not device access to its backing.
    pub fn fail(self: *Exchange, reason: Error) Error {
        if (self.phase == .handed_off) return error.State;
        if (self.phase != .failed) {
            self.failure = .{ .reason = reason, .rpc = if (self.session.pending != null) self.last_rpc else null, .ticket = self.session.pending };
            self.phase = .failed;
            self.session.stop();
        }
        return reason;
    }
    pub fn guard(self: *Exchange, end: u64) Error!void {
        if (self.phase == .failed or self.phase == .handed_off) return error.State;
        self.session.guard(end) catch |err| return self.fail(err);
    }
    pub fn invalidate(self: *Exchange) Error!void {
        if (self.phase == .failed or self.phase == .handed_off) return error.State;
        if (self.revision == std.math.maxInt(u64)) return self.fail(error.Exhausted);
        self.revision += 1;
    }
    pub fn begin(self: *Exchange, function: u32, payload: []const u8, deadline: u64) Error!void {
        if (self.phase != .idle) return error.State;
        if (self.pending != null) return error.Pending;
        const end = @min(self.deadline orelse deadline, deadline);
        try self.guard(end);
        if (function == 0 or function >= 0x1000 or function == 71) return error.Unexpected;
        if (payload.len > message.max_payload_bytes) return error.Payload;
        self.function = function;
        self.request = payload;
        self.deadline = end;
        self.phase = .prepared;
    }
    /// Only a never-submitted request can be cancelled without a reply. A
    /// failed send may already have published, even while phase was prepared.
    pub fn cancelPrepared(self: *Exchange) Error!void {
        if (self.phase != .prepared or self.pending != null) return error.State;
        try self.guard(self.deadline.?);
        self.request = &.{};
        self.phase = .idle;
        self.deadline = null;
    }
    pub fn poll(self: *Exchange, deadline: u64) Error!?Dispatch {
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
            const response = rpc.function == self.function and self.phase == .waiting;
            if (!response) {
                if (rpc.function < 0x1002 or rpc.function >= 0x1023) return self.fail(error.Unexpected);
                if (rpc.function == @intFromEnum(boot.Kind.lockdown)) {
                    const bytes = item.record.payload;
                    if (bytes.len != 1 or bytes[0] > 1) return self.fail(error.Payload);
                    if (bytes[0] == 1) self.in_lockdown = true;
                }
                if (rpc.function != @intFromEnum(boot.Kind.libos_print)) try self.invalidate();
            }
            const dispatch = Dispatch{ .ticket = item.ticket, .record = item.record, .response = response };
            self.pending = dispatch;
            return dispatch;
        }
        // Notifications are drained before a new request is published.
        if (self.phase == .prepared and !self.in_lockdown) {
            self.session.send(end, .{ .function = self.function, .sequence = self.session.tx_sequence }, self.request) catch |err| {
                if (err == error.Unavailable) return null;
                return self.fail(err);
            };
            self.phase = .waiting;
        }
        if (self.phase == .idle) self.deadline = null;
        return null;
    }
    pub fn borrow(self: *Exchange, ticket: transport.Ticket) Error!Dispatch {
        const dispatch = self.pending orelse return error.Stale;
        try self.guard(self.deadline.?);
        if (!std.meta.eql(dispatch.ticket, ticket)) return error.Stale;
        return dispatch;
    }
    /// Semantic response admission or the actual notification handler must
    /// finish first. Ambiguous ACK is terminal and cannot replay a handler.
    pub fn complete(self: *Exchange, ticket: transport.Ticket) Error!void {
        const dispatch = try self.borrow(ticket);
        self.session.acknowledge(self.deadline.?, ticket) catch |err| return self.fail(err);
        if (dispatch.response) {
            self.request = &.{};
            self.phase = .idle;
        } else if (dispatch.record.rpc.function == @intFromEnum(boot.Kind.lockdown)) {
            self.in_lockdown = dispatch.record.payload[0] == 1;
        }
        self.pending = null;
        if (self.phase == .idle) self.deadline = null;
    }
    pub fn reject(self: *Exchange, ticket: transport.Ticket) Error!void {
        _ = try self.borrow(ticket);
        return self.fail(error.Handler);
    }
    pub fn handoff(self: *Exchange, deadline: u64) Error!boot.Handoff {
        if (self.phase != .idle or self.pending != null or self.session.pending != null) return error.State;
        try self.guard(@min(self.deadline orelse deadline, deadline));
        self.phase = .handed_off;
        return .{ .session = self.session, .in_lockdown = self.in_lockdown };
    }
};
