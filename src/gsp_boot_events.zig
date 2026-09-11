//! Pinned GA106 boot notifications over one retained GSP transport session.
//! Decode only CPU snapshots. Payload admission is not permission to execute
//! a sequencer, access registers, release DMA, or declare native graphics ready.
// Layouts and boot event selection from NVIDIA 570.144 g_rpc-structures.h,
// rpc_global_enums.h, ctrl2080nvd.h and kernel_gsp.c. NVIDIA portions: MIT.
// Original R4OS ownership, admission and deadline policy: Apache-2.0.
// Copyright (c) 2008-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2004-2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
const transport = @import("gsp_transport.zig");
const message = transport.message;
pub const Error = transport.Error || error{ UnknownEvent, Payload, Guest, FirmwareResult, Handler };
pub const Kind = enum(u32) {
    init_done = 0x1001,
    cpu_sequencer = 0x1002,
    os_error = 0x1006,
    libos_print = 0x100c,
    lockdown = 0x101c,
    nocat = 0x1020,
};
pub const Sequencer = struct {
    capacity_words: u32,
    saved: [8]u32,
    // Exactly cmdIndex words, in little-endian byte form. The execution owner
    // must admit ALL opcodes, operands and hardware effects before execution.
    commands: []const u8,
};
pub const OsError = struct { xid: u32, runlist: u32, channel: u32, text: []const u8, previous_xid: u32 };
pub const Nocat = struct {
    flags: u32,
    timestamp: u64,
    record_type: u8,
    bugcheck: u32,
    source: []const u8,
    subsystem: u32,
    error_code: u64,
    engine: []const u8,
    tdr_reason: u32,
    diagnostic: []const u8,
};
pub const Event = union(Kind) {
    init_done: void,
    cpu_sequencer: Sequencer,
    os_error: OsError,
    libos_print: struct { engine: u32, bytes: []const u8 },
    lockdown: bool,
    nocat: Nocat,
};
fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
fn text(bytes: []const u8) []const u8 {
    // Fixed vendor character arrays need not contain a terminator. They never
    // become format strings; the receiving log owner must escape raw controls.
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
}

/// Complete outer framing/checksum/queue sequence must already be accepted by
/// gsp_message.decode. Non-init RPC result/private/sequence fields remain raw
/// diagnostics: the original boot event handlers do not define them as an ACK.
pub fn decode(record: message.Record) Error!Event {
    if (record.rpc.cpu_rm_gfid != 0) return error.Guest;
    const kind = std.enums.fromInt(Kind, record.rpc.function) orelse return error.UnknownEvent;
    const bytes = record.payload;
    if (bytes.len > message.max_payload_bytes) return error.Payload;
    switch (kind) {
        .init_done => {
            // The original rpc_init_done_v17_00 has one unused u32. Neither
            // its value nor C padding is a version/firmware-identity field.
            if (bytes.len != 4) return error.Payload;
            if (record.rpc.result != 0) return error.FirmwareResult;
            return .init_done;
        },
        .lockdown => {
            if (bytes.len != 1 or bytes[0] > 1) return error.Payload;
            return .{ .lockdown = bytes[0] == 1 };
        },
        .libos_print => {
            if (bytes.len < 8 or word(bytes, 4) != bytes.len - 8) return error.Payload;
            return .{ .libos_print = .{ .engine = word(bytes, 0), .bytes = bytes[8..] } };
        },
        .os_error => {
            if (bytes.len != 272) return error.Payload;
            return .{ .os_error = .{ .xid = word(bytes, 0), .runlist = word(bytes, 4), .channel = word(bytes, 8), .text = text(bytes[12..268]), .previous_xid = word(bytes, 268) } };
        },
        .nocat => {
            // data is an inline NV2080CtrlNocatJournalInsertRecord, not the
            // four-byte placeholder's size and not a pointer to guest memory.
            if (bytes.len != 1208 or word(bytes, 176) > 1024) return error.Payload;
            return .{ .nocat = .{
                .flags = word(bytes, 0),
                .timestamp = std.mem.readInt(u64, bytes[8..16], .little),
                .record_type = bytes[16],
                .bugcheck = word(bytes, 20),
                .source = text(bytes[24..89]),
                .subsystem = word(bytes, 92),
                .error_code = std.mem.readInt(u64, bytes[96..104], .little),
                .engine = text(bytes[104..169]),
                .tdr_reason = word(bytes, 172),
                .diagnostic = bytes[180..][0..word(bytes, 176)],
            } };
        },
        .cpu_sequencer => {
            if (bytes.len < 40 or (bytes.len - 40) % 4 != 0) return error.Payload;
            const capacity = word(bytes, 0);
            const used = word(bytes, 4);
            const present = (bytes.len - 40) / 4;
            // The allocation capacity and transmitted extent are separate.
            // Admit compact or full buffers, but never read missing used words
            // or follow a capacity outside one bounded transport record.
            if (capacity == 0 or capacity > (message.max_payload_bytes - 40) / 4 or
                used >= capacity or used > present or present > capacity) return error.Payload;
            var saved: [8]u32 = undefined;
            for (&saved, 0..) |*value, i| value.* = word(bytes, 8 + i * 4);
            return .{ .cpu_sequencer = .{ .capacity_words = capacity, .saved = saved, .commands = bytes[40..][0 .. @as(usize, used) * 4] } };
        },
    }
}

