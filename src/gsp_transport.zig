// Notify-after-publication follows NVIDIA570.144 kernel_gsp.c (MIT).
// src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2019-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Single-owner GSP message transport over an externally retained range-I/O
//! port and an explicit device notification. No allocation, polling loop,
//! RPC dispatch, register policy, reset or free.
//! The port must synchronize only the selected bytes and keep backing alive
//! through actual device quiescence, including after this owner fails.
// Publication/sequence rules adapted from NVIDIA 570.144 message_queue_cpu.c.
// Original R4OS interfaces and ownership: Apache-2.0. NVIDIA portions: MIT.
// Copyright (c) 2019-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
const std = @import("std");
pub const message = @import("gsp_message.zig");
pub const ring = @import("gsp_ring.zig");
pub const Error = ring.Error || error{ State, Stale, Deadline, Clock, Io, PeerProgress, Pending, Exhausted, Notification };
pub const State = enum { linking, active, failed };
pub const Ticket = struct { epoch: u64, serial: u64, sequence: u32, cursor: u32, next: u32 };
pub const Received = struct { ticket: Ticket, record: message.Record };
pub const Notification = struct {
    context: *anyopaque,
    generation: *const fn (*anyopaque) u64,
    // Admit notification and retain the whole device run BEFORE publishing
    // any command bytes. No queue pointer/scratch may escape these calls.
    prepare: *const fn (*anyopaque, u64) anyerror!void,
    // Order all preceding queue writes before one device notification. A
    // failure may have notified firmware already; neither phase is retried.
    submit: *const fn (*anyopaque, u64) anyerror!void,
};
pub const Port = struct {
    context: *anyopaque,
    generation: *const fn (*anyopaque) u64,
    now_ns: *const fn (*anyopaque) u64,
    // Read acquires a stable CPU snapshot; publish completes the selected
    // bytes' device synchronization before returning. Neither callback may
    // retain scratch pointers; failure may already have performed the I/O.
    // The absolute operation deadline travels with every callback. Providers
    // must not replace it with a fresh duration or an unrelated boot limit.
    read: *const fn (*anyopaque, u64, ring.Queue, usize, []u8) anyerror!void,
    publish: *const fn (*anyopaque, u64, ring.Queue, usize, []const u8) anyerror!void,
    // A memory-only port supports receive/ACK. Sending without a bound
    // notifier fails before any queue I/O; never silently rely on polling.
    notification: ?Notification = null,
};

