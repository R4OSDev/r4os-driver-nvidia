//! Drain old downstream fragments before a new sideband conversation.
//! No payload becomes a topology observation. The old request deadline and
//! the new capture deadline bound a late reply; the root keeps its SQN.
const std = @import("std");
const wire = @import("gsp_mst_wire.zig");
const aux = @import("gsp_aux_wire.zig");
pub const Work = struct {
    root: u32,
    generation: u64,
    deadline: u64,
    prior_deadline: u64 = 0,
    stage: enum { ready, read, clear, complete, cancelled } = .ready,
    packet: [48]u8 = @splat(0),
    count: usize = 0,
    cursor: usize = 0,
    fragments: u8 = 0,
    continuing: bool = false,
    up_pending: bool = false,
    pending: ?aux.Request = null,
    last_receipt: u64 = 0,
    not_before: u64 = 0,
    retries: u8 = 0,
    pub fn prepare(self: *Work, generation: u64, now: u64) !?aux.Request {
        if (generation != self.generation or self.stage == .cancelled) return error.Stale;
        if (now >= self.deadline) return error.Deadline;
        if (self.pending != null) return error.Pending;
        if (self.stage == .complete or now < self.not_before) return null;
        const operation: aux.Mst = switch (self.stage) {
            .ready => .{ .irq = .{} },
            .read => .{ .mailbox = .{ .box = .down_reply, .offset = @intCast(self.cursor), .count = @intCast(if (self.cursor == 0) 16 else @min(self.count - self.cursor, 16)) } },
            .clear => .{ .irq = .{ .ack = 0x10 } },
            else => unreachable,
        };
        self.pending = .{ .display_id = self.root, .operation = .{ .mst = operation } };
        return self.pending;
    }
    pub fn consume(self: *Work, generation: u64, reply: aux.Reply, serial: u64, now: u64) !void {
        const query = self.pending orelse return error.Pending;
        if (serial <= self.last_receipt) return error.Stale;
        self.pending = null;
        self.last_receipt = serial;
        if (generation != self.generation or self.stage == .cancelled) { self.stage = .cancelled; return; }
        if (now >= self.deadline) return error.Deadline;
        if (reply.status == 3 or reply.status == 0x66 or (reply.status == 0 and reply.kind == .defer_reply)) {
            const delay = if (reply.status == 0) 1 else reply.retry_ms;
            if (delay == 0 or delay > 500 or self.retries == 7) return error.RetryExhausted;
            self.retries += 1;
            self.not_before = now +| @as(u64, delay) * std.time.ns_per_ms;
            return;
        }
        if (reply.status != 0 or reply.kind != .ack or reply.count != aux.length(query.operation)) return error.Aux;
        self.not_before = 0;
        self.retries = 0;
        switch (self.stage) {
            .ready => {
                self.up_pending = self.up_pending or reply.data[0] & 0x20 != 0;
                if (reply.data[0] & 0x10 != 0) {
                    if (self.fragments == 64) return error.RetryExhausted;
                    self.count = 0;
                    self.cursor = 0;
                    self.stage = .read;
                } else if (self.continuing or now < self.prior_deadline) {
                    self.not_before = now +| std.time.ns_per_ms;
                } else self.stage = .complete;
            },
            .read => {
                @memcpy(self.packet[self.cursor..][0..reply.count], reply.data[0..reply.count]);
                self.cursor += reply.count;
                if (self.count == 0) {
                    const header = try wire.decodeHeader(self.packet[0..self.cursor]);
                    self.count = header.size() + header.payload_bytes;
                }
                if (self.cursor >= self.count) {
                    const frame = try wire.decode(self.packet[0..self.count]);
                    if (frame.header.remaining != 0) return error.Payload;
                    self.continuing = !frame.header.end;
                    self.stage = .clear;
                }
            },
            .clear => {
                self.fragments += 1;
                if (!self.continuing) self.prior_deadline = 0;
                self.stage = .ready;
            },
            else => return error.State,
        }
    }
};