pub const State = enum { waiting, dispatching, init_done, handed_off, failed };
pub const Dispatch = struct { ticket: transport.Ticket, rpc: message.Rpc, event: Event };
pub const Failure = struct { reason: Error, rpc: ?message.Rpc, ticket: ?transport.Ticket };
/// Sole post-boot queue owner. The RM object allocator can drive this session
/// and handle notifications (updating lockdown) before the next owner claims
/// it. Do not copy this token or drive its session after claimed becomes true.
/// Neither the handoff nor a claim creates RM objects or frees device backing.
pub const Handoff = struct { session: *transport.Session, in_lockdown: bool, claimed: bool = false };
pub const Boot = struct {
    session: *transport.Session,
    deadline: u64,
    state: State = .waiting,
    pending: ?Dispatch = null,
    last_rpc: ?message.Rpc = null,
    failure: ?Failure = null,
    in_lockdown: bool = false,
    handled_events: u64 = 0,

    /// Bind once before the first connect. The caller retains the session,
    /// port and scratch at stable addresses and never drives them separately.
    /// The one absolute deadline includes linking, dispatch and delayed work.
    pub fn init(session: *transport.Session, deadline: u64) Error!Boot {
        if (session.state != .linking or session.pending != null) return error.State;
        try session.guard(deadline);
        return .{ .session = session, .deadline = deadline };
    }
    fn fail(self: *Boot, reason: Error) Error {
        // An idle/link/framing failure has no admitted current RPC. Never
        // attribute it to the previous successfully acknowledged message.
        self.failure = .{ .reason = reason, .rpc = if (self.session.pending != null) self.last_rpc else null, .ticket = self.session.pending };
        self.state = .failed;
        self.session.stop();
        return reason;
    }
    fn guard(self: *Boot) Error!void {
        if (self.state == .failed or self.state == .init_done or self.state == .handed_off) return error.State;
        self.session.guard(self.deadline) catch |err| return self.fail(err);
    }

    /// Transfer the sole queue owner after INIT_DONE was handled and ACKed.
    /// The new owner inherits lockdown and must retain all device backing.
    /// This grants no RM handles, hardware readiness or quiescence proof.
    pub fn handoff(self: *Boot, deadline: u64) Error!Handoff {
        if (self.state != .init_done or self.pending != null or
            self.session.state != .active or self.session.pending != null) return error.State;
        self.session.guard(deadline) catch |err| return self.fail(err);
        self.state = .handed_off;
        return .{ .session = self.session, .in_lockdown = self.in_lockdown };
    }

    /// At most one record per call, no busy loop or implicit event handling.
    /// A returned payload remains borrowed until complete/reject. Rescheduling
    /// never extends the deadline, including while an event handler is pending.
    pub fn poll(self: *Boot) Error!?Dispatch {
        try self.guard();
        if (self.pending != null) return error.Pending;
        if (self.session.state == .linking) {
            self.session.connect(self.deadline) catch |err| {
                if (err == error.NotReady) return null;
                return self.fail(err);
            };
        }
        const received = self.session.receive(self.deadline) catch |err| {
            if (err == error.NotReady) return null;
            return self.fail(err);
        } orelse return null;
        self.last_rpc = received.record.rpc;
        const event = decode(received.record) catch |err| return self.fail(err);
        // Engaging blocks register access as soon as the notice is admitted.
        // Disengaging only clears this conservative flag after a successful
        // ACK; an ambiguous ACK must never reopen the register path.
        if (event == .lockdown and event.lockdown) self.in_lockdown = true;
        const dispatch = Dispatch{ .ticket = received.ticket, .rpc = received.record.rpc, .event = event };
        self.pending = dispatch;
        self.state = .dispatching;
        return dispatch;
    }

    /// Called only after the hardware/logging owner actually handled the event.
    /// In particular, parsing a sequencer does not satisfy this contract. A
    /// failed/ambiguous ACK is terminal: never execute that handler again.
    pub fn complete(self: *Boot, ticket: transport.Ticket) Error!void {
        const dispatch = try self.borrow(ticket);
        if (self.handled_events == std.math.maxInt(u64)) return self.fail(error.Exhausted);
        self.session.acknowledge(self.deadline, ticket) catch |err| return self.fail(err);
        switch (dispatch.event) {
            .init_done => self.state = .init_done,
            .lockdown => |engaging| self.in_lockdown = engaging,
            else => {},
        }
        self.handled_events += 1;
        self.pending = null;
        if (self.state != .init_done) self.state = .waiting;
    }

    /// Unsupported effects or a failed handler preserve the unacknowledged
    /// receipt and exact RPC fields. Neither failure nor INIT_DONE proves that
    /// the device is quiescent; DMA storage belongs to the execution owner.
    pub fn reject(self: *Boot, ticket: transport.Ticket) Error!void {
        _ = try self.borrow(ticket);
        return self.fail(error.Handler);
    }

    /// Revalidate an outstanding dispatch before each deferred hardware step.
    /// No queue access, new receipt, acknowledgement or deadline extension.
    pub fn borrow(self: *Boot, ticket: transport.Ticket) Error!Dispatch {
        try self.guard();
        const dispatch = self.pending orelse return error.Stale;
        if (!std.meta.eql(dispatch.ticket, ticket)) return error.Stale;
        return dispatch;
    }
};
