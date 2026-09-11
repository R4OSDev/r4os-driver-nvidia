const std = @import("std");
const t = std.testing;
const transport = @import("gsp_transport.zig");
const message = transport.message;
const ring = transport.ring;
const profile = message.Profile{ .chip_id = 0x176 };
const deadline = 1000;
const Event = struct { write: bool, queue: ring.Queue, offset: usize, bytes: usize };
const Model = struct {
    cpu: [2][ring.queue_bytes]u8 = @splat(@splat(0)),
    peer: [2][ring.queue_bytes]u8 = @splat(@splat(0)),
    tx: [message.max_bytes]u8 = undefined,
    rx: [message.max_bytes]u8 = undefined,
    frame: [message.max_bytes]u8 = undefined,
    epoch: u64 = 7,
    now: u64 = 1,
    events: [256]Event = undefined,
    count: usize = 0,
    fault: usize = 0,
    after: bool = false,
    expire: usize = 0,
    change_epoch: usize = 0,
    fn ptr(context: *anyopaque) *Model {
        return @ptrCast(@alignCast(context));
    }
    fn generation(context: *anyopaque) u64 {
        return ptr(context).epoch;
    }
    fn clock(context: *anyopaque) u64 {
        return ptr(context).now;
    }
    fn record(self: *Model, write: bool, queue: ring.Queue, offset: usize, bytes: usize) !void {
        try t.expect(bytes != 0 and bytes <= message.max_bytes and offset <= ring.queue_bytes - bytes);
        self.events[self.count] = .{ .write = write, .queue = queue, .offset = offset, .bytes = bytes };
        self.count += 1;
        if (self.count == self.fault and !self.after) return error.PortFailure;
    }
    fn finish(self: *Model) !void {
        if (self.count == self.expire) self.now = deadline;
        if (self.count == self.change_epoch) self.epoch += 1;
        if (self.count == self.fault and self.after) return error.PortFailure;
    }
    fn read(context: *anyopaque, queue: ring.Queue, offset: usize, output: []u8) !void {
        const self = ptr(context);
        const index = @intFromEnum(queue);
        try self.record(false, queue, offset, output.len);
        @memcpy(self.cpu[index][offset..][0..output.len], self.peer[index][offset..][0..output.len]);
        @memcpy(output, self.cpu[index][offset..][0..output.len]);
        try self.finish();
    }
    fn publish(context: *anyopaque, queue: ring.Queue, offset: usize, input: []const u8) !void {
        const self = ptr(context);
        const index = @intFromEnum(queue);
        try self.record(true, queue, offset, input.len);
        @memcpy(self.cpu[index][offset..][0..input.len], input);
        @memcpy(self.peer[index][offset..][0..input.len], self.cpu[index][offset..][0..input.len]);
        try self.finish();
    }
    fn port(self: *Model) transport.Port {
        return .{ .context = self, .generation = generation, .now_ns = clock, .read = read, .publish = publish };
    }
    fn reset(self: *Model, flags: u32) void {
        self.* = .{};
        for ([_]u32{ 0, 262144, 4096, 63, 0, flags & 1, 32, 4096 }, 0..) |value, index| put(&self.peer[0], index * 4, value);
        for ([_]u32{ 0, 262144, 4096, 63, 0, (flags >> 1) & 1, 64, 4096 }, 0..) |value, index| put(&self.peer[1], index * 4, value);
        self.cpu = self.peer;
    }
    fn start(self: *Model, flags: u32) !transport.Session {
        self.reset(flags);
        var session = try transport.Session.init(self.port(), profile, self.epoch, &self.tx, &self.rx);
        try session.connect(deadline);
        self.count = 0;
        return session;
    }
    fn peerWord(self: *Model, location: ring.Location) u32 {
        return get(&self.peer[@intFromEnum(location.queue)], location.offset);
    }
    fn peerPut(self: *Model, location: ring.Location, value: u32) void {
        put(&self.peer[@intFromEnum(location.queue)], location.offset, value);
    }
    fn reply(self: *Model, session: *transport.Session, payload: []const u8) !void {
        const link = session.link.?;
        const shape = try message.encode(profile, session.rx_sequence, .{ .function = 0xf0000790, .result = 0x87654321 }, payload, &self.frame);
        const plan = try ring.scatter(profile, link.status.layout, get(&self.peer[1], 16), self.peerWord(link.status_read), session.rx_sequence, self.frame[0..shape.storage_bytes], &self.peer[1]);
        put(&self.peer[1], 16, plan.next_cursor);
    }
};
fn put(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn get(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

test "GSP transport orders range publication, explicit acknowledgement and terminal ambiguous failures" {
    const model = try t.allocator.create(Model);
    defer t.allocator.destroy(model);
    for (0..4) |flags| {
        var session = try model.start(@intCast(flags));
        // Device-only neighbour changes must survive CPU command publication.
        model.peer[0][36] = 0xa9;
        try session.send(deadline, .{ .function = 79 }, "command");
        try t.expectEqual(@as(usize, 3), model.count);
        try t.expectEqualDeep(Event{ .write = true, .queue = .command, .offset = 4096, .bytes = 4096 }, model.events[1]);
        try t.expectEqualDeep(Event{ .write = true, .queue = .command, .offset = 16, .bytes = 4 }, model.events[2]);
        try t.expectEqual(@as(u8, 0xa9), model.peer[0][36]);
        try t.expectEqual(@as(u32, 1), session.tx_sequence);
        try model.reply(&session, "opaque event");
        const received = (try session.receive(deadline)).?;
        try t.expectEqualStrings("opaque event", received.record.payload);
        try t.expectEqual(@as(u32, 0xf0000790), received.record.rpc.function);
        try t.expectEqual(@as(u32, 0x87654321), received.record.rpc.result);
        try t.expectEqual(@as(u32, 0), model.peerWord(session.link.?.status_read));
        const calls = model.count;
        try t.expectError(error.Pending, session.receive(deadline));
        var wrong = received.ticket;
        wrong.serial += 1;
        try t.expectError(error.Stale, session.acknowledge(deadline, wrong));
        try t.expectEqual(calls, model.count);
        try session.acknowledge(deadline, received.ticket);
        try t.expectEqualDeep(Event{ .write = true, .queue = session.link.?.status_read.queue, .offset = session.link.?.status_read.offset, .bytes = 4 }, model.events[model.count - 1]);
        try t.expectEqual(@as(u32, 1), session.rx_sequence);
        try t.expectError(error.Stale, session.acknowledge(deadline, received.ticket));
        try t.expect((try session.receive(deadline)) == null);
    }
    // Actual sequential progress reaches the ring end; publication uses two
    // exact payload spans followed by one cursor store, never a full sync.
    var session = try model.start(3);
    for (0..62) |_| {
        try session.send(deadline, .{ .function = 79 }, "x");
        model.peerPut(session.link.?.command_read, session.tx_write);
    }
    model.count = 0;
    const payload = try t.allocator.alloc(u8, message.max_payload_bytes);
    defer t.allocator.free(payload);
    @memset(payload, 0x79);
    try session.send(deadline, .{ .function = 80 }, payload);
    try t.expectEqual(@as(usize, 4), model.count);
    try t.expectEqual(@as(usize, 258048), model.events[1].offset);
    try t.expectEqual(@as(usize, 4096), model.events[1].bytes);
    try t.expectEqual(@as(usize, 15 * 4096), model.events[2].bytes);
    try t.expectEqual(@as(u32, 15), session.tx_write);
    // Four 16-slot replies also cross the RX ring end without early ack.
    for (0..4) |_| {
        try model.reply(&session, payload);
        const received = (try session.receive(deadline)).?;
        try t.expectEqualSlices(u8, payload, received.record.payload);
        try session.acknowledge(deadline, received.ticket);
    }
    try t.expectEqual(@as(u32, 1), session.rx_read);

    session = try model.start(3);
    for (0..62) |_| try session.send(deadline, .{ .function = 1 }, "full");
    const before_full = model.count;
    try t.expectError(error.Unavailable, session.send(deadline, .{ .function = 2 }, "wait"));
    try t.expectEqual(before_full + 1, model.count); // Only refresh the peer cursor.
    try t.expectEqual(@as(u32, 62), session.tx_sequence);
    try t.expectEqual(@as(u32, 62), get(&model.peer[0], 16));
    try t.expectEqual(transport.State.active, session.state);

    // Every command read/data/cursor callback can fail before or after I/O.
    // Ambiguous publication is terminal and cannot duplicate the command.
    for (1..4) |fault| for ([_]bool{ false, true }) |after| {
        session = try model.start(3);
        model.fault = fault;
        model.after = after;
        try t.expectError(error.Io, session.send(deadline, .{ .function = 79 }, "x"));
        try t.expectEqual(transport.State.failed, session.state);
        try t.expectEqual(error.PortFailure, session.last_io_error.?);
        try t.expectEqual(@as(u32, if (fault == 3 and after) 1 else 0), get(&model.peer[0], 16));
        const calls = model.count;
        try t.expectError(error.State, session.send(deadline, .{ .function = 79 }, "x"));
        try t.expectEqual(calls, model.count);
    };
    for ([_]bool{ false, true }) |after| {
        session = try model.start(3);
        try model.reply(&session, "reply");
        const received = (try session.receive(deadline)).?;
        model.fault = model.count + 1;
        model.after = after;
        try t.expectError(error.Io, session.acknowledge(deadline, received.ticket));
        try t.expect(session.pending != null);
        try t.expectEqual(@as(u32, if (after) 1 else 0), model.peerWord(session.link.?.status_read));
        try t.expectError(error.State, session.acknowledge(deadline, received.ticket));
    }
    for (1..4) |fault| for ([_]bool{ false, true }) |after| {
        session = try model.start(3);
        try model.reply(&session, "receive failure");
        model.fault = fault;
        model.after = after;
        try t.expectError(error.Io, session.receive(deadline));
        try t.expectEqual(transport.State.failed, session.state);
        try t.expect(session.pending == null);
        try t.expectEqual(@as(u32, 0), model.peerWord(session.link.?.status_read));
    };
    session = try model.start(3);
    model.expire = 3;
    try t.expectError(error.Deadline, session.send(deadline, .{ .function = 1 }, "x"));
    try t.expectEqual(@as(u32, 1), get(&model.peer[0], 16));
    try t.expectEqual(@as(u32, 0), session.tx_sequence);
    session = try model.start(3);
    model.change_epoch = 3;
    try t.expectError(error.Stale, session.send(deadline, .{ .function = 1 }, "x"));
    session = try model.start(3);
    model.epoch += 1;
    try t.expectError(error.Stale, session.receive(deadline));
    try t.expectEqual(@as(usize, 0), model.count);
    session = try model.start(3);
    model.now = 0;
    try t.expectError(error.Clock, session.receive(deadline));
    session = try model.start(3);
    model.now = std.math.maxInt(u64);
    try t.expectError(error.Clock, session.receive(deadline));
    session = try model.start(3);
    try t.expectError(error.Deadline, session.receive(std.math.maxInt(u64)));
    session = try model.start(3);
    model.peerPut(session.link.?.command_read, 1);
    try t.expectError(error.PeerProgress, session.send(deadline, .{ .function = 1 }, "x"));
    session = try model.start(3);
    put(&model.peer[1], 16, 63);
    try t.expectError(error.PeerProgress, session.receive(deadline));
    model.reset(3);
    put(&model.peer[1], 16, 62);
    session = try transport.Session.init(model.port(), profile, 7, &model.tx, &model.rx);
    try session.connect(deadline);
    put(&model.peer[1], 16, 1); // Peer cannot overrun the unacknowledged full ring.
    try t.expectError(error.PeerProgress, session.receive(deadline));
    session = try model.start(3);
    try model.reply(&session, "bad CRC");
    model.peer[1][4096 + 80] ^= 1;
    try t.expectError(error.Checksum, session.receive(deadline));
    try t.expectEqual(@as(u32, 0), model.peerWord(session.link.?.status_read));
    // Complete prefix, incomplete publication: bounded NotReady, no ack.
    session = try model.start(3);
    try model.reply(&session, payload[0..4097]);
    put(&model.peer[1], 16, 1);
    try t.expectError(error.NotReady, session.receive(deadline));
    try t.expectEqual(transport.State.active, session.state);
    put(&model.peer[1], 16, 2);
    const completed = (try session.receive(deadline)).?;
    try session.acknowledge(deadline, completed.ticket);
    // u32 protocol sequences wrap; receipt tickets never do.
    session = try model.start(3);
    session.tx_sequence = std.math.maxInt(u32);
    session.rx_sequence = std.math.maxInt(u32);
    try session.send(deadline, .{ .function = 1 }, "x");
    try model.reply(&session, "wrap");
    const wrapped = (try session.receive(deadline)).?;
    try session.acknowledge(deadline, wrapped.ticket);
    try t.expectEqual(@as(u32, 0), session.tx_sequence);
    try t.expectEqual(@as(u32, 0), session.rx_sequence);
    session.next_ticket = std.math.maxInt(u64);
    try t.expectError(error.Exhausted, session.receive(deadline));
    // Firmware header readiness does not spin or mutate either queue.
    model.reset(3);
    @memset(&model.peer[1], 0);
    session = try transport.Session.init(model.port(), profile, 7, &model.tx, &model.rx);
    try t.expectError(error.NotReady, session.connect(deadline));
    try t.expectEqual(@as(usize, 2), model.count);
    model.now = deadline;
    try t.expectError(error.Deadline, session.connect(deadline + 1000));
    try t.expectError(error.Profile, transport.Session.init(model.port(), .{ .chip_id = 0x176, .confidential_compute = true }, 7, &model.tx, &model.rx));
    try t.expectError(error.Profile, transport.Session.init(model.port(), .{ .chip_id = 0x177 }, 7, &model.tx, &model.rx));
    try t.expectError(error.Overlap, transport.Session.init(model.port(), profile, 7, &model.tx, &model.tx));
    try t.expectError(error.Stale, transport.Session.init(model.port(), profile, 0, &model.tx, &model.rx));
}
