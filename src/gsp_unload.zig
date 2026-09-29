//! Orderly bare-metal RM unload, before FWSEC-SB/Booter Unload.
//! An RPC reply and processor suspend are not a GPU-DMA quiescence proof.
// RM570.144 rpcUnloadingGuestDriver_v1F_07 / kgspUnloadRm_IMPL /
// kgspWaitForProcessorSuspend_TU102. NVIDIA ABI/ordering portions: MIT.
// SPDX-FileCopyrightText: Copyright (c) 2008-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: MIT
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
// Original R4OS bounded owner and admission: Apache-2.0.
const std = @import("std");
const exchange = @import("gsp_exchange.zig");

// Checked against C sizeof/offsetof of the complete pinned vendor headers
// by the existing firmware ABI verifier. No translated extern-struct size.
pub const function: u32 = 47;
pub const payload_bytes = 8;
pub const suspended: u32 = 0x80000000;
pub const Phase = enum { detached, request, processor_wait, complete };
pub const Owner = struct {
    self_address: usize = 0,
    channel: ?*exchange.Exchange = null,
    epoch: u64 = 0,
    deadline: u64 = 0,
    phase: Phase = .detached,
    // Normal unload: bInPMTransition=false, bGc6Entering=false, newLevel=0.
    request: [payload_bytes]u8 = @splat(0),
    reply: ?exchange.message.Rpc = null,
    reply_bytes: usize = 0,
    last_mailbox: ?u32 = null,
    observations: u64 = 0,
    failure: ?anyerror = null,

    pub fn open(self: *Owner, channel: *exchange.Exchange, deadline: u64) !void {
        if (self.self_address != 0 or channel.phase != .idle or channel.pending != null or
            channel.session.pending != null or channel.session.state != .active or channel.in_lockdown) return error.State;
        try channel.guard(deadline);
        self.* = .{ .self_address = @intFromPtr(self), .channel = channel,
            .epoch = channel.session.epoch, .deadline = deadline, .phase = .request };
        errdefer |err| self.failure = err;
        try channel.begin(function, &self.request, deadline);
    }
    fn guard(self: *Owner) !*exchange.Exchange {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.failure != null) return error.State;
        const channel = self.channel orelse return error.State;
        if (channel.session.epoch != self.epoch) return error.Stale;
        try channel.guard(self.deadline);
        return channel;
    }
    pub fn matches(self: *const Owner, channel: *const exchange.Exchange, deadline: u64) bool {
        return self.self_address == @intFromPtr(self) and self.failure == null and self.phase == .request and
            self.channel == channel and self.epoch == channel.session.epoch and self.deadline == deadline and
            channel.deadline == deadline and channel.phase == .prepared and channel.function == function and
            channel.request.ptr == self.request[0..].ptr and channel.request.len == payload_bytes and
            std.mem.allEqual(u8, &self.request, 0);
    }
    pub fn waitingForSuspend(self: *const Owner, channel: *const exchange.Exchange, deadline: u64) bool {
        return self.self_address == @intFromPtr(self) and self.failure == null and self.phase == .processor_wait and
            self.channel == channel and self.epoch == channel.session.epoch and self.deadline == deadline and
            self.reply != null and self.reply.?.function == function and self.reply.?.result == 0 and
            channel.phase == .idle and channel.pending == null and channel.session.pending == null and !channel.in_lockdown;
    }
    /// Return interleaved notifications to the existing runtime dispatcher.
    /// A malformed/rejected reply or ambiguous ACK retains the exact receipt.
    pub fn poll(self: *Owner) !?exchange.Dispatch {
        const channel = try self.guard();
        if (self.phase != .request) return error.State;
        errdefer |err| self.failure = err;
        const dispatch = (try channel.poll(self.deadline)) orelse return null;
        if (!dispatch.response) return dispatch;
        const received = try channel.borrow(dispatch.ticket);
        if (!received.response or received.record.rpc.function != function) return error.Unexpected;
        self.reply = received.record.rpc;
        self.reply_bytes = received.record.payload.len;
        // The original consumes only RPC status. No invented payload/sequence
        // echo requirement: queue framing and the exact receipt remain checked.
        if (received.record.rpc.result != 0) return error.UnloadRejected;
        try channel.complete(received.ticket);
        self.phase = .processor_wait;
        return null;
    }
    pub fn observe(self: *Owner, mailbox: u32) !bool {
        const channel = try self.guard();
        if (!self.waitingForSuspend(channel, self.deadline)) return error.State;
        self.last_mailbox = mailbox;
        self.observations +|= 1;
        if (mailbox == std.math.maxInt(u32)) { self.failure = error.Unavailable; return error.Unavailable; }
        if (mailbox != suspended) return false;
        self.phase = .complete;
        return true;
    }
};
