// Pinned570.144 reference semantics retain these original MIT notices.
// src/common/sdk/nvidia/inc/nvos.h
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
// src/common/sdk/nvidia/inc/class/cl90f1.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2011 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// src/nvidia/src/kernel/gpu/mem_mgr/vaspace_api.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2012-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! FERMI_VASPACE_A lifetime under the one actual RM graph and RPC token.
//! RM creates/manages page tables. This object alone maps no app buffer and
//! provides no CPU pointer, externally owned PDB or GPU completion guarantee.
const std = @import("std");
const objects = @import("gsp_objects.zig");
const exchange = @import("gsp_exchange.zig");
const boot = @import("gsp_boot_events.zig");
pub const Error = objects.Error;
pub const State = enum { creating, ready, handed_off, destroying, closed, finished, failed };
pub const Info = struct { epoch: u64, client: u32, device: u32, handle: u32, base: u64, bytes: u64, big_page_bytes: u32 };

/// Pinned570.144 vaspaceapiConstruct_IMPL returns vaBase and a BYTE LENGTH
/// (limit - base + 1). The nvos.h comment describes an exclusive limit; the
/// actual implementation is authoritative for this pinned firmware protocol.
pub fn decodeInfo(plan: *const objects.Plan, bytes: []const u8) Error!Info {
    if (bytes.len != 80) return error.Payload;
    const params = bytes[32..];
    for ([_]usize{ 0, 4, 16, 20, 24, 28, 36 }) |at|
        if (std.mem.readInt(u32, params[at..][0..4], .little) != 0) return error.Payload;
    const big_page = std.mem.readInt(u32, params[32..36], .little);
    const base = std.mem.readInt(u64, params[40..48], .little);
    const length = std.mem.readInt(u64, params[8..16], .little);
    const limit: u64 = 1 << 49; // Supported GA106 v2 GPU VA width, not CPU VA.
    if (big_page != 65536 or base == 0 or base >= limit or length == 0 or length > limit - base or
        (base | length) & 4095 != 0) return error.Bounds;
    return .{ .epoch = plan.epoch, .client = plan.handles.client, .device = plan.handles.device, .handle = plan.handles.vaspace, .base = base, .bytes = length, .big_page_bytes = big_page };
}

pub const Owner = struct {
    exchange: exchange.Exchange,
    plan: objects.Plan,
    deadline: u64,
    state: State = .creating,
    info: ?Info = null,
    rejected: ?u32 = null,
    outstanding: ?objects.Operation = null,
    request: [80]u8 = undefined,
    self_address: usize = 0,

    pub fn init(token: *boot.Handoff, plan: objects.Plan, deadline: u64) Error!Owner {
        try plan.validate();
        if (plan.handles.vaspace == 0 or plan.epoch != token.session.epoch) return error.Handle;
        return .{ .exchange = try exchange.Exchange.init(token, deadline), .plan = plan, .deadline = deadline };
    }
    fn stable(self: *Owner) Error!void {
        if (self.self_address != 0 and self.self_address != @intFromPtr(self)) return error.Stale;
        if (self.plan.epoch != self.exchange.session.epoch) return error.Stale;
    }
    fn fail(self: *Owner, reason: Error) Error {
        self.state = .failed;
        return self.exchange.fail(reason);
    }
    pub fn poll(self: *Owner) Error!?exchange.Dispatch {
        try self.stable();
        if (self.state != .creating and self.state != .destroying) return error.State;
        self.self_address = @intFromPtr(self);
        self.exchange.guard(self.deadline) catch |err| return self.fail(err);
        if (self.exchange.pending != null) return error.Pending;
        if (self.outstanding == null) {
            if (self.state == .destroying and self.info == null) {
                self.state = .closed;
                return null;
            }
            const operation: objects.Operation = if (self.state == .creating) .{ .allocate = .vaspace } else .{ .free = .vaspace };
            const encoded = try objects.encode(&self.plan, operation, &self.request);
            try self.exchange.begin(encoded.function, encoded.bytes, self.deadline);
            self.outstanding = operation;
        }
        const dispatch = (self.exchange.poll(self.deadline) catch |err| return self.fail(err)) orelse return null;
        if (!dispatch.response) return dispatch;
        const operation = self.outstanding.?;
        const reply = objects.decode(&self.plan, operation, dispatch.record) catch |err| return self.fail(err);
        if (reply == .rpc_error) return self.fail(error.FirmwareResult);
        const info = if (reply == .ok and operation == .allocate)
            decodeInfo(&self.plan, dispatch.record.payload) catch |err| return self.fail(err)
        else
            null;
        self.exchange.complete(dispatch.ticket) catch |err| return self.fail(err);
        if (reply == .rm_error and operation == .free) return self.fail(error.FirmwareResult);
        self.outstanding = null;
        if (operation == .allocate) {
            self.info = info;
            if (reply == .rm_error) self.rejected = reply.rm_error;
            self.state = .ready;
        } else {
            self.info = null;
            self.state = .closed;
        }
        return null;
    }
    pub fn handoff(self: *Owner, deadline: u64) Error!boot.Handoff {
        try self.stable();
        if (self.state != .ready and self.state != .closed) return error.State;
        const token = try self.exchange.handoff(deadline);
        self.state = if (self.state == .ready) .handed_off else .finished;
        return token;
    }
    pub fn beginDestroy(self: *Owner, token: *boot.Handoff, deadline: u64) Error!void {
        try self.stable();
        if (self.state != .handed_off or token.session != self.exchange.session) return error.State;
        self.exchange = try exchange.Exchange.init(token, deadline);
        self.deadline = deadline;
        self.state = .destroying;
    }
    pub fn matches(self: *const Owner, current: *const exchange.Exchange, deadline: u64) bool {
        if (self.self_address != @intFromPtr(self) or self.outstanding == null or
            (self.state != .creating and self.state != .destroying)) return false;
        const allocate = self.outstanding.? == .allocate;
        return current == &self.exchange and current.phase == .prepared and current.pending == null and
            current.deadline == deadline and self.deadline == deadline and current.session.epoch == self.plan.epoch and
            current.request.ptr == self.request[0..].ptr and current.request.len == @as(usize, if (allocate) 80 else 16) and
            current.function == @as(u32, if (allocate) 103 else 10);
    }
};