pub const Session = struct {
    port: Port,
    profile: message.Profile,
    epoch: u64,
    tx: *[message.max_bytes]u8,
    rx: *[message.max_bytes]u8,
    state: State = .linking,
    link: ?ring.Link = null,
    link_deadline: ?u64 = null,
    last_clock: u64 = 0,
    last_io_error: ?anyerror = null,
    tx_write: u32 = 0,
    tx_peer_read: u32 = 0,
    rx_read: u32 = 0,
    rx_peer_write: u32 = 0,
    tx_sequence: u32 = 0,
    rx_sequence: u32 = 0,
    next_ticket: u64 = 1,
    pending: ?Ticket = null,
    preloaded: bool = false,
    preload_layout: ?ring.Layout = null,
    // The sole RM namespace survives all Boot/Exchange/display handoffs.
    // Only the serialized graph owner mutates it; transport I/O never does.
    rm_names: @import("gsp_rm_names.zig").Ledger,

    /// Backing, port, scratch and this value are borrowed by one execution
    /// owner. Do not copy/rebind an active session or overlap its scratch with
    /// DMA backing. A new epoch requires a genuinely new/quiesced device run.
    pub fn init(port: Port, profile: message.Profile, epoch: u64, tx: *[message.max_bytes]u8, rx: *[message.max_bytes]u8) Error!Session {
        if (profile.chip_id != 0x176 or profile.confidential_compute) return error.Profile;
        if (epoch == 0) return error.Stale;
        const a = @intFromPtr(tx);
        const b = @intFromPtr(rx);
        if ((if (a >= b) a - b else b - a) < message.max_bytes) return error.Overlap;
        return .{ .port = port, .profile = profile, .epoch = epoch, .tx = tx, .rx = rx, .rm_names = try @import("gsp_rm_names.zig").Ledger.init(epoch) };
    }
    fn fail(self: *Session, err: Error) Error {
        self.state = .failed;
        return err;
    }
    /// A protocol owner may stop after a semantically invalid message. Keep
    /// all receipts/backing intact; this does not stop or quiesce the GPU.
    pub fn stop(self: *Session) void {
        self.state = .failed;
    }
    /// Validate lifetime/time between I/O calls while a dispatch is deferred.
    /// Does not touch a queue or renew any deadline.
    pub fn guard(self: *Session, deadline: u64) Error!void {
        try self.check(deadline);
    }
    fn check(self: *Session, deadline: u64) Error!void {
        if (self.state == .failed) return error.State;
        if (self.port.generation(self.port.context) != self.epoch) return self.fail(error.Stale);
        if (self.port.notification) |notification| {
            if (notification.generation(notification.context) != self.epoch) return self.fail(error.Stale);
        }
        const now = self.port.now_ns(self.port.context);
        if (now == std.math.maxInt(u64) or now < self.last_clock) return self.fail(error.Clock);
        self.last_clock = now;
        if (deadline == std.math.maxInt(u64) or now >= deadline) return self.fail(error.Deadline);
    }
    fn read(self: *Session, deadline: u64, queue: ring.Queue, offset: usize, output: []u8) Error!void {
        try self.check(deadline);
        self.port.read(self.port.context, deadline, queue, offset, output) catch |err| {
            self.last_io_error = err;
            return self.fail(error.Io);
        };
        try self.check(deadline);
    }
    fn publish(self: *Session, deadline: u64, queue: ring.Queue, offset: usize, input: []const u8) Error!void {
        try self.check(deadline);
        self.port.publish(self.port.context, deadline, queue, offset, input) catch |err| {
            self.last_io_error = err;
            return self.fail(error.Io);
        };
        // A failure here is ambiguous: the cursor may already be visible.
        // Keep the failed session and its backing; never retry publication.
        try self.check(deadline);
    }
    fn readWord(self: *Session, deadline: u64, location: ring.Location) Error!u32 {
        var bytes: [4]u8 = undefined;
        try self.read(deadline, location.queue, location.offset, &bytes);
        return std.mem.readInt(u32, &bytes, .little);
    }
    fn publishWord(self: *Session, deadline: u64, location: ring.Location, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.publish(deadline, location.queue, location.offset, &bytes);
    }
    fn signal(self: *Session, deadline: u64, prepare: bool) Error!void {
        try self.check(deadline);
        const notification = self.port.notification orelse return self.fail(error.Notification);
        const callback = if (prepare) notification.prepare else notification.submit;
        callback(notification.context, deadline) catch |err| {
            self.last_io_error = err;
            return self.fail(error.Io);
        };
        try self.check(deadline);
    }

    /// Exactly the two asynchronous early-RM messages, before firmware sees
    /// this queue. The native caller must admit a fresh unsubmitted run and
    /// a CPU-only publication scope. No peer header or doorbell is fabricated.
    pub fn preloadInit(self: *Session, deadline: u64, system: []const u8, registry: []const u8) Error!void {
        if (self.state != .linking or self.link != null or self.link_deadline != null or self.preloaded or
            self.tx_write != 0 or self.tx_sequence != 0 or self.pending != null) return error.State;
        if (system.len == 0 or registry.len == 0 or system.len > message.max_payload_bytes or registry.len > message.max_payload_bytes) return error.Length;
        self.preloaded = true; // A partial publication cannot be repeated.
        errdefer self.state = .failed;
        var own: [ring.header_bytes]u8 = undefined;
        var peer: [ring.header_bytes]u8 = undefined;
        try self.read(deadline, .command, 0, &own);
        const header = try ring.inspect(&own);
        if (header.write != 0 or try self.readWord(deadline, .{ .queue = .command, .offset = header.layout.rx_offset }) != 0) return error.Stale;
        try self.read(deadline, .status, 0, &peer);
        if (!std.mem.allEqual(u8, &peer, 0)) return error.Stale;
        self.preload_layout = header.layout;
        for ([_][]const u8{ system, registry }, [_]u32{ 72, 73 }) |payload, function| {
            // NOSEQ async RPCs carry RPC sequence0; outer queue sequences
            // still advance and must survive the later firmware handshake.
            const encoded = try message.encode(self.profile, self.tx_sequence, .{ .function = function }, payload, self.tx);
            const plan = try ring.transmit(header.layout, self.tx_write, 0, encoded.elements);
            var copied: usize = 0;
            for (plan.spans[0..plan.span_count]) |span| {
                try self.publish(deadline, .command, span.offset, self.tx[copied..][0..span.bytes]);
                copied += span.bytes;
            }
            try self.publishWord(deadline, .{ .queue = .command, .offset = 16 }, plan.next_cursor);
            self.tx_write = plan.next_cursor;
            self.tx_sequence += 1;
        }
    }

    /// One readiness attempt, no spin/retry loop. Firmware may still be
    /// constructing its header; caller reschedules within one absolute limit.
    pub fn connect(self: *Session, deadline: u64) Error!void {
        if (self.state != .linking) return error.State;
        const limit = @min(self.link_deadline orelse deadline, deadline);
        self.link_deadline = limit;
        var own: [ring.header_bytes]u8 = undefined;
        var peer: [ring.header_bytes]u8 = undefined;
        try self.read(limit, .command, 0, &own);
        _ = ring.inspect(&own) catch |err| return self.fail(err);
        try self.read(limit, .status, 0, &peer);
        const link = ring.inspectLink(&own, &peer) catch return error.NotReady;
        const tx_read = try self.readWord(limit, link.command_read);
        const rx_read = try self.readWord(limit, link.status_read);
        // Only this exact session may adopt its two preboot messages. Firmware
        // may already have consumed some/all of them. Unknown old CPU cursors
        // are still rejected, and RX/ACK always starts at zero.
        if (self.preloaded) {
            if (self.tx_sequence != 2 or self.preload_layout == null or
                !std.meta.eql(link.command.layout, self.preload_layout.?) or
                link.command.write != self.tx_write or tx_read > self.tx_write or rx_read != 0) return self.fail(error.Stale);
        } else if (link.command.write != 0 or tx_read != 0 or rx_read != 0) return self.fail(error.Stale);
        self.link = link;
        self.tx_peer_read = tx_read;
        self.rx_peer_write = link.status.write;
        self.state = .active;
    }

    pub fn send(self: *Session, deadline: u64, rpc: message.Rpc, payload: []const u8) Error!void {
        if (self.state != .active) return error.State;
        try self.check(deadline);
        if (self.port.notification == null) return self.fail(error.Notification);
        const link = self.link.?;
        const encoded = try message.encode(self.profile, self.tx_sequence, rpc, payload, self.tx);
        const peer = try self.readWord(deadline, link.command_read);
        const slots = link.command.layout.slots;
        if (peer >= slots or distance(slots, self.tx_peer_read, peer) > distance(slots, self.tx_peer_read, self.tx_write))
            return self.fail(error.PeerProgress);
        self.tx_peer_read = peer;
        const plan = try ring.transmit(link.command.layout, self.tx_write, peer, encoded.elements);
        try self.signal(deadline, true);
        var copied: usize = 0;
        for (plan.spans[0..plan.span_count]) |span| {
            try self.publish(deadline, .command, span.offset, self.tx[copied..][0..span.bytes]);
            copied += span.bytes;
        }
        try self.publishWord(deadline, .{ .queue = .command, .offset = 16 }, plan.next_cursor);
        try self.signal(deadline, false);
        self.tx_write = plan.next_cursor;
        self.tx_sequence +%= 1;
    }

    /// The returned payload remains borrowed until explicit acknowledgement.
    /// Even unknown RPC functions/results are returned without auto-ack/drop.
    pub fn receive(self: *Session, deadline: u64) Error!?Received {
        if (self.state != .active) return error.State;
        if (self.pending != null) return error.Pending;
        if (self.next_ticket == std.math.maxInt(u64)) return self.fail(error.Exhausted);
        const link = self.link.?;
        const peer = try self.readWord(deadline, .{ .queue = .status, .offset = 16 });
        const slots = link.status.layout.slots;
        const free = slots - distance(slots, self.rx_read, self.rx_peer_write) - 1;
        if (peer >= slots or distance(slots, self.rx_peer_write, peer) > free) return self.fail(error.PeerProgress);
        self.rx_peer_write = peer;
        if (peer == self.rx_read) return null;
        const first = try ring.receive(link.status.layout, self.rx_read, peer, 1);
        try self.read(deadline, .status, first.spans[0].offset, self.rx[0..message.header_bytes]);
        const shape = message.inspectPrefix(self.profile, self.rx[0..message.header_bytes]) catch |err| return self.fail(err);
        const plan = ring.receive(link.status.layout, self.rx_read, peer, shape.elements) catch |err| {
            if (err == error.Unavailable) return error.NotReady;
            return self.fail(err);
        };
        var copied: usize = 0;
        for (plan.spans[0..plan.span_count]) |span| {
            try self.read(deadline, .status, span.offset, self.rx[copied..][0..span.bytes]);
            copied += span.bytes;
        }
        const record = message.decode(self.profile, self.rx[0..shape.storage_bytes], self.rx_sequence) catch |err| return self.fail(err);
        const ticket = Ticket{ .epoch = self.epoch, .serial = self.next_ticket, .sequence = self.rx_sequence, .cursor = self.rx_read, .next = plan.next_cursor };
        self.pending = ticket;
        self.next_ticket += 1;
        return .{ .ticket = ticket, .record = record };
    }

    pub fn acknowledge(self: *Session, deadline: u64, ticket: Ticket) Error!void {
        if (self.state != .active) return error.State;
        const expected = self.pending orelse return error.Stale;
        if (!std.meta.eql(expected, ticket)) return error.Stale;
        try self.publishWord(deadline, self.link.?.status_read, ticket.next);
        self.rx_read = ticket.next;
        self.rx_sequence +%= 1;
        self.pending = null;
    }
};

fn distance(slots: u32, before: u32, after: u32) u32 {
    return if (after >= before) after - before else slots - before + after;
}
