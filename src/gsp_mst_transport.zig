//! One bounded downstream sideband exchange over the physical root AUX.
//! The resident RM owner submits prepare() through its normal live channel,
//! drains every receipt and supplies the unchanged topology generation.
const std = @import("std");
const wire = @import("gsp_mst_wire.zig");
const aux = @import("gsp_aux_wire.zig");
pub const Stage = enum { send, ready, read, clear, complete, cancelled };
pub const Work = struct {
    root: u32,
    generation: u64,
    deadline: u64,
    request: wire.Request,
    sender: wire.Sender,
    assembly: wire.Assembly,
    stage: Stage = .send,
    body: [24]u8 = @splat(0),
    body_count: usize = 0,
    packet: [wire.packet_bytes]u8 = @splat(0),
    packet_count: usize = 0,
    cursor: usize = 0,
    pending: ?aux.Request = null,
    last_receipt: u64 = 0,
    completion_receipt: u64 = 0,
    not_before: u64 = 0,
    retries: u8 = 0,
    up_pending: bool = false,
    failure: ?anyerror = null,

    pub fn init(root: u32, generation: u64, deadline: u64, route: wire.Route, sequence: u1, request: wire.Request) !Work {
        if (root == 0 or root & (root - 1) != 0 or generation == 0 or deadline == 0 or !route.valid()) return error.Descriptor;
        var value: Work = .{ .root = root, .generation = generation, .deadline = deadline, .request = request, .sender = .{ .route = route, .sequence = sequence, .path = request.path(), .broadcast = request == .clear }, .assembly = .{ .route = if (request == .clear) .{} else route, .sequence = sequence, .path = request.path(), .broadcast = request == .clear } };
        value.body_count = try request.encode(&value.body);
        value.packet_count = (try value.sender.next(value.body[0..value.body_count], &value.packet)).?;
        return value;
    }
    pub fn active(self: *const Work) bool {
        return self.failure == null and self.stage != .complete and self.stage != .cancelled;
    }
    pub fn invalidate(self: *Work) void {
        self.stage = .cancelled;
    }
    fn guard(self: *const Work, generation: u64, now: u64) !void {
        if (self.failure != null or generation != self.generation or self.stage == .cancelled) return error.Stale;
        if (now >= self.deadline) return error.Deadline;
    }
    /// Repeated calls while a request is pending cannot resubmit its effects.
    pub fn prepare(self: *Work, generation: u64, now: u64) !?aux.Request {
        try self.guard(generation, now);
        if (self.pending != null) return error.Pending;
        if (self.stage == .complete or now < self.not_before) return null;
        var query: aux.Request = .{ .display_id = self.root, .operation = undefined };
        switch (self.stage) {
            .send => {
                const count = @min(self.packet_count - self.cursor, 16);
                var data: [16]u8 = @splat(0);
                @memcpy(data[0..count], self.packet[self.cursor..][0..count]);
                query.operation = .{ .mst = .{ .mailbox = .{ .box = .down_request, .offset = @intCast(self.cursor), .count = @intCast(count), .data = data } } };
            },
            .ready => query.operation = .{ .mst = .{ .irq = .{} } },
            .read => query.operation = .{ .mst = .{ .mailbox = .{ .box = .down_reply, .offset = @intCast(self.cursor), .count = @intCast(if (self.cursor == 0) 16 else @min(self.packet_count - self.cursor, 16)) } } },
            .clear => query.operation = .{ .mst = .{ .irq = .{ .ack = 0x10 } } },
            .complete, .cancelled => unreachable,
        }
        self.pending = query;
        return query;
    }
    fn retry(self: *Work, now: u64, delay_ms: u32) !void {
        if (delay_ms == 0 or delay_ms > 500 or self.retries == 7) return error.RetryExhausted;
        self.retries += 1;
        self.not_before = now +| @as(u64, delay_ms) * std.time.ns_per_ms;
    }
    pub fn consume(self: *Work, generation: u64, observed: aux.Reply, serial: u64, now: u64) !void {
        const query = self.pending orelse return error.Pending;
        if (serial == 0 or serial <= self.last_receipt) return error.Stale;
        self.pending = null;
        self.last_receipt = serial;
        // The RM owner has drained this receipt even after invalidation. No
        // ACK, allocation or publication may escape into the new generation.
        if (self.stage == .cancelled or generation != self.generation) {
            self.stage = .cancelled;
            return;
        }
        errdefer |err| self.failure = err;
        try self.guard(generation, now);
        if (observed.status == 3 or observed.status == 0x66) return self.retry(now, observed.retry_ms);
        if (observed.status != 0) return error.RmRejected;
        if (observed.kind == .defer_reply) return self.retry(now, 1);
        if (observed.kind != .ack or observed.count != aux.length(query.operation)) return error.Aux;
        self.retries = 0;
        self.not_before = 0;
        switch (self.stage) {
            .send => {
                self.cursor += observed.count;
                if (self.cursor == self.packet_count) {
                    self.cursor = 0;
                    if (try self.sender.next(self.body[0..self.body_count], &self.packet)) |count| self.packet_count = count else {
                        self.stage = .ready;
                        self.packet_count = 0;
                    }
                }
            },
            .ready => {
                self.up_pending = self.up_pending or observed.data[0] & 0x20 != 0;
                if (observed.data[0] & 0x10 == 0) {
                    self.not_before = now +| std.time.ns_per_ms;
                } else {
                    self.stage = .read;
                    self.cursor = 0;
                    self.packet_count = 0;
                }
            },
            .read => {
                @memcpy(self.packet[self.cursor..][0..observed.count], observed.data[0..observed.count]);
                self.cursor += observed.count;
                if (self.packet_count == 0) {
                    const header = try wire.decodeHeader(self.packet[0..self.cursor]);
                    self.packet_count = header.size() + header.payload_bytes;
                }
                if (self.cursor >= self.packet_count) {
                    const frame = try wire.decode(self.packet[0..self.packet_count]);
                    try self.assembly.consume(frame);
                    self.stage = .clear;
                }
            },
            .clear => {
                if (self.assembly.complete) {
                    _ = try wire.reply(self.request, try self.assembly.body());
                    self.completion_receipt = serial;
                    self.stage = .complete;
                } else {
                    self.stage = .ready;
                    self.cursor = 0;
                    self.packet_count = 0;
                }
            },
            .complete, .cancelled => return error.State,
        }
    }
    pub fn result(self: *const Work, generation: u64) !wire.Reply {
        if (self.failure != null or generation != self.generation or self.stage != .complete or
            self.pending != null or self.completion_receipt == 0) return error.Stale;
        return wire.reply(self.request, try self.assembly.body());
    }
};
