//! Receive one real branch notification, then let the topology owner decide
//! its acknowledgement. HPD invalidates work before it can affect a new root.
const std = @import("std");
const wire = @import("gsp_mst_wire.zig");
const aux = @import("gsp_aux_wire.zig");
pub const Stage = enum { ready, read, clear, received, respond, complete, empty, cancelled };
pub const Work = struct {
    root: u32,
    generation: u64,
    deadline: u64,
    stage: Stage = .ready,
    assembly: ?wire.Assembly = null,
    packet: [48]u8 = @splat(0),
    count: usize = 0,
    cursor: usize = 0,
    pending: ?aux.Request = null,
    last_receipt: u64 = 0,
    received_receipt: u64 = 0,
    response_receipt: u64 = 0,
    not_before: u64 = 0,
    retries: u8 = 0,
    down_pending: bool = false,
    failure: ?anyerror = null,

    pub fn init(root: u32, generation: u64, deadline: u64) !Work {
        if (root == 0 or root & (root - 1) != 0 or generation == 0 or deadline == 0) return error.Descriptor;
        return .{ .root = root, .generation = generation, .deadline = deadline };
    }
    pub fn invalidate(self: *Work) void {
        self.stage = .cancelled;
    }
    fn guard(self: *const Work, generation: u64, now: u64) !void {
        if (self.failure != null or generation != self.generation or self.stage == .cancelled) return error.Stale;
        if (now >= self.deadline) return error.Deadline;
    }
    pub fn prepare(self: *Work, generation: u64, now: u64) !?aux.Request {
        try self.guard(generation, now);
        if (self.pending != null) return error.Pending;
        if (now < self.not_before or self.stage == .received or self.stage == .complete or self.stage == .empty) return null;
        var operation: aux.Mst = undefined;
        switch (self.stage) {
            .ready => operation = .{ .irq = .{} },
            .read => operation = .{ .mailbox = .{ .box = .up_request, .offset = @intCast(self.cursor), .count = @intCast(if (self.cursor == 0) 16 else @min(self.count - self.cursor, 16)) } },
            .clear => operation = .{ .irq = .{ .ack = 0x20 } },
            .respond => {
                const count = @min(self.count - self.cursor, 16);
                var data: [16]u8 = @splat(0);
                @memcpy(data[0..count], self.packet[self.cursor..][0..count]);
                operation = .{ .mailbox = .{ .box = .up_reply, .offset = @intCast(self.cursor), .count = @intCast(count), .data = data } };
            },
            else => unreachable,
        }
        const query: aux.Request = .{ .display_id = self.root, .operation = .{ .mst = operation } };
        self.pending = query;
        return query;
    }
    fn retry(self: *Work, now: u64, delay_ms: u32) !void {
        if (delay_ms == 0 or delay_ms > 500 or self.retries == 7) return error.RetryExhausted;
        self.retries += 1;
        self.not_before = now +| @as(u64, delay_ms) * std.time.ns_per_ms;
    }
    pub fn consume(self: *Work, generation: u64, reply: aux.Reply, serial: u64, now: u64) !void {
        const query = self.pending orelse return error.Pending;
        if (serial == 0 or serial <= self.last_receipt) return error.Stale;
        self.pending = null;
        self.last_receipt = serial;
        if (self.stage == .cancelled or generation != self.generation) {
            self.stage = .cancelled;
            return;
        }
        errdefer |err| self.failure = err;
        try self.guard(generation, now);
        if (reply.status == 3 or reply.status == 0x66) return self.retry(now, reply.retry_ms);
        if (reply.status != 0) return error.RmRejected;
        if (reply.kind == .defer_reply) return self.retry(now, 1);
        if (reply.kind != .ack or reply.count != aux.length(query.operation)) return error.Aux;
        self.retries = 0;
        self.not_before = 0;
        switch (self.stage) {
            .ready => {
                self.down_pending = self.down_pending or reply.data[0] & 0x10 != 0;
                if (reply.data[0] & 0x20 != 0) {
                    self.stage = .read;
                    self.cursor = 0;
                    self.count = 0;
                } else if (self.assembly != null) {
                    self.not_before = now +| std.time.ns_per_ms;
                } else self.stage = .empty;
            },
            .read => {
                @memcpy(self.packet[self.cursor..][0..reply.count], reply.data[0..reply.count]);
                self.cursor += reply.count;
                if (self.count == 0) {
                    const header = try wire.decodeHeader(self.packet[0..self.cursor]);
                    self.count = header.size() + header.payload_bytes;
                    if (self.assembly == null) {
                        if (!header.start or header.remaining != 0) return error.Stale;
                        self.assembly = .{ .route = header.route, .sequence = header.sequence, .path = header.path, .broadcast = header.broadcast };
                    }
                }
                if (self.cursor >= self.count) {
                    try self.assembly.?.consume(try wire.decode(self.packet[0..self.count]));
                    self.stage = .clear;
                }
            },
            .clear => {
                if (self.assembly.?.complete) {
                    _ = try wire.notification(try self.assembly.?.body());
                    self.received_receipt = serial;
                    self.stage = .received;
                } else self.stage = .ready;
            },
            .respond => {
                self.cursor += reply.count;
                if (self.cursor == self.count) {
                    self.response_receipt = serial;
                    self.stage = .complete;
                }
            },
            else => return error.State,
        }
    }
    pub fn notification(self: *const Work, generation: u64) !wire.Notification {
        if (self.failure != null or self.generation != generation or self.stage != .received or self.received_receipt == 0) return error.Stale;
        return wire.notification(try self.assembly.?.body());
    }
    /// The registry must match GUID, RAD and port before accepting. An
    /// unmatched old branch gets a NAK and never changes current connectors.
    pub fn respond(self: *Work, generation: u64, now: u64, accepted: bool) !void {
        try self.guard(generation, now);
        _ = try self.notification(generation);
        if (self.pending != null) return error.Pending;
        const incoming = &self.assembly.?;
        const request = (try incoming.body())[0];
        // NVIDIA GenericUpReplyMessage::set: one reply-type bit and seven
        // request-ID bits. Do not transplant a downstream NAK body here.
        const body = [_]u8{request | @as(u8, if (accepted) 0 else 0x80)};
        var sender: wire.Sender = .{ .route = incoming.route, .sequence = incoming.sequence, .path = incoming.path, .broadcast = incoming.broadcast };
        self.count = (try sender.next(&body, &self.packet)).?;
        self.cursor = 0;
        self.stage = .respond;
    }
};
