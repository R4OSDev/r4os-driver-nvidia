const std = @import("std");
const t = std.testing;
const transport = @import("gsp_transport.zig");
const boot_events = @import("gsp_boot_events.zig");
const display_rpc = @import("gsp_display_rpc.zig");
const objects = @import("gsp_objects.zig");
const sequencer = @import("gsp_sequencer.zig");
const runtime_events = @import("gsp_runtime_events.zig");
const event_objects = @import("gsp_event_objects.zig");
const rm_graph = @import("gsp_rm_graph.zig");
const rm_names = @import("gsp_rm_names.zig");
const receiver = @import("gsp_receiver.zig");
const topology = @import("gsp_topology.zig");
const message = transport.message;
const ring = transport.ring;
const profile = message.Profile{ .chip_id = 0x176 };
const deadline = 1000;
const Event = struct { write: bool, queue: ring.Queue, offset: usize, bytes: usize };
const SignalPhase = enum { none, prepare, submit };
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
    signal_epoch: ?u64 = null,
    prepares: usize = 0,
    notifications: usize = 0,
    notify_pending: bool = false,
    signal_fault: SignalPhase = .none,
    signal_after: bool = false,
    signal_expire: SignalPhase = .none,
    signal_stale: SignalPhase = .none,
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
    fn read(context: *anyopaque, limit: u64, queue: ring.Queue, offset: usize, output: []u8) !void {
        const self = ptr(context);
        try t.expect(self.now < limit and limit != std.math.maxInt(u64));
        const index = @intFromEnum(queue);
        try self.record(false, queue, offset, output.len);
        @memcpy(self.cpu[index][offset..][0..output.len], self.peer[index][offset..][0..output.len]);
        @memcpy(output, self.cpu[index][offset..][0..output.len]);
        try self.finish();
    }
    fn publish(context: *anyopaque, limit: u64, queue: ring.Queue, offset: usize, input: []const u8) !void {
        const self = ptr(context);
        try t.expect(self.now < limit and limit != std.math.maxInt(u64));
        const index = @intFromEnum(queue);
        try self.record(true, queue, offset, input.len);
        @memcpy(self.cpu[index][offset..][0..input.len], input);
        @memcpy(self.peer[index][offset..][0..input.len], self.cpu[index][offset..][0..input.len]);
        try self.finish();
    }
    fn port(self: *Model) transport.Port {
        return .{ .context = self, .generation = generation, .now_ns = clock, .read = read, .publish = publish, .notification = .{ .context = self, .generation = signalGeneration, .prepare = prepareSignal, .submit = submitSignal } };
    }
    fn signalGeneration(p: *anyopaque) u64 {
        const self = ptr(p);
        return self.signal_epoch orelse self.epoch;
    }
    fn signal(self: *Model, phase: SignalPhase, limit: u64) !void {
        try t.expect(self.now < limit);
        if (self.signal_fault == phase and !self.signal_after) return error.NotifyFailure;
        if (phase == .prepare) {
            try t.expect(!self.notify_pending);
            self.prepares += 1;
            self.notify_pending = true;
        } else {
            try t.expect(self.notify_pending);
            try t.expectEqualDeep(Event{ .write = true, .queue = .command, .offset = 16, .bytes = 4 }, self.events[self.count - 1]);
            self.notifications += 1;
            self.notify_pending = false;
        }
        if (self.signal_expire == phase) self.now = limit;
        if (self.signal_stale == phase) self.signal_epoch = self.epoch + 1;
        if (self.signal_fault == phase and self.signal_after) return error.NotifyFailure;
    }
    fn prepareSignal(p: *anyopaque, limit: u64) anyerror!void {
        return ptr(p).signal(.prepare, limit);
    }
    fn submitSignal(p: *anyopaque, limit: u64) anyerror!void {
        return ptr(p).signal(.submit, limit);
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
        return self.replyRpc(session, .{ .function = 0xf0000790, .result = 0x87654321 }, payload);
    }
    fn replyRpc(self: *Model, session: *transport.Session, rpc: message.Rpc, payload: []const u8) !void {
        const link = session.link.?;
        const shape = try message.encode(profile, session.rx_sequence, rpc, payload, &self.frame);
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

fn startBoot(model: *Model, session: *transport.Session) !boot_events.Boot {
    return startBootAt(model, session, deadline);
}
fn startBootAt(model: *Model, session: *transport.Session, end: u64) !boot_events.Boot {
    model.reset(3);
    session.* = try transport.Session.init(model.port(), profile, model.epoch, &model.tx, &model.rx);
    var boot = try boot_events.Boot.init(session, end);
    try t.expect((try boot.poll()) == null);
    model.count = 0;
    return boot;
}

const SequencerDevice = struct {
    queue: *Model,
    registers: [4]u32 = @splat(0),
    admissions: usize = 0,
    calls: usize = 0,
    writes: usize = 0,
    starts: usize = 0,
    completions: usize = 0,
    denied: ?sequencer.Opcode = null,
    fault: usize = 0,
    after: bool = false,
    late: usize = 0,
    epoch_change: usize = 0,
    fn ptr(context: *anyopaque) *SequencerDevice {
        return @ptrCast(@alignCast(context));
    }
    fn generation(context: *anyopaque) u64 {
        return ptr(context).queue.epoch;
    }
    fn now(context: *anyopaque) u64 {
        return ptr(context).queue.now;
    }
    fn admit(context: *anyopaque, command: sequencer.Command) error{ Denied, Unsupported }!void {
        const self = ptr(context);
        self.admissions += 1;
        if (self.denied == std.meta.activeTag(command)) return error.Denied;
    }
    fn begin(self: *SequencerDevice) !void {
        self.calls += 1;
        if (self.calls == self.fault and !self.after) return error.RegisterBus;
    }
    fn finish(self: *SequencerDevice) !void {
        if (self.calls == self.late) self.queue.now = 100000;
        if (self.calls == self.epoch_change) self.queue.epoch += 1;
        if (self.calls == self.fault and self.after) return error.RegisterBus;
    }
    fn read(context: *anyopaque, address: u32) !u32 {
        const self = ptr(context);
        try self.begin();
        const value = self.registers[address / 4];
        try self.finish();
        return value;
    }
    fn write(context: *anyopaque, address: u32, value: u32) !void {
        const self = ptr(context);
        try self.begin();
        self.writes += 1;
        self.registers[address / 4] = value;
        try self.finish();
    }
    fn core(context: *anyopaque, opcode: sequencer.Opcode, state: *sequencer.CoreState, end: u64, saved: *const [8]u32) !bool {
        const self = ptr(context);
        try t.expect(@intFromEnum(opcode) >= 5 and @intFromEnum(opcode) <= 8);
        try t.expect(end <= 100000 and end > self.queue.now);
        _ = saved;
        try self.begin();
        if (state.phase == 0) {
            self.starts += 1;
            state.phase = 1;
            try self.finish();
            return false;
        }
        try t.expectEqual(@as(u32, 1), state.phase);
        self.completions += 1;
        state.phase = 2;
        try self.finish();
        return true;
    }
    fn port(self: *SequencerDevice) sequencer.Port {
        return .{ .context = self, .generation = generation, .now_ns = now, .admit = admit, .read32 = read, .write32 = write, .core_step = core };
    }
};
fn sequencerPayload(output: []u8, words: []const u32) []const u8 {
    const bytes = output[0 .. 40 + words.len * 4];
    @memset(bytes, 0);
    put(bytes, 0, @intCast(words.len + 1));
    put(bytes, 4, @intCast(words.len));
    for (0..8) |i| put(bytes, 8 + i * 4, @intCast(0xa0 + i));
    for (words, 0..) |value, i| put(bytes, 40 + i * 4, value);
    return bytes;
}

test "GSP sequencer admits the entire stream and finishes bounded effects before acknowledging its dispatch" {
    const model = try t.allocator.create(Model);
    defer t.allocator.destroy(model);
    const limits = sequencer.Limits{ .register_bytes = 16, .default_timeout_ns = 20000, .poll_interval_ns = 1000 };
    var session: transport.Session = undefined;
    var boot = try startBootAt(model, &session, 100000);
    var device = SequencerDevice{ .queue = model };
    var payload: [256]u8 = undefined;
    const program = [_]u32{
        0, 0, 0xa500, // write
        1, 0, 0xff, 0x10003, // modify; value includes bits outside mask
        4, 0, 7, // save
        2, 4, 0xff, 0x79, 5, 0x600d, // poll, five MICROseconds
        3, 2, // delay, two microseconds
        5, 6, 7, 8, // four distinct architecture operations
    };
    try model.replyRpc(&session, .{ .function = 0x1002 }, sequencerPayload(&payload, &program));
    _ = (try boot.poll()).?;
    var execution = try sequencer.DispatchExecution.init(&boot, device.port(), limits);
    try t.expectEqual(@as(usize, 9), device.admissions);
    try t.expectEqual(@as(usize, 0), device.calls);
    try t.expect((try execution.step()) == .advanced);
    try t.expectEqual(@as(u32, 0xa500), device.registers[0]);
    try t.expect((try execution.step()) == .advanced);
    try t.expectEqual(@as(u32, 0x1a503), device.registers[0]);
    try t.expect((try execution.step()) == .advanced);
    try t.expectEqual(@as(u32, 0x1a503), execution.runner.saved[7]);
    try t.expectEqual(@as(u64, 1001), (try execution.step()).wait_until);
    try t.expectEqual(@as(u64, 5001), execution.runner.phase_deadline.?);
    model.now = 4000;
    try t.expectEqual(@as(u64, 5000), (try execution.step()).wait_until);
    device.registers[1] = 0x79;
    model.now = 4001;
    try t.expect((try execution.step()) == .advanced);
    try t.expectEqual(@as(u64, 6001), (try execution.step()).wait_until);
    const before_delay = device.calls;
    model.now = 6000;
    try t.expectEqual(@as(u64, 6001), (try execution.step()).wait_until);
    try t.expectEqual(before_delay, device.calls);
    model.now = 6001;
    try t.expect((try execution.step()) == .advanced);
    for (0..4) |i| {
        try t.expect((try execution.step()) == .wait_until);
        try t.expectEqual(@as(u32, 0), model.peerWord(session.link.?.status_read));
        model.now += 1000;
        const result = try execution.step();
        try t.expect(if (i == 3) result == .complete else result == .advanced);
    }
    try t.expectEqual(@as(usize, 4), device.starts);
    try t.expectEqual(@as(usize, 4), device.completions);
    try t.expect(execution.acknowledged);
    try t.expectEqual(@as(u32, 1), model.peerWord(session.link.?.status_read));
    try t.expectEqual(boot_events.State.waiting, boot.state); // Still needs INIT_DONE.
    const completed_calls = device.calls;
    const completed_queue_calls = model.count;
    try t.expect((try execution.step()) == .complete);
    try t.expectEqual(completed_calls, device.calls);
    try t.expectEqual(completed_queue_calls, model.count);

    const Invalid = struct { words: []const u32, expected: sequencer.Error, deny: ?sequencer.Opcode = null, core: bool = true };
    for ([_]Invalid{
        .{ .words = &.{ 0, 0, 0x79, 99 }, .expected = error.Opcode },
        .{ .words = &.{ 0, 0, 0x79, 0 }, .expected = error.Payload },
        .{ .words = &.{ 0, 0, 0x79, 0, 16, 1 }, .expected = error.Register },
        .{ .words = &.{ 0, 0, 0x79, 0, 2, 1 }, .expected = error.Register },
        .{ .words = &.{ 0, 0, 0x79, 4, 4, 8 }, .expected = error.Slot },
        .{ .words = &.{ 0, 0, 0x79, 2, 4, 1, 2, 3, 4 }, .expected = error.Payload },
        .{ .words = &.{ 0, 0, 0x79, 8 }, .expected = error.Unsupported, .core = false },
        .{ .words = &.{ 0, 0, 0x79, 6 }, .expected = error.Denied, .deny = .core_start },
        .{ .words = &.{ 0, 0, 0x79, 3, 0xffffffff }, .expected = error.Deadline },
        .{ .words = &.{ 0, 0, 0x79, 3, 50, 3, 50 }, .expected = error.Deadline },
    }) |case| {
        boot = try startBootAt(model, &session, 100000);
        device = .{ .queue = model, .denied = case.deny };
        try model.replyRpc(&session, .{ .function = 0x1002 }, sequencerPayload(&payload, case.words));
        _ = (try boot.poll()).?;
        var port = device.port();
        if (!case.core) port.core_step = null;
        try t.expectError(case.expected, sequencer.DispatchExecution.init(&boot, port, limits));
        try t.expectEqual(@as(usize, 0), device.calls);
        try t.expectEqual(@as(u32, 0), model.peerWord(session.link.?.status_read));
        try t.expectEqual(boot_events.State.failed, boot.state);
        try t.expect(session.pending != null);
    }
    // A poll's first local deadline cannot slide on subsequent worker calls.
    // Prior writes remain accounted for; a timeout cannot trigger a replay.
    boot = try startBootAt(model, &session, 100000);
    device = .{ .queue = model };
    try model.replyRpc(&session, .{ .function = 0x1002 }, sequencerPayload(&payload, &.{ 0, 0, 0x79, 2, 4, 0xff, 0x79, 3, 0xbeef }));
    _ = (try boot.poll()).?;
    execution = try sequencer.DispatchExecution.init(&boot, device.port(), limits);
    _ = try execution.step();
    _ = try execution.step();
    model.now = 3000;
    _ = try execution.step();
    model.now = 3001;
    try t.expectError(error.Timeout, execution.step());
    try t.expectEqual(@as(u32, 0xbeef), execution.runner.failure.?.vendor_error);
    try t.expectEqual(@as(usize, 3), execution.runner.failure.?.word_index);
    try t.expectEqual(@as(u32, 0), execution.runner.failure.?.last_value.?);
    var calls = device.calls;
    try t.expectError(error.State, execution.step());
    try t.expectEqual(calls, device.calls);
    try t.expectEqual(@as(u32, 0x79), device.registers[0]);
    try t.expectEqual(@as(u32, 0), model.peerWord(session.link.?.status_read));

    // Hardware callback failure before/after an effect, global deadline and
    // stale epoch all stop execution while the event remains unacknowledged.
    for (0..4) |fault| {
        boot = try startBootAt(model, &session, 100000);
        device = .{ .queue = model };
        try model.replyRpc(&session, .{ .function = 0x1002 }, sequencerPayload(&payload, &.{ 0, 0, 0x79, 0, 4, 0xaa }));
        _ = (try boot.poll()).?;
        execution = try sequencer.DispatchExecution.init(&boot, device.port(), limits);
        const expected: sequencer.DispatchError = switch (fault) {
            0, 1 => blk: {
                device.fault = 1;
                device.after = fault == 1;
                break :blk error.Io;
            },
            2 => blk: {
                device.late = 1;
                break :blk error.Deadline;
            },
            else => blk: {
                device.epoch_change = 1;
                break :blk error.Stale;
            },
        };
        try t.expectError(expected, execution.step());
        try t.expectEqual(@as(u32, if (fault == 0) 0 else 0x79), device.registers[0]);
        try t.expectEqual(@as(u32, 0), device.registers[1]);
        try t.expectEqual(@as(u32, 0), model.peerWord(session.link.?.status_read));
        calls = device.calls;
        try t.expectError(error.State, execution.step());
        try t.expectEqual(calls, device.calls);
    }
    // A partially started architecture operation is not restarted after an
    // ambiguous callback, and an expired deferred event prevents any new I/O.
    boot = try startBootAt(model, &session, 100000);
    device = .{ .queue = model, .fault = 1, .after = true };
    try model.replyRpc(&session, .{ .function = 0x1002 }, sequencerPayload(&payload, &.{8}));
    _ = (try boot.poll()).?;
    execution = try sequencer.DispatchExecution.init(&boot, device.port(), limits);
    try t.expectError(error.Io, execution.step());
    try t.expectEqual(@as(u32, 1), execution.runner.core.phase);
    try t.expectEqual(@as(usize, 1), device.starts);
    try t.expectEqual(error.RegisterBus, execution.runner.failure.?.callback_error.?);

    boot = try startBootAt(model, &session, 100000);
    device = .{ .queue = model };
    try model.replyRpc(&session, .{ .function = 0x1002 }, sequencerPayload(&payload, &.{ 0, 0, 0x79 }));
    _ = (try boot.poll()).?;
    execution = try sequencer.DispatchExecution.init(&boot, device.port(), limits);
    model.now = 100000;
    try t.expectError(error.Deadline, execution.step());
    try t.expectEqual(@as(usize, 0), device.calls);

    // ACK can fail after all real port effects finished. Keep that completion
    // and never repeat the write merely to get a second queue acknowledgement.
    boot = try startBootAt(model, &session, 100000);
    device = .{ .queue = model };
    try model.replyRpc(&session, .{ .function = 0x1002 }, sequencerPayload(&payload, &.{ 0, 0, 0x79 }));
    _ = (try boot.poll()).?;
    execution = try sequencer.DispatchExecution.init(&boot, device.port(), limits);
    model.fault = model.count + 1;
    model.after = true;
    try t.expectError(error.Io, execution.step());
    try t.expectEqual(sequencer.State.complete, execution.runner.state);
    try t.expect(!execution.acknowledged and execution.failed);
    try t.expectEqual(@as(u32, 1), model.peerWord(session.link.?.status_read));
    try t.expect(boot.pending != null and session.pending != null);
    try t.expectError(error.State, execution.step());
    try t.expectEqual(@as(usize, 1), device.writes);
    try checkRuntimeSequencer(model, limits);
}

fn checkRuntimeSequencer(model: *Model, limits: sequencer.Limits) !void {
    const exchange = @import("gsp_exchange.zig");
    // The same handler works while idle, before a request is sent, and while
    // waiting for its response. Completing the notification preserves that
    // request and does not publish a second one or grant a fresh deadline.
    for (0..5) |scenario| {
        var session: transport.Session = undefined;
        var boot = try startBootAt(model, &session, 1000);
        try model.replyRpc(&session, .{ .function = 0x1001, .result = 0 }, &.{ 0, 0, 0, 0 });
        try boot.complete((try boot.poll()).?.ticket);
        var token = try boot.handoff(1000);
        var owner = try exchange.Exchange.init(&token, 100000);
        model.now = 2000; // Boot has expired; this notification has its own budget.
        if (scenario != 0) {
            try owner.begin(79, "runtime request", 100000);
            if (scenario >= 2) try t.expect((try owner.poll(100000)) == null);
        }
        var payload: [64]u8 = undefined;
        const words: []const u32 = if (scenario == 3) &.{ 0, 0, 0x79, 3, 2 } else &.{ 0, 0, 0x79 };
        try model.replyRpc(&session, .{ .function = 0x1002, .result = 0 }, sequencerPayload(&payload, words));
        const dispatch = (try owner.poll(100000)).?;
        var device = SequencerDevice{ .queue = model };
        var execution = try sequencer.DispatchExecution.initRuntime(&owner, device.port(), limits);
        const phase = owner.phase;
        const sends = model.notifications;
        const cursor = model.peerWord(session.link.?.status_read);
        if (scenario == 3) {
            try t.expect((try execution.step()) == .advanced);
            try t.expectEqual(@as(u64, 4000), (try execution.step()).wait_until);
            try t.expectError(error.Pending, owner.poll(3000)); // Tightens, cannot consume another event.
            try t.expectEqual(@as(u64, 3000), (try execution.step()).wait_until);
            try t.expectEqual(@as(u64, 4000), execution.runner.delay_until.?); // Mandatory delay stays whole.
            model.now = 3000;
            try t.expectError(error.Deadline, execution.step());
            try t.expect(owner.phase == .failed and session.pending != null);
            try t.expectEqual(cursor, model.peerWord(session.link.?.status_read));
        } else if (scenario == 4) {
            model.fault = model.count + 1;
            model.after = true;
            try t.expectError(error.Io, execution.step());
            try t.expect(execution.runner.state == .complete and !execution.acknowledged);
            try t.expectEqual(dispatch.ticket.next, model.peerWord(session.link.?.status_read));
            try t.expect(owner.phase == .failed and owner.pending != null);
        } else {
            try t.expect((try execution.step()) == .complete);
            try t.expect(execution.acknowledged and owner.pending == null and session.pending == null);
            try t.expectEqual(phase, owner.phase);
            if (scenario == 0) try t.expect(owner.deadline == null) else try t.expectEqual(@as(u64, 100000), owner.deadline.?);
        }
        try t.expectEqual(@as(usize, 1), device.writes);
        try t.expectEqual(sends, model.notifications);
        const queue_calls = model.count;
        if (execution.failed) try t.expectError(error.State, execution.step()) else try t.expect((try execution.step()) == .complete);
        try t.expectEqual(@as(usize, 1), device.writes);
        try t.expectEqual(queue_calls, model.count);
    }
}
fn badBootEvent(model: *Model, rpc: message.Rpc, payload: []const u8, expected: boot_events.Error) !void {
    var session: transport.Session = undefined;
    var boot = try startBoot(model, &session);
    try model.replyRpc(&session, rpc, payload);
    try t.expectError(expected, boot.poll());
    try t.expectEqual(boot_events.State.failed, boot.state);
    try t.expectEqual(transport.State.failed, session.state);
    try t.expectEqual(expected, boot.failure.?.reason);
    try t.expectEqualDeep(rpc, boot.failure.?.rpc.?);
    try t.expectEqualDeep(session.pending.?, boot.failure.?.ticket.?);
    try t.expectEqual(@as(u32, 0), model.peerWord(session.link.?.status_read));
    const calls = model.count;
    try t.expectError(error.State, boot.poll());
    try t.expectError(error.State, session.send(deadline, .{ .function = 1 }, "retry"));
    try t.expectEqual(calls, model.count);
}

test "GSP boot events require explicit handling, valid original payloads and an unextended deadline" {
    const model = try t.allocator.create(Model);
    defer t.allocator.destroy(model);
    var session: transport.Session = undefined;
    var boot = try startBoot(model, &session);
    try model.replyRpc(&session, .{ .function = 0x101c }, &.{1});
    var event = (try boot.poll()).?;
    try t.expect(event.event == .lockdown and event.event.lockdown);
    try t.expect(boot.in_lockdown); // Restrict registers BEFORE handling/ACK.
    try t.expectEqual(boot_events.State.dispatching, boot.state);
    var before = model.count;
    try t.expectError(error.Pending, boot.poll());
    var wrong = event.ticket;
    wrong.serial += 1;
    try t.expectError(error.Stale, boot.complete(wrong));
    try t.expectError(error.Stale, boot.reject(wrong));
    try t.expectEqual(before, model.count);
    try boot.complete(event.ticket);
    try t.expectEqual(@as(u32, 1), model.peerWord(session.link.?.status_read));
    try t.expectError(error.Stale, boot.complete(event.ticket));
    try model.replyRpc(&session, .{ .function = 0x101c }, &.{0});
    event = (try boot.poll()).?;
    try t.expect(boot.in_lockdown); // Release only after unambiguous ACK.
    try boot.complete(event.ticket);
    try t.expect(!boot.in_lockdown);
    try model.replyRpc(&session, .{ .function = 0x1001, .result = 0, .result_private = 0x76543210 }, &.{ 0xff, 0xab, 0xcd, 0xef });
    event = (try boot.poll()).?;
    try t.expect(event.event == .init_done);
    try t.expectEqual(boot_events.State.dispatching, boot.state);
    try boot.complete(event.ticket);
    try t.expectEqual(boot_events.State.init_done, boot.state);
    try t.expectEqual(@as(u64, 3), boot.handled_events);
    before = model.count;
    try t.expectError(error.State, boot.poll());
    try t.expectEqual(before, model.count);

    for ([_]u32{ 79, 0x1000, 0x1021, 0xffffffff }) |function|
        try badBootEvent(model, .{ .function = function }, "unknown", error.UnknownEvent);
    try badBootEvent(model, .{ .function = 0x1001, .result = 0, .cpu_rm_gfid = 1 }, &.{ 0, 0, 0, 0 }, error.Guest);
    for ([_]u32{ message.pending, 0x65, 0x12345678 }) |result|
        try badBootEvent(model, .{ .function = 0x1001, .result = result, .result_private = 0x1122 }, &.{ 0, 0, 0, 0 }, error.FirmwareResult);
    var bytes: [1212]u8 = @splat(0);
    const Invalid = struct { function: u32, length: usize };
    for ([_]Invalid{
        .{ .function = 0x1001, .length = 3 },    .{ .function = 0x1001, .length = 5 },
        .{ .function = 0x101c, .length = 0 },    .{ .function = 0x101c, .length = 2 },
        .{ .function = 0x1006, .length = 271 },  .{ .function = 0x1006, .length = 273 },
        .{ .function = 0x1020, .length = 1207 }, .{ .function = 0x1020, .length = 1209 },
        .{ .function = 0x100c, .length = 7 },    .{ .function = 0x1002, .length = 39 },
    }) |case| try badBootEvent(model, .{ .function = case.function, .result = 0 }, bytes[0..case.length], error.Payload);
    try badBootEvent(model, .{ .function = 0x101c }, &.{2}, error.Payload);
    put(&bytes, 176, 1025);
    try badBootEvent(model, .{ .function = 0x1020 }, bytes[0..1208], error.Payload);
    put(&bytes, 176, 0);
    put(&bytes, 4, 0xffffffff);
    try badBootEvent(model, .{ .function = 0x100c }, bytes[0..9], error.Payload);

    // Capacity cannot authorize missing commands or wrap a byte count. These
    // are transport-valid frames whose semantic payload must not reach MMIO.
    for ([_][3]u32{ .{ 0, 0, 40 }, .{ 1, 1, 44 }, .{ 3, 2, 44 }, .{ 1, 0, 48 }, .{ 0xffffffff, 0, 40 }, .{ 2, 1, 45 } }) |case| {
        put(&bytes, 0, case[0]);
        put(&bytes, 4, case[1]);
        try badBootEvent(model, .{ .function = 0x1002 }, bytes[0..case[2]], error.Payload);
    }
    boot = try startBoot(model, &session);
    put(&bytes, 0, 2);
    put(&bytes, 4, 1);
    put(&bytes, 40, 0xfeed);
    try model.replyRpc(&session, .{ .function = 0x1002 }, bytes[0..44]);
    event = (try boot.poll()).?;
    try t.expect(event.event == .cpu_sequencer);
    try t.expectEqual(@as(usize, 4), event.event.cpu_sequencer.commands.len);
    before = model.count;
    // There is no real executor in this fixture; parsing must not ACK it.
    try t.expectError(error.Handler, boot.reject(event.ticket));
    try t.expectEqual(before, model.count);
    try t.expect(boot.pending != null and session.pending != null);

    // Largest binary log traverses the actual framing/ring transport. Embedded
    // NUL/control bytes stay a bounded byte span for the logging owner.
    const large = try t.allocator.alloc(u8, message.max_payload_bytes);
    defer t.allocator.free(large);
    @memset(large, 0x1b);
    put(large, 0, 0x9999);
    put(large, 4, @intCast(large.len - 8));
    large[8] = 0;
    boot = try startBoot(model, &session);
    try model.replyRpc(&session, .{ .function = 0x100c }, large);
    event = (try boot.poll()).?;
    try t.expectEqualSlices(u8, large[8..], event.event.libos_print.bytes);
    try boot.complete(event.ticket);
    try t.expectEqual(@as(u32, 16), session.rx_read);
    model.now = deadline;
    try t.expectError(error.Deadline, boot.poll());
    try t.expect(boot.failure.?.rpc == null and boot.failure.?.ticket == null);

    // Delayed handler, lifetime change and ambiguous acknowledgements cannot
    // report INIT_DONE or cause handler replay, even if the cursor was written.
    for (0..4) |fault| {
        boot = try startBoot(model, &session);
        try model.replyRpc(&session, .{ .function = 0x1001, .result = 0 }, &.{ 0, 0, 0, 0 });
        event = (try boot.poll()).?;
        before = model.count;
        const expected: boot_events.Error = switch (fault) {
            0 => blk: {
                model.now = deadline;
                break :blk error.Deadline;
            },
            1 => blk: {
                model.epoch += 1;
                break :blk error.Stale;
            },
            2 => blk: {
                model.fault = before + 1;
                model.after = true;
                break :blk error.Io;
            },
            else => blk: {
                model.expire = before + 1;
                break :blk error.Deadline;
            },
        };
        try t.expectError(expected, boot.complete(event.ticket));
        try t.expectEqual(boot_events.State.failed, boot.state);
        try t.expectEqual(@as(u64, 0), boot.handled_events);
        try t.expect(boot.pending != null and session.pending != null);
        try t.expectEqual(@as(u32, if (fault >= 2) 1 else 0), model.peerWord(session.link.?.status_read));
        before = model.count;
        try t.expectError(error.State, boot.complete(event.ticket));
        try t.expectEqual(before, model.count);
    }
    boot = try startBoot(model, &session);
    try model.replyRpc(&session, .{ .function = 0x101c }, &.{1});
    _ = (try boot.poll()).?;
    model.now = deadline;
    try t.expectError(error.Deadline, boot.poll()); // Pending doesn't hide TTL.
    try t.expect(boot.in_lockdown);
    try t.expectEqual(@as(u32, 0), model.peerWord(session.link.?.status_read));

    // Readiness attempts keep the same absolute boot deadline.
    model.reset(3);
    session = try transport.Session.init(model.port(), profile, model.epoch, &model.tx, &model.rx);
    boot = try boot_events.Boot.init(&session, deadline);
    @memset(&model.peer[1], 0);
    try t.expect((try boot.poll()) == null);
    model.now = deadline - 1;
    try t.expect((try boot.poll()) == null);
    model.now = deadline;
    before = model.count;
    try t.expectError(error.Deadline, boot.poll());
    try t.expectEqual(before, model.count);
}

const display_object = display_rpc.Object{ .epoch = 7, .client = 0xc100, .display = 0xd073 };
fn startDisplay(model: *Model, session: *transport.Session) !display_rpc.Channel {
    var boot = try startBoot(model, session);
    try t.expectError(error.State, boot.handoff(deadline));
    try model.replyRpc(session, .{ .function = 0x1001, .result = 0 }, &.{ 0, 0, 0, 0 });
    const event = (try boot.poll()).?;
    try t.expectError(error.State, boot.handoff(deadline));
    try boot.complete(event.ticket);
    var runtime = try boot.handoff(deadline);
    var wrong = display_object;
    wrong.epoch += 1;
    try t.expectError(error.Handle, display_rpc.Channel.init(&runtime, wrong, deadline));
    try t.expect(!runtime.claimed);
    const channel = try display_rpc.Channel.init(&runtime, display_object, deadline);
    try t.expectEqual(boot_events.State.handed_off, boot.state);
    try t.expect(runtime.claimed);
    try t.expectError(error.State, display_rpc.Channel.init(&runtime, display_object, deadline));
    try t.expectError(error.State, boot.handoff(deadline));
    try t.expectError(error.State, boot.poll());
    model.count = 0;
    return channel;
}
fn displayReply(model: *Model, channel: *display_rpc.Channel, status: u32, value: u32) !void {
    var bytes: [display_rpc.max_request_bytes]u8 = undefined;
    const encoded = try display_rpc.encode(channel.object, channel.request.?, &bytes);
    put(&bytes, 12, status);
    switch (channel.request.?) {
        .supported => {
            put(&bytes, 28, value);
            put(&bytes, 32, value);
        },
        .connected => put(&bytes, 32, value),
        .edid => {
            put(&bytes, 32, value);
            if (value <= 2048) for (bytes[40..][0..value], 0..) |*byte, i| {
                byte.* = @truncate(i);
            };
        },
        .heads, .active, .connectors, .resource, .buses, .ports, .ddc, .aux => unreachable, // Dedicated bounded topology/DDC fixtures below.
    }
    // The RPC sequence and private result deliberately do not echo the request.
    try model.replyRpc(channel.exchange.session, .{ .function = 76, .result = 0, .result_private = 0x19283746, .sequence = 0xdeadbeef }, encoded);
}
fn readyDisplay(model: *Model, session: *transport.Session) !display_rpc.Channel {
    var channel = try startDisplay(model, session);
    try channel.begin(.supported, deadline);
    try t.expect((try channel.poll(deadline)) == null);
    try displayReply(model, &channel, 0, 0x80000005);
    try channel.complete((try channel.poll(deadline)).?.ticket);
    try channel.begin(.{ .connected = 0x80000005 }, deadline);
    try t.expect((try channel.poll(deadline)) == null);
    try displayReply(model, &channel, 0, 0x80000001);
    try channel.complete((try channel.poll(deadline)).?.ticket);
    return channel;
}
fn checkDisplayRpc(model: *Model) !void {
    // Original-header byte offsets, sizes and command IDs are independent
    // of the encoder, and travel through the real framing/queue model below.
    var payload: [2089]u8 = undefined;
    const queries = [_]display_rpc.Query{ .supported, .{ .connected = 0x80000005 }, .{ .edid = 0x80000000 }, .{ .connectors = 0x80000000 }, .{ .resource = 0x80000000 }, .{ .buses = 0x80000000 }, .heads, .{ .active = 31 } };
    const sizes = [_]usize{ 36, 40, 2088, 96, 80, 40, 36, 40 };
    const commands = [_]u32{ 0x730107, 0x730108, 0x730245, 0x730250, 0x73028b, 0x730211, 0x730102, 0x73010c };
    for (queries, sizes, commands) |query, size, command| {
        @memset(&payload, 0xa5);
        const bytes = try display_rpc.encode(display_object, query, &payload);
        try t.expectEqual(size, bytes.len);
        try t.expectEqual(@as(u8, 0xa5), payload[size]);
        for ([_]u32{ 0xc100, 0xd073, command, 0, @intCast(size - 24), 0, 0 }, 0..) |value, i|
            try t.expectEqual(value, get(bytes, i * 4));
        if (query == .connected) try t.expectEqual(@as(u32, 0x80000005), get(bytes, 32));
        if (query == .heads) try t.expect(get(bytes, 28) == 0 and get(bytes, 32) == 0);
        if (query == .active) try t.expect(get(bytes, 28) == 31 and get(bytes, 32) == 0 and get(bytes, 36) == 0);
        if (query == .edid) {
            try t.expectEqual(@as(u32, 0x80000000), get(bytes, 28));
            try t.expectEqual(@as(u32, 0), get(bytes, 32));
            try t.expectEqual(@as(u32, 2), get(bytes, 36));
            for (bytes[40..]) |byte| try t.expectEqual(@as(u8, 0), byte);
        }
        if (query == .connectors or query == .resource or query == .buses) {
            try t.expectEqual(@as(u32, 0x80000000), get(bytes, 28));
            for (bytes[32..]) |byte| try t.expectEqual(@as(u8, 0), byte);
        }
        try t.expectError(error.Bounds, display_rpc.encode(display_object, query, payload[0 .. size - 1]));
        _ = try display_rpc.encode(display_object, query, &payload);
        const shape = try message.encode(profile, 0, .{ .function = 76, .result = 0 }, bytes, &model.frame);
        try t.expectEqual(@as(u32, 1), shape.elements);
        var record = try message.decode(profile, model.frame[0..shape.storage_bytes], 0);
        for (0..size) |length| {
            record.payload = bytes[0..length];
            try t.expectError(error.Payload, display_rpc.decode(display_object, query, record));
        }
        record.payload = &payload;
        try t.expectError(error.Payload, display_rpc.decode(display_object, query, record));
        for ([_]usize{ 0, 4, 8, 16, 20, 24 }) |offset| {
            _ = try display_rpc.encode(display_object, query, &payload);
            put(&payload, offset, get(&payload, offset) ^ 1);
            record.payload = payload[0..size];
            const err = if (offset == 16 or offset == 20) error.Payload else error.Unexpected;
            try t.expectError(err, display_rpc.decode(display_object, query, record));
        }
    }
    for ([_]u32{ 0, 3, 0xffffffff }) |id|
        try t.expectError(error.Query, display_rpc.encode(display_object, .{ .edid = id }, &payload));

    var session: transport.Session = undefined;
    var channel = try startDisplay(model, &session);
    try t.expectError(error.Query, channel.begin(.{ .connected = 1 }, deadline));
    try t.expectError(error.Query, channel.begin(.{ .edid = 1 }, deadline));
    try t.expectEqual(@as(usize, 0), model.count);
    try channel.begin(.supported, deadline);
    try t.expectError(error.State, channel.begin(.supported, deadline + 1));
    try t.expectError(error.State, channel.handoff(deadline));
    try t.expect((try channel.poll(deadline)) == null);
    const sent = try message.decode(profile, model.peer[0][4096..8192], 0);
    try t.expectEqual(@as(u32, 76), sent.rpc.function);
    try t.expectEqual(@as(usize, 36), sent.payload.len);
    // A print message cannot be mistaken for a response, including when its
    // raw RPC result is PENDING; the actual log handler still owns its ACK.
    try model.replyRpc(&session, .{ .function = 0x100c }, &.{ 0, 0, 0, 0, 1, 0, 0, 0, 'x' });
    var event = (try channel.poll(deadline)).?;
    try t.expect(event.value == .notification);
    try t.expectEqual(@as(u64, 1), channel.exchange.revision);
    const before = model.count;
    try t.expectError(error.Pending, channel.poll(deadline + 100));
    var wrong = event.ticket;
    wrong.serial += 1;
    try t.expectError(error.Stale, channel.complete(wrong));
    try t.expectEqual(before, model.count);
    try channel.complete(event.ticket);
    try t.expectEqual(display_rpc.Phase.waiting, channel.exchange.phase);
    try displayReply(model, &channel, 0, 0x80000005);
    event = (try channel.poll(deadline)).?;
    try t.expect(channel.supported == null);
    try channel.complete(event.ticket);
    try t.expectEqual(@as(u32, 0x80000005), channel.supported.?.displays);
    try t.expectError(error.Query, channel.begin(.{ .connected = 2 }, deadline));
    try channel.begin(.{ .connected = 0x80000005 }, deadline);
    try t.expect((try channel.poll(deadline)) == null);
    try displayReply(model, &channel, 0, 0x80000001);
    try channel.complete((try channel.poll(deadline)).?.ticket);
    try t.expectError(error.Query, channel.begin(.{ .edid = 4 }, deadline));
    try channel.begin(.{ .edid = 0x80000000 }, deadline);
    try t.expect((try channel.poll(deadline)) == null);
    try displayReply(model, &channel, 0, 2048);
    event = (try channel.poll(deadline)).?;
    try t.expectEqual(@as(usize, 2048), event.value.reply.edid.len);
    try t.expectEqual(@as(u8, 255), event.value.reply.edid[2047]);
    try channel.invalidate(); // Deferred consumers must re-borrow before use.
    try t.expect((try channel.borrow(event.ticket)).value.reply == .obsolete);
    try channel.complete(event.ticket);
    try t.expectEqual(@as(u32, 0), channel.connected);

    channel = try readyDisplay(model, &session);
    try channel.begin(.{ .edid = 1 }, deadline);
    const sent_before = session.tx_sequence;
    try model.replyRpc(&session, .{ .function = 0x1003 }, "hotplug requires handler");
    event = (try channel.poll(deadline)).?;
    try channel.complete(event.ticket);
    try t.expectError(error.Obsolete, channel.poll(deadline));
    try t.expectEqual(sent_before, session.tx_sequence); // Never sent after invalidation.
    try channel.begin(.{ .connected = 1 }, deadline);
    try t.expect((try channel.poll(deadline)) == null);
    try model.replyRpc(&session, .{ .function = 0x1003 }, "second hotplug");
    try channel.complete((try channel.poll(deadline)).?.ticket);
    try displayReply(model, &channel, 0, 1);
    event = (try channel.poll(deadline)).?;
    try t.expect(event.value.reply == .obsolete);
    try channel.complete(event.ticket);
    try t.expectEqual(@as(u32, 0), channel.connected);

    channel = try readyDisplay(model, &session);
    try channel.begin(.{ .connected = 1 }, deadline);
    try t.expect((try channel.poll(deadline)) == null);
    try displayReply(model, &channel, 66, 0xffffffff);
    event = (try channel.poll(deadline)).?;
    try t.expectEqual(@as(u32, 66), event.value.reply.control_error);
    try channel.complete(event.ticket);
    try t.expectError(error.Query, channel.begin(.{ .edid = 1 }, deadline));
    try channel.begin(.supported, deadline);
    try t.expect((try channel.poll(deadline)) == null);
    try model.replyRpc(&session, .{ .function = 76, .result = 0x55 }, "");
    event = (try channel.poll(deadline)).?;
    try t.expectEqual(@as(u32, 0x55), event.value.reply.rpc_error);
    try channel.complete(event.ticket);
    try t.expectEqual(display_rpc.Phase.idle, channel.exchange.phase);
    // The runtime can perform other RPCs between owners (e.g. object alloc/
    // free). Here only the wire transaction is a fixture, not an RM allocation.
    var runtime = try channel.handoff(deadline);
    try t.expectError(error.State, channel.handoff(deadline));
    try t.expectError(error.State, channel.poll(deadline));
    const previous_sequence = session.tx_sequence;
    try runtime.session.send(deadline, .{ .function = 103, .sequence = previous_sequence }, "allocator fixture");
    try model.replyRpc(&session, .{ .function = 103, .result = 0 }, "allocator result");
    try runtime.session.acknowledge(deadline, (try runtime.session.receive(deadline)).?.ticket);
    runtime.in_lockdown = true; // The preceding owner handled a lockdown notice.
    channel = try display_rpc.Channel.init(&runtime, display_object, deadline);
    try t.expect(channel.exchange.in_lockdown);
    try channel.begin(.supported, deadline);
    try model.replyRpc(&session, .{ .function = 0x101c }, &.{0});
    try channel.complete((try channel.poll(deadline)).?.ticket);
    const cursor = session.tx_write;
    try t.expect((try channel.poll(deadline)) == null);
    const carried = try message.decode(profile, model.peer[0][4096 + @as(usize, cursor) * 4096 ..][0..4096], previous_sequence + 1);
    try t.expectEqual(previous_sequence + 1, carried.rpc.sequence);

    channel = try readyDisplay(model, &session);
    try channel.begin(.{ .edid = 1 }, deadline);
    try t.expect((try channel.poll(deadline)) == null);
    try displayReply(model, &channel, 0, 2049);
    try t.expectError(error.Payload, channel.poll(deadline));
    try t.expect(session.pending != null);

    for ([_]bool{ false, true }) |after| {
        channel = try startDisplay(model, &session);
        try channel.begin(.supported, deadline);
        try t.expect((try channel.poll(deadline)) == null);
        try displayReply(model, &channel, 0, 1);
        event = (try channel.poll(deadline)).?;
        model.fault = model.count + 1;
        model.after = after;
        try t.expectError(error.Io, channel.complete(event.ticket));
        try t.expectEqual(display_rpc.Phase.failed, channel.exchange.phase);
        try t.expect(channel.supported == null and session.pending != null and channel.pending != null);
        const count = model.count;
        try t.expectError(error.State, channel.complete(event.ticket));
        try t.expectEqual(count, model.count);
    }
    channel = try startDisplay(model, &session);
    try channel.begin(.supported, deadline);
    // A full command queue is legitimate backpressure, with no deadline reset.
    session.tx_write = 62;
    put(&model.peer[0], 16, 62);
    try t.expect((try channel.poll(deadline + 100)) == null);
    try t.expectEqual(display_rpc.Phase.prepared, channel.exchange.phase);
    model.now = deadline;
    try t.expectError(error.Deadline, channel.poll(deadline + 100));
    try t.expectEqual(@as(u32, 0), session.tx_sequence);

    channel = try startDisplay(model, &session);
    try model.replyRpc(&session, .{ .function = 0x101c }, &.{1});
    event = (try channel.poll(deadline)).?;
    try t.expect(channel.exchange.in_lockdown);
    try channel.complete(event.ticket);
    try channel.begin(.supported, deadline);
    try t.expect((try channel.poll(deadline)) == null);
    try t.expectEqual(@as(u32, 0), session.tx_sequence);
    try model.replyRpc(&session, .{ .function = 0x101c }, &.{0});
    event = (try channel.poll(deadline)).?;
    try t.expect(channel.exchange.in_lockdown);
    try channel.complete(event.ticket);
    try t.expect(!channel.exchange.in_lockdown);
    try t.expect((try channel.poll(deadline)) == null);
    try t.expectEqual(@as(u32, 1), session.tx_sequence);

    for ([_]message.Rpc{
        .{ .function = 71, .result = 0 },
        .{ .function = 76, .result = 0, .cpu_rm_gfid = 1 },
        .{ .function = 76 },
        .{ .function = 76, .result = 0 },
    }, [_]anyerror{ error.Unexpected, error.Guest, error.Payload, error.Payload }) |rpc, err| {
        channel = try startDisplay(model, &session);
        try channel.begin(.supported, deadline);
        try t.expect((try channel.poll(deadline)) == null);
        try model.replyRpc(&session, rpc, "");
        try t.expectError(err, channel.poll(deadline));
        try t.expectEqual(display_rpc.Phase.failed, channel.exchange.phase);
        try t.expect(session.pending != null and channel.exchange.failure.?.ticket != null);
    }
    channel = try startDisplay(model, &session);
    try model.replyRpc(&session, .{ .function = 0x1003 }, "unimplemented event");
    event = (try channel.poll(deadline)).?;
    try t.expectError(error.Handler, channel.reject(event.ticket));
    try t.expect(session.pending != null);
}

fn objectPlan() !objects.Plan {
    return objects.Plan.init(7, .{ .client = 0xc100, .device = 0xd080, .subdevice = 0xd208, .display = 0xd073 }, 0xffffffff, "R4OS display");
}
fn startObjects(model: *Model, session: *transport.Session) !objects.Owner {
    var boot = try startBoot(model, session);
    try model.replyRpc(session, .{ .function = 0x1001, .result = 0 }, &.{ 0, 0, 0, 0 });
    try boot.complete((try boot.poll()).?.ticket);
    var runtime = try boot.handoff(deadline);
    const owner = try objects.Owner.init(&runtime, try objectPlan(), deadline);
    try t.expectError(error.State, objects.Owner.init(&runtime, try objectPlan(), deadline));
    model.count = 0;
    return owner;
}
fn objectReply(model: *Model, owner: *objects.Owner, status: u32, full: bool) !void {
    var bytes: [152]u8 = undefined;
    const operation = owner.outstanding.?;
    const request = try objects.encode(&owner.plan, operation, &bytes);
    put(&bytes, if (operation == .allocate) 16 else 12, status);
    const count = if (operation == .allocate and !full) 32 else request.bytes.len;
    try model.replyRpc(owner.exchange.session, .{ .function = request.function, .result = 0, .sequence = 0x99887766, .result_private = 0x1234 }, bytes[0..count]);
}
fn createOne(model: *Model, owner: *objects.Owner, kind: objects.Kind) !void {
    try t.expect((try owner.poll()) == null);
    try t.expectEqual(kind, owner.outstanding.?.allocate);
    try t.expectEqual(objects.Slot.creating, owner.slots[@intFromEnum(kind)]);
    try objectReply(model, owner, 0, kind == .device);
    try t.expect((try owner.poll()) == null);
    try t.expectEqual(objects.Slot.live, owner.slots[@intFromEnum(kind)]);
}
fn createAll(model: *Model, owner: *objects.Owner) !void {
    for (0..4) |i| try createOne(model, owner, @enumFromInt(i));
    try t.expectEqual(objects.State.objects_ready, owner.state);
}
fn checkObjects(model: *Model) !void {
    const plan = try objectPlan();
    var payload: [153]u8 = undefined;
    const ids = [_]u32{ 0xc100, 0xd080, 0xd208, 0xd073 };
    const classes = [_]u32{ 0, 0x80, 0x2080, 0x73 };
    const parents = [_]u32{ 0xc100, 0xc100, 0xd080, 0xd080 };
    const sizes = [_]usize{ 152, 88, 36, 32 };
    for (0..4) |i| {
        const operation = objects.Operation{ .allocate = @enumFromInt(i) };
        @memset(&payload, 0xa5);
        const encoded = try objects.encode(&plan, operation, &payload);
        try t.expectEqual(@as(u32, 103), encoded.function);
        try t.expectEqual(sizes[i], encoded.bytes.len);
        for ([_]u32{ 0xc100, parents[i], ids[i], classes[i], 0, @intCast(sizes[i] - 32), 0, 0 }, 0..) |value, j|
            try t.expectEqual(value, get(encoded.bytes, j * 4));
        try t.expectEqual(@as(u8, 0xa5), payload[sizes[i]]);
        if (i == 0) {
            try t.expectEqual(@as(u32, 0xc100), get(encoded.bytes, 32));
            try t.expectEqual(@as(u32, 0xffffffff), get(encoded.bytes, 36));
            try t.expectEqualStrings("R4OS display", encoded.bytes[40..52]);
            // All name tail, alignment padding and the570.144 OS pointer zero.
            for (encoded.bytes[52..152]) |byte| try t.expectEqual(@as(u8, 0), byte);
        } else if (i == 1) {
            try t.expectEqual(@as(u32, 0), get(encoded.bytes, 32));
            try t.expectEqual(@as(u32, 0xc100), get(encoded.bytes, 36));
            for (encoded.bytes[40..88]) |byte| try t.expectEqual(@as(u8, 0), byte);
        }
        try t.expectError(error.Bounds, objects.encode(&plan, operation, payload[0 .. sizes[i] - 1]));
        var record = message.Record{ .shape = undefined, .queue_sequence = 0, .rpc = .{ .function = 103, .result = 0 }, .payload = encoded.bytes };
        try t.expect((try objects.decode(&plan, operation, record)) == .ok);
        for (0..sizes[i]) |count| {
            record.payload = payload[0..count];
            if (count == 32) try t.expect((try objects.decode(&plan, operation, record)) == .ok) else try t.expectError(error.Payload, objects.decode(&plan, operation, record));
        }
        for ([_]usize{ 0, 4, 8, 12, 20, 24, 28 }) |offset| {
            _ = try objects.encode(&plan, operation, &payload);
            put(&payload, offset, get(&payload, offset) ^ 1);
            record.payload = payload[0..32];
            try t.expectError(if (offset < 16) error.Unexpected else error.Payload, objects.decode(&plan, operation, record));
        }
        const free = objects.Operation{ .free = @enumFromInt(i) };
        const freed = try objects.encode(&plan, free, &payload);
        try t.expectEqual(@as(u32, 10), freed.function);
        try t.expectEqual(@as(usize, 16), freed.bytes.len);
        for ([_]u32{ 0xc100, 0, ids[i], 0 }, 0..) |value, j| try t.expectEqual(value, get(freed.bytes, j * 4));
        record.rpc.function = 10;
        for (0..18) |count| {
            record.payload = payload[0..count];
            if (count == 16) try t.expect((try objects.decode(&plan, free, record)) == .ok) else try t.expectError(error.Payload, objects.decode(&plan, free, record));
        }
    }
    var bad_handles = plan.handles;
    bad_handles.display = bad_handles.client;
    try t.expectError(error.Handle, objects.Plan.init(7, bad_handles, 0, "x"));
    bad_handles.display = 0;
    try t.expectError(error.Handle, objects.Plan.init(7, bad_handles, 0, "x"));
    try t.expectError(error.Handle, objects.Plan.init(0, plan.handles, 0, "x"));
    const long_name: [100]u8 = @splat('a');
    try t.expectError(error.Payload, objects.Plan.init(7, plan.handles, 0, &long_name));
    try t.expectError(error.Payload, objects.Plan.init(7, plan.handles, 0, "a\x00b"));
    const longest = try objects.Plan.init(7, plan.handles, 0, long_name[0..99]);
    const max_name = try objects.encode(&longest, .{ .allocate = .client }, &payload);
    try t.expectEqual(@as(u8, 0), max_name.bytes[139]);
    for (max_name.bytes[140..152]) |byte| try t.expectEqual(@as(u8, 0), byte);

    var session: transport.Session = undefined;
    var owner = try startObjects(model, &session);
    try t.expectError(error.State, owner.loan(deadline));
    try t.expect((try owner.poll()) == null);
    try model.replyRpc(&session, .{ .function = 0x1003 }, "allocation notification");
    const notice = (try owner.poll()).?;
    const before = model.count;
    try t.expect(!notice.response);
    try t.expectError(error.Pending, owner.poll());
    try t.expectError(error.State, owner.beginDestroy(deadline));
    var wrong = notice.ticket;
    wrong.serial += 1;
    try t.expectError(error.Stale, owner.completeNotification(wrong));
    try t.expectEqual(before, model.count);
    try owner.completeNotification(notice.ticket);
    try objectReply(model, &owner, 0, false);
    try t.expect((try owner.poll()) == null);
    for (1..4) |i| try createOne(model, &owner, @enumFromInt(i));
    var loan = try owner.loan(deadline);
    try t.expectEqualDeep(display_object, loan.object);
    try t.expectError(error.State, owner.poll());
    var channel = try display_rpc.Channel.init(&loan.runtime, loan.object, deadline);
    try t.expectError(error.State, owner.reclaim(&loan.runtime, deadline));
    try t.expectEqual(transport.State.active, session.state);
    try channel.begin(.supported, deadline);
    try t.expect((try channel.poll(deadline)) == null);
    try displayReply(model, &channel, 0, 1);
    try channel.complete((try channel.poll(deadline)).?.ticket);
    var returned = try channel.handoff(deadline);
    // An old display owner must not stop the session after transferring it.
    try t.expectError(error.State, channel.poll(deadline));
    try t.expectEqual(transport.State.active, session.state);
    try owner.reclaim(&returned, deadline);
    try owner.beginDestroy(deadline);
    for (0..4) |i| {
        try t.expect((try owner.poll()) == null);
        const kind: objects.Kind = @enumFromInt(3 - i);
        try t.expectEqual(kind, owner.outstanding.?.free);
        try t.expectEqual(objects.Slot.freeing, owner.slots[3 - i]);
        try objectReply(model, &owner, 0, false);
        try t.expect((try owner.poll()) == null);
        try t.expectEqual(objects.Slot.absent, owner.slots[3 - i]);
    }
    try t.expectEqual(objects.State.objects_closed, owner.state);
    const finished = try owner.finish(deadline);
    try t.expectEqual(objects.State.finished, owner.state);
    try t.expect(finished.session == &session and !finished.claimed);
    try t.expectEqual(transport.State.active, session.state); // Not device quiescence.
    try t.expectError(error.State, owner.finish(deadline));

    // Every confirmed allocation rejection cleans only the live prefix in
    // reverse order, using an explicit bounded cleanup phase, not a retry.
    for (0..4) |failed_index| {
        owner = try startObjects(model, &session);
        for (0..failed_index) |i| try createOne(model, &owner, @enumFromInt(i));
        try t.expect((try owner.poll()) == null);
        try objectReply(model, &owner, 0x51, false);
        try t.expect((try owner.poll()) == null);
        try t.expectEqual(objects.State.rejected, owner.state);
        try t.expectEqual(objects.Slot.absent, owner.slots[failed_index]);
        model.now = deadline - 1;
        try owner.beginDestroy(deadline + 100);
        try t.expectEqual(@as(u64, deadline + 100), owner.deadline);
        var freed_count: usize = 0;
        while (owner.state == .destroying) {
            try t.expect((try owner.poll()) == null);
            if (owner.state == .objects_closed) break;
            try t.expectEqual(@as(objects.Kind, @enumFromInt(failed_index - freed_count - 1)), owner.outstanding.?.free);
            freed_count += 1;
            try objectReply(model, &owner, 0, false);
            try t.expect((try owner.poll()) == null);
        }
        try t.expectEqual(failed_index, freed_count);
        try t.expectEqual(objects.State.objects_closed, owner.state);
        _ = try owner.finish(deadline + 100);
    }
    // Failed free retains that object and every not-yet-freed ancestor.
    for (0..4) |failed_index| {
        owner = try startObjects(model, &session);
        try createAll(model, &owner);
        try owner.beginDestroy(deadline);
        for (0..4 - failed_index) |i| {
            try t.expect((try owner.poll()) == null);
            try objectReply(model, &owner, if (3 - i == failed_index) 0x55 else 0, false);
            if (3 - i == failed_index) try t.expectError(error.FirmwareResult, owner.poll()) else try t.expect((try owner.poll()) == null);
        }
        try t.expectEqual(objects.State.failed, owner.state);
        try t.expectEqual(objects.Slot.uncertain, owner.slots[failed_index]);
        for (owner.slots[0..failed_index]) |slot| try t.expectEqual(objects.Slot.live, slot);
        const count = model.count;
        try t.expectError(error.State, owner.poll());
        try t.expectError(error.State, owner.beginDestroy(deadline + 100));
        try t.expectEqual(count, model.count);
    }
    // Publication and ACK faults can occur after the pointer was visible;
    // neither missing local sequence advancement nor an OK reply permits reuse.
    for ([_]bool{ false, true }) |ack| for ([_]bool{ false, true }) |after| {
        owner = try startObjects(model, &session);
        if (ack) {
            try t.expect((try owner.poll()) == null);
            try objectReply(model, &owner, 0, false);
        }
        model.fault = model.count + 4;
        model.after = after;
        try t.expectError(error.Io, owner.poll());
        try t.expectEqual(objects.State.failed, owner.state);
        try t.expectEqual(objects.Slot.uncertain, owner.slots[0]);
        try t.expect(owner.outstanding != null);
        if (ack) try t.expect(session.pending != null);
        const count = model.count;
        try t.expectError(error.State, owner.poll());
        try t.expectEqual(count, model.count);
    };
    owner = try startObjects(model, &session);
    try t.expect((try owner.poll()) == null);
    model.now = deadline;
    try t.expectError(error.Deadline, owner.poll());
    try t.expectEqual(objects.Slot.uncertain, owner.slots[0]);
    owner = try startObjects(model, &session);
    try t.expect((try owner.poll()) == null);
    try model.replyRpc(&session, .{ .function = 0x1003 }, "deferred");
    const deferred = (try owner.poll()).?;
    model.epoch += 1;
    try t.expectError(error.Stale, owner.borrowNotification(deferred.ticket));
    try t.expectEqual(objects.State.failed, owner.state);
    try t.expect(session.pending != null and owner.slots[0] == .uncertain);
}

fn runtimeEvent(model: *Model, function: u32, bytes: []const u8) !runtime_events.Event {
    const shape = try message.encode(profile, 0, .{ .function = function, .result = 0 }, bytes, &model.frame);
    return runtime_events.decode(try message.decode(profile, model.frame[0..shape.storage_bytes], 0));
}
fn postPayload(bytes: *[40]u8) []const u8 {
    @memset(bytes, 0xcc); // Nonzero C padding is valid, including the trailing3 bytes.
    put(bytes, 0, 0x1234);
    put(bytes, 4, 0x56);
    put(bytes, 8, 1);
    put(bytes, 12, 0x42);
    std.mem.writeInt(u16, bytes[16..18], 0x789a, .little);
    put(bytes, 20, 0xaabb);
    put(bytes, 24, 8);
    bytes[28] = 1;
    put(bytes, 29, 0x80000001); // Flexible data starts BEFORE sizeof(header).
    put(bytes, 33, 1);
    return bytes;
}
const EventSink = struct {
    const Fault = enum { none, deny, before, after, late, stale, ack, expired, unknown, sequencer, lockdown };
    model: *Model,
    owner: *@import("gsp_exchange.zig").Exchange,
    fault: Fault,
    admissions: usize = 0,
    attempts: usize = 0,
    effects: usize = 0,
    display: ?runtime_events.Display = null,
    fn from(p: *anyopaque) *EventSink {
        return @ptrCast(@alignCast(p));
    }
    fn generation(p: *anyopaque) u64 {
        return from(p).model.epoch;
    }
    fn admit(p: *anyopaque, _: runtime_events.Scope, event: runtime_events.Event) error{ Denied, Unsupported }!void {
        const self = from(p);
        self.admissions += 1;
        if (self.fault == .deny) return error.Unsupported;
        if (event == .post_event) {
            const v = event.post_event;
            if (v.client != 0x1234 or v.event != 0x56 or v.index != 1 or !v.notify_list) return error.Denied;
        } else if (event != .lockdown) return error.Unsupported;
    }
    fn deliver(p: *anyopaque, scope: runtime_events.Scope, event: runtime_events.Event) anyerror!void {
        const self = from(p);
        try t.expect(scope.epoch == self.model.epoch and scope.deadline == self.owner.deadline.?);
        try t.expectEqualDeep(scope.ticket, self.owner.pending.?.ticket);
        try t.expect(self.model.now < scope.deadline);
        self.attempts += 1;
        if (self.fault == .before) return error.SinkFailure;
        if (event == .post_event) self.display = try event.post_event.display() else try t.expect(self.owner.in_lockdown);
        self.effects += 1;
        if (self.fault == .after) return error.SinkFailure;
        if (self.fault == .late) self.model.now = scope.deadline;
        if (self.fault == .stale) self.model.epoch += 1;
    }
    fn sink(self: *EventSink) runtime_events.Sink {
        return .{ .context = self, .generation = generation, .admit = admit, .deliver = deliver };
    }
};
fn checkRuntimeEvents(model: *Model) !void {
    var post: [40]u8 = undefined;
    var event = try runtimeEvent(model, 0x1003, postPayload(&post));
    const p = event.post_event;
    try t.expect(p.client == 0x1234 and p.event == 0x56 and p.data == 0x42 and p.info16 == 0x789a and p.status == 0xaabb and p.notify_list);
    const hpd = (try p.display()).?.hotplug;
    try t.expect(hpd.plug_mask == 0x80000001 and hpd.unplug_mask == 1); // Keep overlapping/high bits; no guessed state.
    put(&post, 8, 7);
    put(&post, 24, 4);
    event = try runtimeEvent(model, 0x1003, post[0..36]);
    try t.expectEqual(@as(u32, 0x80000001), (try event.post_event.display()).?.dp_irq);
    put(&post, 8, 1);
    event = try runtimeEvent(model, 0x1003, post[0..36]);
    try t.expectError(error.Payload, event.post_event.display());
    put(&post, 24, 0xffffffff);
    try t.expectError(error.Payload, runtimeEvent(model, 0x1003, &post));
    _ = postPayload(&post);
    post[28] = 2;
    try t.expectError(error.Payload, runtimeEvent(model, 0x1003, &post));
    try t.expectError(error.Payload, runtimeEvent(model, 0x1003, post[0..31]));
    var rc: [52]u8 = @splat(0xcc);
    for ([_]u32{ 9, 0x123, 0, 2, 7, 8 }, 0..) |value, index| put(&rc, index * 4, value);
    std.mem.writeInt(u16, rc[24..26], 0x3210, .little);
    put(&rc, 28, 0x55667788);
    put(&rc, 32, 0x11223344);
    put(&rc, 36, 17);
    rc[40] = 1;
    put(&rc, 44, 4);
    @memcpy(rc[48..52], "jrnl");
    const fault = (try runtimeEvent(model, 0x1004, &rc)).rc_triggered;
    try t.expect(fault.channel == 0x123 and fault.partition == 0x3210 and fault.fault_address == 0x1122334455667788 and fault.fault_type == 17 and fault.callback_needed);
    try t.expectEqualStrings("jrnl", fault.journal);
    put(&rc, 8, 1);
    try t.expectError(error.Guest, runtimeEvent(model, 0x1004, &rc));
    put(&rc, 8, 0);
    put(&rc, 44, 5);
    try t.expectError(error.Payload, runtimeEvent(model, 0x1004, &rc));
    try t.expect((try runtimeEvent(model, 0x1005, &.{})) == .mmu_fault_queued);
    try t.expectError(error.Payload, runtimeEvent(model, 0x1005, &.{0}));
    var fixed: [12]u8 = @splat(0xcc);
    put(&fixed, 0, 3);
    put(&fixed, 4, 0x55);
    try t.expect((try runtimeEvent(model, 0x1007, fixed[0..8])).rg_line_intr.interrupts == 0x55);
    fixed[0] = 1;
    put(&fixed, 4, 1234);
    put(&fixed, 8, 5678);
    const mode = (try runtimeEvent(model, 0x1011, &fixed)).display_modeset;
    try t.expect(mode.start and mode.iso_bandwidth_kbps == 1234 and mode.floor_bandwidth_kbps == 5678);
    try t.expect((try runtimeEvent(model, 0x1012, &.{ 2, 3, 4, 1 })).extdev_intr_service.rm_status);
    try t.expectError(error.Payload, runtimeEvent(model, 0x1012, &.{ 2, 3, 4, 2 }));
    put(&fixed, 0, 2);
    fixed[4] = 5;
    try t.expect((try runtimeEvent(model, 0x1021, fixed[0..8])).fecs_error.error_type == 5);
    fixed[4] = 1;
    try t.expect((try runtimeEvent(model, 0x1022, fixed[0..8])).recovery_action.value);
    fixed[4] = 2;
    try t.expectError(error.Payload, runtimeEvent(model, 0x1022, fixed[0..8]));
    try t.expectError(error.UnknownEvent, runtimeEvent(model, 0x100e, &.{}));
    // Existing boot decoder is reused for log/error/lockdown/NOCAT layouts.
    for (std.enums.values(EventSink.Fault)) |scenario| {
        var session: transport.Session = undefined;
        var boot = try startBoot(model, &session);
        try model.replyRpc(&session, .{ .function = 0x1001, .result = 0 }, &.{ 0, 0, 0, 0 });
        try boot.complete((try boot.poll()).?.ticket);
        var token = try boot.handoff(deadline);
        var owner = try @import("gsp_exchange.zig").Exchange.init(&token, 3000);
        model.now = 1200;
        try owner.begin(79, "runtime request", 3000);
        try t.expect((try owner.poll(3000)) == null);
        const function: u32 = switch (scenario) {
            .unknown => 0x100e,
            .sequencer => 0x1002,
            .lockdown => 0x101c,
            else => 0x1003,
        };
        if (scenario == .lockdown) owner.in_lockdown = true; // Model an already engaged runtime lockdown.
        try model.replyRpc(&session, .{ .function = function, .result = 0 }, if (scenario == .lockdown) &.{0} else postPayload(&post));
        const receipt = (try owner.poll(3000)).?;
        const cursor = model.peerWord(session.link.?.status_read);
        var sink: EventSink = .{ .model = model, .owner = &owner, .fault = scenario };
        if (scenario == .deny or scenario == .unknown or scenario == .sequencer) {
            try t.expectError(switch (scenario) {
                .deny => error.Unsupported,
                .unknown => error.UnknownEvent,
                else => error.SequencerRequired,
            }, runtime_events.Dispatch.init(&owner, sink.sink()));
            try t.expect(sink.effects == 0 and session.pending != null);
            try t.expectEqual(cursor, model.peerWord(session.link.?.status_read));
            try t.expect(if (scenario == .sequencer) owner.phase == .waiting else owner.phase == .failed);
            continue;
        }
        var dispatch = try runtime_events.Dispatch.init(&owner, sink.sink());
        try t.expect(sink.admissions == 1 and sink.attempts == 0);
        if (scenario == .ack) {
            model.fault = model.count + 1;
            model.after = true;
        }
        if (scenario == .expired) model.now = 3000;
        switch (scenario) {
            .none, .lockdown => {
                try dispatch.step();
                try t.expect(dispatch.delivered and dispatch.acknowledged and owner.pending == null and session.pending == null);
                try t.expect(owner.phase == .waiting and owner.function == 79 and owner.deadline == 3000 and !owner.in_lockdown);
            },
            else => {
                const expected: runtime_events.Error = switch (scenario) {
                    .before, .after => error.Handler,
                    .late, .expired => error.Deadline,
                    .stale => error.Stale,
                    .ack => error.Io,
                    else => unreachable,
                };
                try t.expectError(expected, dispatch.step());
                try t.expect(dispatch.failed and !dispatch.acknowledged and owner.phase == .failed and session.pending != null);
                if (scenario == .before or scenario == .after) try t.expectEqual(error.SinkFailure, dispatch.failure.?);
            },
        }
        try t.expectEqual(@as(usize, if (scenario == .before or scenario == .expired) 0 else 1), sink.effects);
        try t.expectEqual(if (dispatch.acknowledged or scenario == .ack) receipt.ticket.next else cursor, model.peerWord(session.link.?.status_read));
        const calls = model.count;
        const attempts = sink.attempts;
        if (dispatch.failed) try t.expectError(error.State, dispatch.step()) else try dispatch.step();
        try t.expect(model.count == calls and sink.attempts == attempts and model.notifications == 1);
    }
}

fn eventPlan() !event_objects.Plan {
    return event_objects.Plan.init(try objectPlan(), .{ .hotplug = 0xe001, .dp_irq = 0xe007 });
}
fn startEventObjects(model: *Model, base: *objects.Owner) !event_objects.Owner {
    try createAll(model, base);
    var loan = try base.loan(deadline);
    model.count = 0;
    return event_objects.Owner.init(&loan.runtime, try eventPlan(), deadline);
}
fn eventReply(model: *Model, owner: *event_objects.Owner, status: u32) !void {
    var bytes: [56]u8 = undefined;
    const operation = owner.outstanding.?;
    const encoded = try event_objects.encode(&owner.plan, operation, &bytes);
    put(&bytes, if (operation == .allocate) 16 else 12, status);
    if (operation == .enable or operation == .disable) {
        // Failed controls may leave copyout untouched, including invalid bool.
        bytes[32] = if (status == 0) 1 else 0xff;
        bytes[33] = 0xa5;
        put(&bytes, 36, 0x80000005);
        std.mem.writeInt(u16, bytes[40..42], 0x79ab, .little);
        bytes[42] = 0xff;
    }
    const count = if (operation == .allocate and operation.allocate == .hotplug) 32 else encoded.bytes.len;
    try model.replyRpc(owner.exchange.session, .{ .function = encoded.function, .result = 0 }, bytes[0..count]);
}
fn eventOperation(model: *Model, owner: *event_objects.Owner, expected: event_objects.Operation, status: u32) !void {
    try t.expect((try owner.poll()) == null);
    try t.expectEqualDeep(expected, owner.outstanding.?);
    try eventReply(model, owner, status);
    try t.expect((try owner.poll()) == null);
}
const event_create = [_]event_objects.Operation{ .{ .allocate = .hotplug }, .{ .enable = .hotplug }, .{ .allocate = .dp_irq }, .{ .enable = .dp_irq } };
const event_destroy = [_]event_objects.Operation{ .{ .disable = .dp_irq }, .{ .free = .dp_irq }, .{ .disable = .hotplug }, .{ .free = .hotplug } };
fn registeredPost(bytes: *[40]u8, kind: event_objects.Kind, list: bool) []const u8 {
    _ = postPayload(bytes);
    put(bytes, 0, 0xc100);
    put(bytes, 4, if (kind == .hotplug) 0xe001 else 0xe007);
    put(bytes, 8, event_objects.index(kind));
    put(bytes, 20, 0);
    put(bytes, 24, if (kind == .hotplug) 8 else 4);
    bytes[28] = @intFromBool(list);
    return bytes[0..if (kind == .hotplug) @as(usize, 40) else 36];
}
fn checkEventObjects(model: *Model) !void {
    const plan = try eventPlan();
    try t.expectError(error.Handle, event_objects.Plan.init(plan.base, .{ .hotplug = 0, .dp_irq = 0xe007 }));
    try t.expectError(error.Handle, event_objects.Plan.init(plan.base, .{ .hotplug = 0xe001, .dp_irq = 0xe001 }));
    try t.expectError(error.Handle, event_objects.Plan.init(plan.base, .{ .hotplug = plan.base.handles.subdevice, .dp_irq = 0xe007 }));
    var bytes: [56]u8 = undefined;
    const alloc = try event_objects.encode(&plan, .{ .allocate = .hotplug }, &bytes);
    try t.expectEqual(@as(u32, 103), alloc.function);
    for ([_]u32{ 0xc100, 0xd208, 0xe001, 0x7e, 0, 24, 0, 0, 0xc100, 0, 0x7e, 0x04000001, 0, 0 }, 0..) |value, i| try t.expectEqual(value, get(&bytes, i * 4));
    const enable = try event_objects.encode(&plan, .{ .enable = .dp_irq }, &bytes);
    try t.expect(enable.function == 76 and enable.bytes.len == 44);
    for ([_]u32{ 0xc100, 0xd208, 0x20800301, 0, 20, 0, 7, 2, 0, 0, 0 }, 0..) |value, i| try t.expectEqual(value, get(enable.bytes, i * 4));
    try t.expectError(error.Bounds, event_objects.encode(&plan, .{ .allocate = .hotplug }, bytes[0..55]));
    // Original output padding is arbitrary; active fields and identities are not.
    bytes[32] = 1;
    bytes[33] = 0xff;
    put(&bytes, 36, 0x80000001);
    std.mem.writeInt(u16, bytes[40..42], 0x79ab, .little);
    const shape = try message.encode(profile, 0, .{ .function = 76, .result = 0 }, enable.bytes, &model.frame);
    var record = try message.decode(profile, model.frame[0..shape.storage_bytes], 0);
    const valid = try event_objects.decode(&plan, .{ .enable = .dp_irq }, record);
    try t.expectEqualDeep(event_objects.Initial{ .notify_state = true, .info32 = 0x80000001, .info16 = 0x79ab }, valid.ok.?);
    const original = record.payload;
    record.payload = original[0..43];
    try t.expectError(error.Payload, event_objects.decode(&plan, .{ .enable = .dp_irq }, record));
    record.payload = bytes[0..44];
    bytes[32] = 2;
    try t.expectError(error.Payload, event_objects.decode(&plan, .{ .enable = .dp_irq }, record));
    put(&bytes, 12, 0x55);
    try t.expectEqual(@as(u32, 0x55), (try event_objects.decode(&plan, .{ .enable = .dp_irq }, record)).rm_error);
    put(&bytes, 4, 0xd209);
    try t.expectError(error.Unexpected, event_objects.decode(&plan, .{ .enable = .dp_irq }, record));

    var session: transport.Session = undefined;
    var base = try startObjects(model, &session);
    var owner = try startEventObjects(model, &base);
    try t.expectError(error.State, owner.loan(deadline));
    for (event_create) |operation| try eventOperation(model, &owner, operation, 0);
    try t.expect(owner.state == .ready and base.state == .loaned);
    try t.expectEqual(@as(u16, 0x79ab), owner.slots[0].initial.?.info16);
    var loan = try owner.loan(deadline);
    var channel = try display_rpc.Channel.init(&loan.runtime, loan.object, deadline);
    try t.expectError(error.State, owner.poll());
    try t.expectError(error.State, owner.reclaim(&loan.runtime, deadline));
    try t.expect(session.state == .active);
    try channel.begin(.supported, deadline);
    try t.expect((try channel.poll(deadline)) == null);
    try displayReply(model, &channel, 0, 0x80000001);
    try channel.complete((try channel.poll(deadline)).?.ticket);
    try channel.begin(.{ .connected = 0x80000001 }, deadline);
    try t.expect((try channel.poll(deadline)) == null);
    var post: [40]u8 = undefined;
    // Both routing forms reach the sole matching registration, even while
    // the runtime queue belongs to a display query under the event graph loan.
    for ([_]event_objects.Kind{ .hotplug, .dp_irq }, 0..) |kind, i| {
        try model.replyRpc(&session, .{ .function = 0x1003, .result = 0 }, registeredPost(&post, kind, i == 0));
        const received = (try channel.poll(deadline)).?;
        try t.expect(received.value == .notification and channel.request != null);
        var handler = try runtime_events.Dispatch.initDisplay(&channel, owner.sink());
        try t.expectError(error.Pending, owner.takeChanges(deadline));
        const kicks = model.notifications;
        try handler.step();
        try t.expect(handler.acknowledged and channel.pending == null and channel.exchange.pending == null and session.pending == null);
        try t.expect(channel.exchange.phase == .waiting and channel.request != null and model.notifications == kicks);
        const effects = model.count;
        try handler.step();
        try t.expectEqual(effects, model.count);
    }
    const changes = try owner.takeChanges(deadline);
    try t.expectEqualDeep(event_objects.Changes{ .serial = 2, .plug = 0x80000001, .unplug = 1, .dp_irq = 0x80000001 }, changes);
    try t.expectEqualDeep(event_objects.Changes{ .serial = 2 }, try owner.takeChanges(deadline));
    @memset(&model.rx, 0xcc); // Delivered state holds no borrowed firmware bytes.
    try displayReply(model, &channel, 0, 0x80000001);
    const obsolete = (try channel.poll(deadline)).?;
    try t.expect(obsolete.value.reply == .obsolete and channel.connected == 0);
    try channel.complete(obsolete.ticket);
    var returned = try channel.handoff(deadline);
    try owner.reclaim(&returned, deadline);
    model.count = 0;
    try owner.beginDestroy(deadline);
    for (event_destroy) |operation| try eventOperation(model, &owner, operation, 0);
    var finished = try owner.finish(deadline);
    try t.expect(owner.sink().generation(&owner) == 0);
    try base.reclaim(&finished, deadline);
    try base.beginDestroy(deadline);
    for (0..4) |i| {
        try t.expect((try base.poll()) == null);
        try t.expectEqual(@as(objects.Kind, @enumFromInt(3 - i)), base.outstanding.?.free);
        try objectReply(model, &base, 0, false);
        try t.expect((try base.poll()) == null);
    }
    _ = try base.finish(deadline);
    try t.expect(session.state == .active); // Object cleanup is not GPU quiescence.

    // A confirmed allocation/enable rejection permits bounded cleanup of the
    // live prefix. A failed enable is disabled before its object can be freed.
    for (0..event_create.len) |failed| {
        base = try startObjects(model, &session);
        owner = try startEventObjects(model, &base);
        for (event_create[0..failed]) |operation| try eventOperation(model, &owner, operation, 0);
        try eventOperation(model, &owner, event_create[failed], 0x51);
        try t.expect(owner.state == .rejected and base.state == .loaned);
        try owner.beginDestroy(deadline + 100);
        const first: usize = switch (failed) {
            0 => 4,
            1, 2 => 2,
            3 => 0,
            else => unreachable,
        };
        for (event_destroy[first..]) |operation| try eventOperation(model, &owner, operation, 0);
        if (failed == 0) try t.expect((try owner.poll()) == null);
        _ = try owner.finish(deadline + 100);
    }
    // Stop on each failed teardown operation and retain the parent graph.
    for (0..event_destroy.len) |failed| {
        base = try startObjects(model, &session);
        owner = try startEventObjects(model, &base);
        for (event_create) |operation| try eventOperation(model, &owner, operation, 0);
        try owner.beginDestroy(deadline);
        for (event_destroy[0..failed]) |operation| try eventOperation(model, &owner, operation, 0);
        try t.expect((try owner.poll()) == null);
        try eventReply(model, &owner, 0x55);
        try t.expectError(error.FirmwareResult, owner.poll());
        try t.expect(owner.state == .failed and base.state == .loaned and session.state == .failed);
        try t.expectError(error.State, owner.finish(deadline));
        const count = model.count;
        try t.expectError(error.State, owner.poll());
        try t.expectEqual(count, model.count);
        for (base.slots) |slot| try t.expectEqual(objects.Slot.live, slot);
    }
    // Exact registration matching, late queued events during enable/disable,
    // and an ACK lost after effects must all use the real retained receipt.
    const Fault = enum { none, disabling, client, event, index, ack, stale, expired };
    for (std.enums.values(Fault)) |fault| {
        base = try startObjects(model, &session);
        owner = try startEventObjects(model, &base);
        try eventOperation(model, &owner, event_create[0], 0);
        if (fault == .disabling) {
            for (event_create[1..]) |operation| try eventOperation(model, &owner, operation, 0);
            try owner.beginDestroy(deadline);
        }
        try t.expect((try owner.poll()) == null);
        const payload = registeredPost(&post, if (fault == .disabling) .dp_irq else .hotplug, false);
        put(&post, 20, 0x51);
        if (fault == .client) put(&post, 0, 0xc101);
        if (fault == .event) put(&post, 4, 0xe007);
        if (fault == .index) put(&post, 8, 7);
        try model.replyRpc(&session, .{ .function = 0x1003, .result = 0 }, payload);
        _ = (try owner.poll()).?;
        if (fault == .client or fault == .event or fault == .index) {
            try t.expectError(error.Denied, runtime_events.Dispatch.init(&owner.exchange, owner.sink()));
            try t.expect(owner.changes.serial == 0 and session.pending != null and session.state == .failed);
            continue;
        }
        var handler = try runtime_events.Dispatch.init(&owner.exchange, owner.sink());
        if (fault == .ack) {
            model.fault = model.count + 1;
            model.after = true;
        }
        if (fault == .stale) model.epoch += 1;
        if (fault == .expired) model.now = deadline;
        if (fault == .none or fault == .disabling) {
            try handler.step();
            try t.expect(owner.changes.serial == 1 and owner.changes.event_error and session.pending == null);
            try eventReply(model, &owner, 0);
            try t.expect((try owner.poll()) == null);
        } else {
            try t.expectError(switch (fault) {
                .ack => error.Io,
                .stale => error.Stale,
                .expired => error.Deadline,
                else => unreachable,
            }, handler.step());
            try t.expect(session.state == .failed and session.pending != null);
            try t.expectEqual(@as(u64, if (fault == .ack) 1 else 0), owner.changes.serial);
            const count = model.count;
            try t.expectError(error.State, handler.step());
            try t.expectEqual(count, model.count);
        }
    }
}

fn graphOperation(model: *Model, owner: *rm_graph.Owner, status: u32) !void {
    try t.expect((try owner.poll()) == null);
    switch (owner.state) {
        .base_creating, .base_destroying => {
            if (owner.base.outstanding == null) return;
            try objectReply(model, &owner.base, status, false);
        },
        .events_creating, .events_destroying => {
            if (owner.subscriptions.?.outstanding == null) return;
            try eventReply(model, &owner.subscriptions.?, status);
        },
        .i2c_creating, .i2c_destroying => {
            const child = &owner.i2c.?;
            if (child.outstanding == null) return;
            var reply: [32]u8 = undefined;
            const encoded = try objects.encode(&child.plan, child.outstanding.?, &reply);
            put(&reply, if (encoded.function == 103) 16 else 12, status);
            try model.replyRpc(child.exchange.session, .{ .function = encoded.function, .result = 0 }, encoded.bytes);
        },
        .vaspace_creating, .vaspace_destroying => {
            const child = &owner.address_space.?;
            if (child.outstanding == null) return;
            var reply: [80]u8 = undefined;
            const encoded = try objects.encode(&child.plan, child.outstanding.?, &reply);
            put(&reply, if (encoded.function == 103) 16 else 12, status);
            if (encoded.function == 103 and status == 0) {
                std.mem.writeInt(u64, reply[40..48], 0x100000000, .little);
                std.mem.writeInt(u64, reply[72..80], 0x200000, .little);
            }
            try model.replyRpc(child.exchange.session, .{ .function = encoded.function, .result = 0 }, encoded.bytes);
        },
        .closed => return,
        else => return error.InvalidGraphProgress,
    }
    try t.expect((try owner.poll()) == null);
}
fn graphCreate(model: *Model, owner: *rm_graph.Owner) !void {
    for (0..16) |_| {
        if (owner.state == .ready) break;
        try graphOperation(model, owner, 0);
    }
    try t.expect(owner.state == .ready and owner.base.state == .loaned and owner.subscriptions.?.state == .ready);
    try t.expect(owner.i2c.?.live and owner.i2c.?.state == .handed_off);
    const info = owner.address_space.?.info orelse return error.MissingAddressSpace;
    try t.expect(owner.address_space.?.state == .handed_off and info.base == 0x200000 and info.bytes == 0x100000000);
}
fn graphDestroy(model: *Model, owner: *rm_graph.Owner) !boot_events.Handoff {
    try owner.beginDestroy(deadline);
    for (0..16) |_| {
        if (owner.state == .closed) break;
        try graphOperation(model, owner, 0);
    }
    try t.expect(owner.state == .closed and owner.base.state == .objects_closed);
    try t.expect(!owner.i2c.?.live and owner.i2c.?.state == .finished);
    try t.expect(owner.address_space.?.info == null and owner.address_space.?.state == .finished);
    return owner.finish(deadline);
}
fn checkRmGraph(model: *Model) !void {
    {
        const caps = @import("gsp_memory_caps.zig");
        const golden = @embedFile("fixtures/memory-caps-570.144.bin");
        const binding: caps.Binding = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000 };
        var encoded: [caps.bytes]u8 = undefined;
        for (0..6) |index| {
            const pair = golden[index * 2 * caps.bytes ..][0 .. 2 * caps.bytes];
            try t.expectEqualSlices(u8, pair[0..caps.bytes], try caps.encode(binding, &encoded));
            var record: message.Record = .{ .shape = .{ .message_bytes = caps.bytes + 80, .checksum_bytes = caps.bytes + 80, .storage_bytes = 4096, .elements = 1 },
                .queue_sequence = 0, .rpc = .{ .function = caps.function, .result = 0 }, .payload = pair[caps.bytes..] };
            const reply = try caps.decode(binding, record);
            if (index == 5) try t.expect(reply == .rejected and reply.rejected == 0x51) else {
                try t.expect(reply == .ok and std.meta.eql(reply.ok.binding, binding));
                try t.expectEqualSlices(u8, pair[caps.bytes + 24..], &reply.ok.raw);
                const info = reply.ok;
                try t.expect(info.renderSystem() == (index == 0 or index == 4) and info.scanoutSystem() == info.renderSystem());
                try t.expect(info.gpuCachedSystem() == info.renderSystem() and info.blocklinear() == (index != 1));
                try t.expect(info.gobBytes() == @as(u16, if (index == 0 or index == 2 or index == 4) 512 else 0));
                try t.expect(info.genericPageKind() == @as(u8, if (index == 0 or index == 4) 6 else 0xfe));
                try t.expect(info.vidmemCleared() == (index == 0 or index == 4) and info.partialUnmap() == info.vidmemCleared());
            }
            record.payload = pair[caps.bytes..][0..26];
            try t.expectError(error.Payload, caps.decode(binding, record));
            record.payload = pair[caps.bytes..];
            record.rpc.result = message.pending;
            try t.expectError(error.Payload, caps.decode(binding, record));
            record.rpc.result = 5;
            try t.expectError(error.FirmwareResult, caps.decode(binding, record));
        }
        for (0..caps.bytes) |size| try t.expectError(error.Bounds, caps.encode(binding, encoded[0..size]));
        var record: message.Record = .{ .shape = .{ .message_bytes = caps.bytes + 80, .checksum_bytes = caps.bytes + 80, .storage_bytes = 4096, .elements = 1 },
            .queue_sequence = 0, .rpc = .{ .function = caps.function, .result = 0 }, .payload = &encoded };
        for ([_]usize{0,4,8,16,20}) |offset| {
            @memcpy(&encoded, golden[caps.bytes..][0..caps.bytes]);
            encoded[offset] ^= 1;
            try t.expectError(error.Unexpected, caps.decode(binding, record));
        }
        @memcpy(&encoded, golden[caps.bytes..][0..caps.bytes]);
        record.rpc.function += 1;
        try t.expectError(error.Unexpected, caps.decode(binding, record));
        record.rpc.function = caps.function;
        record.rpc.cpu_rm_gfid = 1;
        try t.expectError(error.Unexpected, caps.decode(binding, record));
        try t.expectError(error.Handle, caps.encode(.{ .epoch = 0, .client = binding.client, .device = binding.device }, &encoded));
    }
    {
        const wire = @import("gsp_buffer_wire.zig");
        const golden = @embedFile("fixtures/control-buffer-570.144.bin");
        const binding = wire.Binding{ .space = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000,
            .handle = 0x10000006, .base = 0x200000, .bytes = 0x100000000, .big_page_bytes = 65536 }, .memory = 0x10000007, .virtual = 0x10000008 };
        const pages = [_]u64{0x100000000,0x300000000,0x100004000};
        var request: [wire.max_request_bytes]u8 = undefined;
        var offset: usize = 0;
        var address: u64 = 0;
        for (std.enums.values(wire.Operation)) |operation| {
            const encoded = try wire.encode(binding, operation, &pages, address, &request);
            const size = wire.length(operation);
            try t.expectEqualSlices(u8, golden[offset..][0..size], encoded.bytes);
            const reply = try wire.decode(binding, operation, encoded.bytes,
                .{ .shape = .{ .message_bytes = size + 80, .checksum_bytes = size + 80, .storage_bytes = 4096, .elements = 1 },
                    .queue_sequence = 0, .rpc = .{ .function = encoded.function, .result = 0 }, .payload = golden[offset+size..][0..size] }, address);
            try t.expect(reply == .ok);
            if (operation == .allocate) address = reply.ok;
            offset += size * 2;
        }
        try t.expect(offset == golden.len and address == 0x600000);
        try t.expectError(error.Bounds, wire.addressValid(binding, 0x200000 - 4096));
        try t.expectError(error.Bounds, wire.addressValid(binding, 0x100200000 - 4096));
        var alias = pages;alias[2] = alias[0];
        try t.expectError(error.Bounds, wire.encode(binding, .register, &alias, 0, &request));
    }
    {
        const vaspace = @import("gsp_vaspace.zig");
        const golden = @embedFile("fixtures/vaspace-570.144.bin");
        const plan = try objects.Plan.init(7, .{ .client = 0xc1d00000, .device = 0x10000000,
            .subdevice = 0x10000001, .display = 0x10000002, .i2c = 0x10000005, .vaspace = 0x10000006 }, 0xffffffff, "");
        var request: [80]u8 = undefined;
        const encoded = try objects.encode(&plan, .{ .allocate = .vaspace }, &request);
        try t.expect(encoded.function == 103 and encoded.bytes.len == 80);
        try t.expectEqualSlices(u8, golden[0..80], encoded.bytes);
        const info = try vaspace.decodeInfo(&plan, golden[80..160]);
        try t.expect(info.base == 0x200000 and info.bytes == 0x100000000 and info.base + info.bytes == 0x100200000);
        try t.expect(info.handle == plan.handles.vaspace and info.big_page_bytes == 65536);
        try t.expectError(error.Payload, vaspace.decodeInfo(&plan, golden[80..112]));
        var response: [80]u8 = golden[80..160].*;
        put(&response, 36, 8); // External ownership was never requested.
        try t.expectError(error.Payload, vaspace.decodeInfo(&plan, &response));
        response = golden[80..160].*;
        std.mem.writeInt(u64, response[72..80], std.math.maxInt(u64) - 4095, .little);
        try t.expectError(error.Bounds, vaspace.decodeInfo(&plan, &response));
    }
    {
        const wire = @import("gsp_buffer_wire.zig");
        const golden = @embedFile("fixtures/buffer-part-570.144.bin");
        const binding: wire.Binding = .{ .space = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000,
            .handle = 0x10000006, .base = 0x200000, .bytes = 0x100000000, .big_page_bytes = 65536 }, .memory = 0x10000007, .virtual = 0x10000008 };
        const part: wire.Part = .{ .total_bytes = 80 * 1024 * 1024, .offset = 8175 * 4096, .byte_length = 12288 };
        const pages = [_]u64{0x100000000,0x300000000,0x100004000};
        var request: [160]u8 = undefined;
        var address: u64 = 0;
        var offset: usize = 0;
        for (std.enums.values(wire.Operation)) |operation| {
            const encoded = try wire.encodePart(binding, part, operation, &pages, address, &request);
            const size = wire.partLength(operation, part);
            try t.expectEqualSlices(u8, golden[offset..][0..size], encoded.bytes);
            const reply = try wire.decodePart(binding, part, operation, encoded.bytes,
                .{ .shape = .{ .message_bytes = size + 80, .checksum_bytes = size + 80, .storage_bytes = 4096, .elements = 1 },
                    .queue_sequence = 0, .rpc = .{ .function = encoded.function, .result = 0 }, .payload = golden[offset+size..][0..size] }, address);
            try t.expect(reply == .ok);
            if (operation == .allocate) address = reply.ok;
            offset += size * 2;
        }
        try t.expect(offset == golden.len and address == 0x600000 and wire.max_registration_pages == 8175);
        try t.expectError(error.Bounds, wire.validatePart(binding, .{ .total_bytes = 4096, .offset = 4096, .byte_length = 4096 }));
        const large: wire.Part = .{ .total_bytes = 80 * 1024 * 1024, .byte_length = 8176 * 4096 };
        try wire.validatePart(binding, large); // Valid VA extent; only registration is transport bounded.
        var small: [160]u8 = undefined;
        try t.expectError(error.Bounds, wire.encodePart(binding, large, .register, &.{}, 0, &small));
        try t.expectError(error.Bounds, wire.encodePart(binding, part, .map, &.{}, 0, &request));
    }
    {
        const wire = @import("gsp_vram_wire.zig");
        const golden = @embedFile("fixtures/vram-570.144.bin");
        const binding: wire.Binding = .{ .space = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000, .handle = 0x10000006,
            .base = 0x200000, .bytes = 0x100000000, .big_page_bytes = 65536 }, .memory = 0x10000007, .virtual = 0x10000008 };
        var request: [160]u8 = undefined;
        var address: u64 = 0;
        var offset: usize = 0;
        for (std.enums.values(wire.Operation)) |operation| {
            const encoded = try wire.encode(binding, 64 * 1024 * 1024, operation, address, &request);
            const size = encoded.bytes.len;
            try t.expectEqualSlices(u8, golden[offset..][0..size], encoded.bytes);
            const reply = try wire.decode(binding, 64 * 1024 * 1024, operation, encoded.bytes,
                .{ .shape = .{ .message_bytes = size + 80, .checksum_bytes = size + 80, .storage_bytes = 4096, .elements = 1 },
                    .queue_sequence = 0, .rpc = .{ .function = encoded.function, .result = 0 }, .payload = golden[offset+size..][0..size] }, address);
            try t.expect(reply == .ok);
            if (operation == .allocate_virtual) address = reply.ok;
            offset += size * 2;
        }
        try t.expect(offset == 896 and golden.len == 896 and address == 0x600000);
        var wide_space = binding; wide_space.space.bytes = @as(u64, 1) << 48;
        // A virtual allocation has no 32-bit page-count field. Its encoder
        // must not narrow the extent as though it were a registration list.
        _ = try wire.encode(wide_space, @as(u64, 1) << 46, .allocate_virtual, 0, &request);
    }
    // Bounded bookkeeping capacity is separate from consumed wire IDs.
    var ledger = try rm_names.Ledger.init(7);
    var leases: [rm_names.max_clients]rm_names.Lease = undefined;
    for (&leases, 0..) |*lease, i| {
        lease.* = try ledger.reserve(5);
        try t.expectEqual(@as(u32, 0xc1d00000) + @as(u32, @intCast(i)), lease.client);
        try t.expectEqual(@as(u32, 0x10000000) + @as(u32, @intCast(i * 5)), try lease.object(0));
        try t.expectError(error.Bounds, lease.object(5));
    }
    const next_client = ledger.next_client;
    const child = try ledger.reserveChildren(leases[2], 4);
    try t.expect(ledger.next_client == next_client and child.parent.client == leases[2].client);
    try t.expectError(error.Retained, ledger.requireNoChildren(leases[2]));
    try t.expectError(error.Retained, ledger.retire(leases[2]));
    try t.expectError(error.Bounds, child.object(4));
    var forged_child = child;
    forged_child.object_count += 1;
    try t.expectError(error.Stale, ledger.retireChildren(forged_child));
    try ledger.retireChildren(child);
    try ledger.requireNoChildren(leases[2]);
    const child_next = try ledger.reserveChildren(leases[2], 2);
    try t.expect(child_next.slot == child.slot and child_next.first_object > child.first_object);
    try t.expectError(error.Stale, ledger.validateChildren(child));
    try ledger.retainChildren(child_next);
    try t.expectError(error.Retained, ledger.retireChildren(child_next));
    try t.expectError(error.Retained, ledger.requireNoChildren(leases[2]));
    const next_object = ledger.next_object;
    try t.expectError(error.Exhausted, ledger.reserve(5));
    try t.expect(next_client == ledger.next_client and next_object == ledger.next_object);
    try ledger.retain(leases[0]);
    try t.expectError(error.Retained, ledger.retire(leases[0]));
    try ledger.retire(leases[1]);
    const replacement = try ledger.reserve(5);
    try t.expect(replacement.slot == leases[1].slot and replacement.client > leases[1].client and replacement.first_object > leases[1].first_object);
    try t.expectError(error.Stale, ledger.validate(leases[1]));
    var stale = replacement;
    stale.epoch += 1;
    try t.expectError(error.Stale, ledger.retire(stale));
    var limits = try rm_names.Ledger.init(7);
    try t.expectError(error.Bounds, limits.reserve(0));
    limits.next_object = rm_names.object_end - 4;
    try t.expectError(error.Exhausted, limits.reserve(5));
    try t.expectEqual(@as(u32, 0), limits.next_client);
    const last = try limits.reserve(4);
    try t.expectEqual(rm_names.object_end - 1, try last.object(3));
    try t.expectError(error.Exhausted, limits.reserve(1));
    limits = try rm_names.Ledger.init(7);
    limits.next_client = rm_names.client_mask;
    try t.expectEqual(@as(u32, 0xc1d0ffff), (try limits.reserve(1)).client);
    try t.expectError(error.Exhausted, limits.reserve(1));

    var session: transport.Session = undefined;
    var boot = try startBoot(model, &session);
    try model.replyRpc(&session, .{ .function = 0x1001, .result = 0 }, &.{ 0, 0, 0, 0 });
    try boot.complete((try boot.poll()).?.ticket);
    var token = try boot.handoff(deadline);
    try t.expectError(error.Payload, rm_graph.Owner.init(&token, 1, "bad\x00name", deadline));
    try t.expect(!token.claimed and session.rm_names.next_client == 0);
    var owner = try rm_graph.Owner.init(&token, 1, "R4OS display", deadline);
    const canceled = owner.reservation;
    const unsubmitted_calls = model.count;
    token = try owner.cancelUnsubmitted(deadline);
    try t.expect(model.count == unsubmitted_calls and !token.claimed and owner.state == .finished);
    try t.expectError(error.Stale, session.rm_names.validate(canceled));
    try t.expectError(error.State, owner.cancelUnsubmitted(deadline));
    owner = try rm_graph.Owner.init(&token, 1, "R4OS display", deadline);
    const first = owner.reservation;
    try t.expect(first.client != canceled.client and first.first_object != canceled.first_object);
    try t.expectError(error.State, rm_graph.Owner.init(&token, 1, "second", deadline));
    try t.expectEqual(@as(u32, 2), session.rm_names.next_client);
    try graphCreate(model, &owner);
    var copied = owner;
    try t.expectError(error.Stale, copied.loan(deadline));
    try t.expect(session.state == .active);
    var loan = try owner.loan(deadline);
    var channel = try display_rpc.Channel.init(&loan.runtime, loan.object, deadline);
    try t.expectError(error.State, owner.poll());
    try t.expectError(error.State, owner.reclaim(&loan.runtime, deadline));
    try channel.begin(.supported, deadline);
    try t.expect((try channel.poll(deadline)) == null);
    try displayReply(model, &channel, 0, 0x80000001);
    try channel.complete((try channel.poll(deadline)).?.ticket);
    var post: [40]u8 = undefined;
    const payload = registeredPost(&post, .hotplug, true);
    put(&post, 0, first.client);
    put(&post, 4, try first.object(3));
    try model.replyRpc(&session, .{ .function = 0x1003, .result = 0 }, payload);
    _ = (try channel.poll(deadline)).?;
    var delivery = try runtime_events.Dispatch.initDisplay(&channel, try owner.eventSink());
    try delivery.step();
    try t.expectEqual(@as(u32, 0x80000001), (try owner.takeChanges(deadline)).plug);
    var returned = try channel.handoff(deadline);
    try owner.reclaim(&returned, deadline);
    model.count = 0;
    token = try graphDestroy(model, &owner);
    try t.expect(owner.state == .finished and !token.claimed and session.state == .active);
    try t.expectError(error.Stale, session.rm_names.validate(first));
    // A confirmed root rejection burns all reserved IDs, but retires the
    // bookkeeping only after the explicit empty graph cleanup transition.
    owner = try rm_graph.Owner.init(&token, 2, "rejected", deadline);
    const rejected = owner.reservation;
    try t.expect(rejected.client != first.client and rejected.first_object != first.first_object);
    try graphOperation(model, &owner, 0x51);
    try t.expect(owner.state == .rejected);
    try session.rm_names.validate(rejected);
    try owner.beginDestroy(deadline);
    try t.expect((try owner.poll()) == null and owner.state == .closed);
    token = try owner.finish(deadline);
    try t.expectError(error.Stale, session.rm_names.validate(rejected));
    owner = try rm_graph.Owner.init(&token, 3, "retained", deadline);
    try t.expect(owner.reservation.client != rejected.client and owner.reservation.first_object != rejected.first_object);
    model.count = 0;
    try graphCreate(model, &owner);
    try owner.beginDestroy(deadline);
    try t.expect((try owner.poll()) == null);
    try eventReply(model, &owner.subscriptions.?, 0x55);
    try t.expectError(error.FirmwareResult, owner.poll());
    try t.expect(owner.state == .failed and session.state == .failed and owner.base.state == .loaned);
    try t.expectError(error.Retained, session.rm_names.retire(owner.reservation));
    const calls = model.count;
    try t.expectError(error.State, owner.finish(deadline));
    try t.expectError(error.State, owner.poll());
    try t.expectEqual(calls, model.count);
}

fn receiverFixture(bytes: []u8) void {
    @memset(bytes, 0);
    @memcpy(bytes[0..8], &[_]u8{ 0, 255, 255, 255, 255, 255, 255, 0 });
    bytes[8] = 0x48;
    bytes[9] = 0xcf; // Synthetic RFO identity, not a real monitor.
    bytes[18] = 1;
    bytes[19] = 4;
    bytes[20] = 0x80;
    @memset(bytes[38..54], 1);
    for (0..4) |i| bytes[54 + i * 18 + 3] = 0x10;
    if (bytes.len > 128) {
        bytes[126] = @intCast(bytes.len / 128 - 1);
        const cta = bytes[128..256];
        @memcpy(cta[0..16], &[_]u8{ 2, 3, 16, 0x40, 0x41, 16, 0x23, 0x09, 7, 7, 0x65, 3, 12, 0, 0x10, 0 });
        for (2..bytes.len / 128) |i| bytes[i * 128] = 0x99; // Unknown extensions retained by the shared parser.
    }
    for (0..bytes.len / 128) |i| receiverChecksum(bytes[i * 128 ..][0..128]);
}
fn receiverChecksum(bytes: []u8) void {
    bytes[127] = 0;
    var sum: u8 = 0;
    for (bytes) |byte| sum +%= byte;
    bytes[127] = 0 -% sum;
}
fn receiverEdidReply(model: *Model, refresh: *receiver.Refresh, status: u32, blob: []const u8) !void {
    var bytes: [display_rpc.max_request_bytes]u8 = undefined;
    const payload = try display_rpc.encode(refresh.channel.object, refresh.channel.request.?, &bytes);
    put(&bytes, 12, status);
    put(&bytes, 32, @intCast(blob.len));
    @memcpy(bytes[40..][0..blob.len], blob);
    try model.replyRpc(refresh.channel.exchange.session, .{ .function = 76, .result = 0 }, payload);
}
fn checkReceiver(model: *Model) !void {
    const capture = try t.allocator.create(receiver.Capture);
    defer t.allocator.destroy(capture);
    const Case = enum { valid, base_only, missing, missing_extension, checksum, invalid_base, truncated, edid_rejected, verify_rejected, disconnected, not_supported, changed, hpd, late_hpd, canceled, ack, expired, release_expired };
    for (std.enums.values(Case)) |case| {
        var session: transport.Session = undefined;
        var boot = try startBoot(model, &session);
        try model.replyRpc(&session, .{ .function = 0x1001, .result = 0 }, &.{ 0, 0, 0, 0 });
        try boot.complete((try boot.poll()).?.ticket);
        var token = try boot.handoff(deadline);
        var owner = try rm_graph.Owner.init(&token, 1, "receiver", deadline);
        try graphCreate(model, &owner);
        model.count = 0;
        try t.expectError(error.Query, receiver.Refresh.init(&owner, 3, capture, deadline));
        var refresh = try receiver.Refresh.init(&owner, 0x80000000, capture, deadline);
        // An unstarted read returns the graph without querying hardware.
        try refresh.release(deadline);
        try t.expect(owner.state == .ready and model.count == 0);
        refresh = try receiver.Refresh.init(&owner, 0x80000000, capture, deadline);
        try t.expectError(error.State, refresh.borrow(deadline));
        try t.expect((try refresh.poll()) == null);
        var copied = refresh;
        try t.expectError(error.Stale, copied.poll());
        try t.expect(session.state == .active);
        try displayReply(model, &refresh.channel, 0, if (case == .not_supported) 1 else 0x80000001);
        try t.expect((try refresh.poll()) == null);
        if (case == .not_supported) {
            try t.expect(refresh.state == .drain and capture.status == .not_supported and capture.connected == null);
        } else {
            try t.expect(refresh.state == .connected);
            try t.expect((try refresh.poll()) == null);
            try displayReply(model, &refresh.channel, 0, if (case == .disconnected) 0 else 0x80000000);
            try t.expect((try refresh.poll()) == null);
            if (case == .disconnected) {
                try t.expect(refresh.state == .drain and capture.status == .disconnected and capture.connected.? == false);
            } else {
                try t.expect(refresh.state == .edid);
                try t.expect((try refresh.poll()) == null);
                try t.expectError(error.State, refresh.release(deadline));
                var blob: [2048]u8 = undefined;
                const size: usize = switch (case) {
                    .base_only, .missing_extension => 128,
                    .missing => 0,
                    .truncated => 2048,
                    else => 256,
                };
                receiverFixture(&blob);
                if (size != 0) receiverFixture(blob[0..size]);
                if (case == .missing_extension or case == .truncated) {
                    blob[126] += 1;
                    receiverChecksum(blob[0..128]);
                }
                if (case == .checksum) blob[255] ^= 1;
                if (case == .invalid_base) blob[0] = 1;
                if (case == .hpd) {
                    var post: [40]u8 = undefined;
                    const bytes = registeredPost(&post, .hotplug, true);
                    put(&post, 0, owner.reservation.client);
                    put(&post, 4, try owner.reservation.object(3));
                    try model.replyRpc(&session, .{ .function = 0x1003, .result = 0 }, bytes);
                    const notice = (try refresh.poll()).?;
                    try t.expect(notice.value == .notification and session.pending != null);
                    try t.expectError(error.Pending, refresh.poll());
                    var dispatch = try runtime_events.Dispatch.initDisplay(&refresh.channel, try owner.eventSink());
                    try dispatch.step();
                    try t.expect(refresh.channel.exchange.phase == .waiting);
                }
                if (case == .canceled) {
                    try refresh.invalidate();
                    try t.expect((try refresh.poll()) == null and refresh.channel.exchange.phase == .waiting);
                }
                try receiverEdidReply(model, &refresh, if (case == .edid_rejected) 0x55 else 0, blob[0..size]);
                if (case == .ack) {
                    model.fault = model.count + 4;
                    model.after = true;
                }
                if (case == .expired) model.now = deadline;
                if (case == .ack or case == .expired) {
                    try t.expectError(if (case == .ack) error.Io else error.Deadline, refresh.poll());
                    try t.expect(refresh.state == .failed and session.state == .failed and owner.state == .loaned);
                    if (case == .ack) try t.expect(session.pending != null);
                    const calls = model.count;
                    try t.expectError(error.State, refresh.borrow(deadline + 100));
                    try t.expectError(error.State, refresh.poll());
                    try t.expectError(error.State, refresh.release(deadline + 100));
                    try t.expectEqual(calls, model.count);
                    continue;
                }
                try t.expect((try refresh.poll()) == null);
                if (case == .hpd or case == .canceled) {
                    try t.expect(refresh.state == .obsolete and refresh.channel.exchange.phase == .idle and session.pending == null);
                    try t.expectError(error.State, refresh.borrow(deadline));
                    try refresh.release(deadline);
                    try t.expect(owner.state == .ready);
                    continue;
                }
                if (refresh.state == .resource) {
                    try t.expect((try refresh.poll()) == null);
                    var bytes: [80]u8 = undefined;
                    const payload = try display_rpc.encode(refresh.channel.object, refresh.channel.request.?, &bytes);
                    put(&bytes, 36, 2); put(&bytes, 40, 1);
                    try model.replyRpc(&session, .{ .function = 76, .result = 0 }, payload);
                    try t.expect((try refresh.poll()) == null);
                }
                if (refresh.state == .buses) {
                    try t.expect((try refresh.poll()) == null);
                    var bytes: [40]u8 = undefined;
                    const payload = try display_rpc.encode(refresh.channel.object, refresh.channel.request.?, &bytes);
                    put(&bytes, 36, 37); // An unknown RM ID cannot be truncated to an I2C index.
                    try model.replyRpc(&session, .{ .function = 76, .result = 0 }, payload);
                    try t.expect((try refresh.poll()) == null);
                }
                try t.expect(refresh.state == .verify);
                try t.expect((try refresh.poll()) == null);
                try displayReply(model, &refresh.channel, if (case == .verify_rejected) 0x56 else 0, if (case == .changed) 0 else 0x80000000);
                try t.expect((try refresh.poll()) == null);
                if (case == .changed) {
                    try t.expect(refresh.state == .obsolete);
                    try t.expectError(error.State, refresh.borrow(deadline));
                    try refresh.release(deadline);
                    continue;
                }
            }
        }
        try t.expectError(error.State, refresh.borrow(deadline)); // Still no completed capture before final drain.
        if (case == .late_hpd) {
            var post: [40]u8 = undefined;
            const bytes = registeredPost(&post, .hotplug, false);
            put(&post, 0, owner.reservation.client);
            put(&post, 4, try owner.reservation.object(3));
            try model.replyRpc(&session, .{ .function = 0x1003, .result = 0 }, bytes);
            _ = (try refresh.poll()).?;
            var dispatch = try runtime_events.Dispatch.initDisplay(&refresh.channel, try owner.eventSink());
            try dispatch.step();
            try t.expect((try refresh.poll()) == null and refresh.state == .obsolete);
            try refresh.release(deadline);
            continue;
        }
        try t.expect((try refresh.poll()) == null and refresh.state == .complete);
        const result = try refresh.borrow(deadline);
        const expected: receiver.Status = switch (case) {
            .valid, .base_only, .release_expired => .valid_edid,
            .missing => .edid_missing,
            .missing_extension, .checksum, .truncated => .incomplete_edid,
            .invalid_base => .invalid_edid,
            .edid_rejected => .edid_rejected,
            .verify_rejected => .query_rejected,
            .disconnected => .disconnected,
            .not_supported => .not_supported,
            else => unreachable,
        };
        try t.expectEqual(expected, result.status);
        try t.expect(result.receipt_serial != 0 and result.epoch == session.epoch and result.client == owner.reservation.client);
        if (case == .valid) try t.expect(result.report.hdmi and result.report.basic_audio and result.report.audio_count == 1 and result.report.mode_count == 1 and result.report.complete());
        if (case == .base_only or case == .missing or case == .checksum or case == .invalid_base or case == .verify_rejected) try t.expect(!result.report.hdmi and !result.report.basic_audio and result.report.audio_count == 0);
        if (case == .missing_extension or case == .truncated) try t.expect(result.report.warnings & receiver.edid.Warning.missing != 0);
        if (case == .edid_rejected) try t.expectEqual(@as(u32, 0x55), result.control_status.?);
        if (case == .verify_rejected) try t.expect(result.connected == null and result.edid_bytes == 0 and result.report.mode_count == 0);
        if (case == .valid) {
            @memset(&model.rx, 0xcc);
            try t.expectEqual(@as(u8, 0), result.bytes[0]);
            // Completed capture access/release has a fresh observation budget;
            // it must not reuse the expired deadline of an already-finished RPC.
            model.now = deadline + 1;
            _ = try refresh.borrow(deadline + 100);
        }
        if (case == .release_expired) {
            model.now = deadline;
            try t.expectError(error.Deadline, refresh.release(deadline));
            try t.expect(refresh.state == .failed and refresh.failure.? == error.Deadline and owner.state == .loaned and session.state == .failed);
            const calls = model.count;
            try t.expectError(error.State, refresh.release(deadline + 100));
            try t.expectError(error.State, refresh.borrow(deadline + 100));
            try t.expectEqual(calls, model.count);
            continue;
        }
        try refresh.release(deadline + 100);
        try t.expect(owner.state == .ready and session.state == .active);
        const calls = model.count;
        try t.expectError(error.State, refresh.borrow(deadline + 100));
        try t.expectError(error.State, refresh.poll());
        try t.expectEqual(calls, model.count);
    }
}

fn topologyReply(model: *Model, probe: *topology.Discovery, status: u32, mask: u32, head_count: u32, head_changed: bool) !void {
    const query = probe.channel.request.?;
    // A replying firmware peer has consumed this command. Advance its read
    // cursor so discovery of all 32 IDs exercises real ring wraparound,
    // instead of injecting responses to requests blocked by a full ring.
    try t.expect(probe.channel.exchange.phase == .waiting);
    model.peerPut(probe.channel.exchange.session.link.?.command_read, get(&model.peer[0], 16));
    if (query == .supported) return displayReply(model, &probe.channel, status, mask);
    var bytes: [display_rpc.max_request_bytes]u8 = undefined;
    const payload = try display_rpc.encode(probe.channel.object, query, &bytes);
    put(&bytes, 12, status);
    switch (query) {
        .heads => put(&bytes, 32, head_count),
        .active => |head| put(&bytes, 36, if (head_changed) 0 else if (head == 0) mask & 1 else if (head == head_count - 1) mask & 0x80000000 else 0),
        .connectors => {
            put(&bytes, 32, 1);
            put(&bytes, 36, 0x80000005);
            put(&bytes, 40, 2);
            put(&bytes, 44, 17); // RM physical ID differs from DCB connector index.
            put(&bytes, 48, 0x61);
            put(&bytes, 52, 4);
            put(&bytes, 56, 19);
            put(&bytes, 60, 0xffffffff); // Unknown type preserved, not HDMI by default.
            put(&bytes, 64, 2);
            put(&bytes, 92, 7);
        },
        .resource => |id| {
            put(&bytes, 32, 0xffffffff); // RM may have no assigned SOR yet.
            put(&bytes, 36, 2);
            put(&bytes, 40, 1);
            put(&bytes, 56, 4);
            put(&bytes, 60, 27); // DCB slot differs from log2(display ID).
            std.mem.writeInt(u64, bytes[64..72], 0x123456789abcdef0, .little);
            bytes[72] = 1;
            bytes[73] = if (id == 0x80000000) 1 else 0;
            @memset(bytes[74..80], 0xcc); // Arbitrary C padding.
        },
        .buses => {
            put(&bytes, 32, 0); // NONE, not physical bus zero.
            put(&bytes, 36, 37); // An RM ID, not an I2C controller index.
        },
        else => unreachable,
    }
    try model.replyRpc(probe.channel.exchange.session, .{ .function = 76, .result = 0 }, payload);
}
fn checkTopology(model: *Model) !void {
    try checkPortMapping();
    // Validate semantic fields beyond the shared framing/length checks. All
    // four connector records survive; flags=NO keeps DDC partners but cannot
    // establish a physical socket. Unknown scalar values are retained.
    var raw: [96]u8 = undefined;
    var encoded = try display_rpc.encode(display_object, .{ .connectors = 1 }, &raw);
    put(&raw, 36, 0x80000001);
    put(&raw, 40, 4);
    put(&raw, 80, 0xfedcba98);
    const shape = try message.encode(profile, 0, .{ .function = 76, .result = 0 }, encoded, &model.frame);
    var record = try message.decode(profile, model.frame[0..shape.storage_bytes], 0);
    record.payload = encoded;
    const connectors = (try display_rpc.decode(display_object, .{ .connectors = 1 }, record)).connectors;
    try t.expect(!connectors.present() and connectors.count == 4 and connectors.ddc_partners == 0x80000001 and connectors.data[3].index == 0xfedcba98);
    put(&raw, 40, 5);
    try t.expectError(error.Payload, display_rpc.decode(display_object, .{ .connectors = 1 }, record));
    put(&raw, 12, 0x1234);
    try t.expectEqual(@as(u32, 0x1234), (try display_rpc.decode(display_object, .{ .connectors = 1 }, record)).control_error);
    encoded = try display_rpc.encode(display_object, .{ .resource = 1 }, &raw);
    record.payload = encoded;
    raw[73] = 2;
    try t.expectError(error.Payload, display_rpc.decode(display_object, .{ .resource = 1 }, record));
    raw[73] = 0;
    raw[72] = 2;
    try t.expectError(error.Payload, display_rpc.decode(display_object, .{ .resource = 1 }, record));
    for ([_]display_rpc.Query{ .{ .connectors = 0 }, .{ .resource = 3 }, .{ .buses = 0xffffffff } }) |query| try t.expectError(error.Query, display_rpc.encode(display_object, query, &raw));
    try t.expectError(error.Query, display_rpc.encode(display_object, .{ .active = 32 }, &raw));
    encoded = try display_rpc.encode(display_object, .heads, &raw);
    record.payload = encoded;
    put(&raw, 32, 33);
    try t.expectError(error.Payload, display_rpc.decode(display_object, .heads, record));
    encoded = try display_rpc.encode(display_object, .{ .active = 0 }, &raw);
    record.payload = encoded;
    put(&raw, 36, 3);
    try t.expectError(error.Payload, display_rpc.decode(display_object, .{ .active = 0 }, record));
    put(&raw, 36, 0);
    try t.expect((try display_rpc.decode(display_object, .{ .active = 0 }, record)).active == 0);

    const catalog = try t.allocator.create(topology.Catalog);
    defer t.allocator.destroy(catalog);
    const Case = enum { valid, empty, full, changed, partial, verify_error, hpd, canceled, ack, expiry, release_expired, heads_rejected, active_rejected, head_changed, head_count_changed };
    for (std.enums.values(Case)) |case| {
        var session: transport.Session = undefined;
        var boot = try startBoot(model, &session);
        try model.replyRpc(&session, .{ .function = 0x1001, .result = 0 }, &.{ 0, 0, 0, 0 });
        try boot.complete((try boot.poll()).?.ticket);
        var token = try boot.handoff(deadline);
        var owner = try rm_graph.Owner.init(&token, 1, "topology", deadline);
        try graphCreate(model, &owner);
        model.count = 0;
        var probe = try topology.Discovery.init(&owner, catalog, deadline);
        try t.expectError(error.Query, probe.channel.begin(.{ .connectors = 1 }, deadline));
        try t.expectError(error.Query, probe.channel.begin(.heads, deadline));
        try t.expectError(error.Query, probe.channel.begin(.{ .active = 0 }, deadline));
        try probe.release(deadline);
        try t.expect(owner.state == .ready and model.count == 0);
        probe = try topology.Discovery.init(&owner, catalog, deadline);
        const mask: u32 = switch (case) {
            .empty => 0,
            .full => 0xffffffff,
            else => 0x80000005,
        };
        var steps: usize = 0;
        while (probe.state != .complete and probe.state != .obsolete and probe.state != .failed) : (steps += 1) {
            try t.expect(steps < 180);
            model.count = 0;
            try t.expectError(error.State, probe.borrow(deadline));
            if (case == .canceled and probe.state == .resource) {
                try probe.invalidate();
                try t.expect((try probe.poll()) == null and probe.state == .obsolete and model.count == 0);
                break;
            }
            try t.expect((try probe.poll()) == null);
            if (probe.state == .complete) break; // Final idle drain.
            var copy = probe;
            try t.expectError(error.Stale, copy.poll());
            try t.expect(session.state == .active);
            try t.expectError(error.State, probe.release(deadline));
            if (case == .hpd and probe.state == .resource) {
                var post: [40]u8 = undefined;
                const bytes = registeredPost(&post, .hotplug, true);
                put(&post, 0, owner.reservation.client);
                put(&post, 4, try owner.reservation.object(3));
                try model.replyRpc(&session, .{ .function = 0x1003, .result = 0 }, bytes);
                _ = (try probe.poll()).?;
                try t.expectError(error.Pending, probe.poll());
                var dispatch = try runtime_events.Dispatch.initDisplay(&probe.channel, try owner.eventSink());
                try dispatch.step();
                try t.expect(probe.channel.exchange.phase == .waiting);
            }
            const status: u32 = if ((case == .partial and probe.state == .connectors) or (case == .verify_error and probe.state == .verify) or
                (case == .heads_rejected and (probe.state == .heads or probe.state == .verify_heads)) or
                (case == .active_rejected and (probe.state == .active or probe.state == .verify_active) and probe.head_cursor == 1)) 0x55 else 0;
            const count: u32 = if (case == .empty) 0 else if (case == .full) 32 else if (case == .head_count_changed and probe.state == .verify_heads) 3 else 4;
            try topologyReply(model, &probe, status, if (case == .changed and probe.state == .verify) 1 else mask, count,
                case == .head_changed and probe.state == .verify_active and probe.head_cursor == 0);
            if (case == .ack and probe.state == .resource) {
                model.fault = model.count + 4;
                model.after = true;
            }
            if (case == .expiry and probe.state == .resource) model.now = deadline;
            if ((case == .ack or case == .expiry) and probe.state == .resource) {
                try t.expectError(if (case == .ack) error.Io else error.Deadline, probe.poll());
                try t.expect(probe.state == .failed and session.state == .failed and owner.state == .loaned);
                const calls = model.count;
                try t.expectError(error.State, probe.poll());
                try t.expectError(error.State, probe.release(deadline + 100));
                try t.expectEqual(calls, model.count);
                break;
            }
            try t.expect((try probe.poll()) == null);
        }
        if (probe.state == .failed) continue;
        if (case == .hpd or case == .changed or case == .canceled or case == .head_changed or case == .head_count_changed) {
            try t.expect(probe.state == .obsolete and session.pending == null);
            try t.expectError(error.State, probe.borrow(deadline));
        } else {
            const value = try probe.borrow(deadline);
            try t.expect(value.epoch == session.epoch and value.client == owner.reservation.client and value.receipt_serial != 0);
            try t.expectEqual(@as(usize, if (case == .verify_error) 0 else @popCount(mask)), value.count);
            if (case == .verify_error) try t.expect(value.rejected.?.control.? == 0x55 and value.supported == null);
            if (case == .heads_rejected) try t.expect(value.head_count == null and value.heads_rejected.?.control.? == 0x55 and value.activeHeads(1) == null)
            else if (case == .active_rejected) try t.expect(value.heads[1].display_id == null and value.heads[1].rejected.?.control.? == 0x55 and value.activeHeads(1) == null)
            else if (case == .empty) try t.expect(value.head_count.? == 0 and value.activeHeads(1).? == 0)
            else if (case != .verify_error) {
                try t.expect(value.activeHeads(1).? == 1 and value.activeHeads(4).? == 0);
                try t.expect(value.activeHeads(0x80000000).? == @as(u32, if (case == .full) 0x80000000 else 8));
            }
            if (case == .valid or case == .partial) {
                const first = &value.routes[0];
                const dynamic = &value.routes[2];
                try t.expect(first.id == 1 and dynamic.id == 0x80000000 and first.resource.?.index == 0xffffffff and first.buses.?.communication == 0 and first.buses.?.ddc == 37);
                if (case == .partial) try t.expect(first.connectors == null and first.rejections[0].?.control.? == 0x55) else try t.expect(first.connectors.?.present() and first.connectors.?.count == 2 and first.connectors.?.data[0].index == dynamic.connectors.?.data[0].index);
                var rom: @import("vbios.zig").Result = .{};
                rom.port_count = 1;
                rom.ports[0] = .{ .index = 27, .kind = 2, .connector = 3, .heads = 5, .output_mask = 6, .i2c = 1, .aux = 2 };
                try t.expectEqual(@as(u8, 3), topology.relate(first, &rom).static.connector);
                try t.expectEqual(@as(u32, 4), topology.relate(dynamic, &rom).dynamic);
                rom.port_count = 0;
                try t.expect(topology.relate(first, &rom) == .missing);
                rom.port_count = 2;
                rom.ports[1] = rom.ports[0];
                try t.expect(topology.relate(first, &rom) == .ambiguous);
            }
            if (case == .release_expired) {
                model.now = deadline;
                try t.expectError(error.Deadline, probe.release(deadline));
                try t.expect(probe.failure.? == error.Deadline and probe.state == .failed and session.state == .failed and owner.state == .loaned);
                continue;
            }
        }
        model.now = deadline + 1;
        if (probe.state == .complete) _ = try probe.borrow(deadline + 100);
        try probe.release(deadline + 100);
        try t.expect(owner.state == .ready and session.state == .active);
    }
}

fn checkPortMapping() !void {
    const rom = @import("tests.zig").portFixture();
    var board = try @import("vbios.zig").parse(&rom, 0x2504);
    var catalog: topology.Catalog = .{ .count = 1, .head_count = 1 };
    catalog.heads[0].display_id = 0x100;
    catalog.routes[0] = .{ .id = 0x100,
        .resource = .{ .index = 0, .kind = 2, .protocol = 1, .dither_type = 0, .dither_algo = 0,
            .location = 0, .root_port_id = 1, .dcb_index = 27, .vbios_address = 0, .lit_by_vbios = true, .dynamic = false },
        .buses = .{ .communication = 0, .ddc = 37 },
        .connectors = .{ .flags = 1, .ddc_partners = 0x100, .platform = 0, .count = 2,
            .data = .{ .{ .index = 17, .kind = 0x61, .location = 4 }, .{ .index = 19, .kind = 0xffffffff, .location = 2 }, .{}, .{} } } };
    const route = &catalog.routes[0];
    topology.correlate(&catalog, &board);
    const saved = route.*;
    try t.expect(route.wiring.relation.static.index == 27 and route.wiring.active_heads.? == 1);
    try t.expect(route.wiring.heads == .matched and route.wiring.encoder == .observed and route.wiring.protocol == .matched);
    try t.expect(route.wiring.physical_status == .matched and route.wiring.physical.?.index == 17);
    try t.expect(route.wiring.connector.?.index == 0 and route.wiring.communication.?.index == 0);
    try t.expect(route.wiring.communication.?.i2c.? == 3 and route.buses.?.ddc == 37);
    try t.expect(route.wiring.hpd[0].?.line.? == 3 and route.wiring.hpd[1] == null);
    try t.expect(route.wiring.external_dongle[0].?.line.? == 1 and route.wiring.external_dongle[1] == null);
    route.resource.?.index = 0xffffffff;
    topology.correlate(&catalog, &board);
    try t.expect(route.wiring.encoder == .unassigned);
    board.ports[0].assignment = .encoder; // DCB4.0, not the repurposed 4.1 pad mask.
    for ([_]u32{ 1, 4, 0xfffffffe }) |index| {
        route.resource.?.index = index;
        topology.correlate(&catalog, &board);
        try t.expect(route.wiring.encoder == .mismatch);
    }
    board.ports[0].assignment = .pad_macro;
    board.ports[0].virtual = true;
    topology.correlate(&catalog, &board);
    try t.expect(route.wiring.relation == .virtual and route.wiring.physical == null);
    board.ports[0].virtual = false;
    route.* = saved; route.resource.?.protocol = 8;
    topology.correlate(&catalog, &board);
    try t.expect(route.wiring.protocol == .mismatch);
    route.resource.?.protocol = 0xffffffff;
    topology.correlate(&catalog, &board);
    try t.expect(route.wiring.protocol == .unavailable);
    route.* = saved; route.resource.?.dynamic = true;
    topology.correlate(&catalog, &board);
    try t.expect(route.wiring.relation.dynamic == 1 and route.wiring.physical == null and route.wiring.hpd[0] == null);
    route.* = saved; route.resource.?.dcb_index = 8;
    topology.correlate(&catalog, &board);
    try t.expect(route.wiring.relation == .missing and route.wiring.physical == null);
    route.* = saved; route.connectors.?.data[1] = route.connectors.?.data[0];
    topology.correlate(&catalog, &board);
    try t.expect(route.wiring.physical_status == .ambiguous and route.wiring.physical == null);
    route.* = saved; route.connectors.?.data[0].location = 5;
    topology.correlate(&catalog, &board);
    try t.expect(route.wiring.physical_status == .mismatch and route.wiring.physical == null);
    route.* = saved; catalog.heads[0].display_id = null;
    topology.correlate(&catalog, &board);
    try t.expect(route.wiring.heads == .unavailable);
    catalog.heads[0].display_id = 0;
    topology.correlate(&catalog, &board);
    try t.expect(route.wiring.heads == .unassigned);
    catalog.heads[0].display_id = 0x100; board.ports[0].heads = 2;
    topology.correlate(&catalog, &board);
    try t.expect(route.wiring.heads == .mismatch);
    board.ports[0].heads = 1;
    // Same physical DCB socket with different RM IDs: discard the derived
    // identity for every alias, including a third matching earlier record.
    catalog.count = 3;
    for (catalog.routes[0..3], 0..) |*item, i| {
        item.* = saved; item.id = @as(u32, 1) << @as(u5, @intCast(i));
        item.connectors.?.data[0].index = if (i == 1) 18 else 17;
    }
    topology.correlate(&catalog, &board);
    for (catalog.routes[0..3]) |*item| try t.expect(item.wiring.physical_status == .ambiguous and item.wiring.physical == null);
    topology.correlate(&catalog, null);
    for (catalog.routes[0..3]) |*item| try t.expect(item.wiring.relation == .unavailable and item.wiring.physical == null);
}

fn checkDdcWire() !void {
    const wire = display_rpc.ddc_wire;
    // Original 570.144 SerializeDown/DeserializeDown/SerializeUp/DeserializeUp,
    // compiled unchanged with NVRM. This fixture is independent of our codec.
    const golden = @embedFile("fixtures/ddc-finn-570.144.bin");
    const blocks = [_]u8{ 0, 1, 2, 15, 16, 31 };
    var encoded: [201]u8 = @splat(0xa5);
    var output: [128]u8 = @splat(0xa5);
    for (blocks, 0..) |block, i| {
        const request = wire.Request{ .port = 2, .block = block };
        const expected = golden[i * 400 ..][0..400];
        try t.expectEqualSlices(u8, expected[0..200], try wire.encode(request, null, &encoded));
        try t.expect(encoded[200] == 0xa5);
        try wire.decode(request, expected[200..400], &output);
        for (output, 0..) |value, index| try t.expectEqual(@as(u8, @truncate(index * 37 + block)), value);
        try t.expectEqualSlices(u8, expected[200..400], try wire.encode(request, &output, &encoded));
        for (0..200) |size| try t.expectError(error.Bounds, wire.encode(request, null, encoded[0..size]));
        @memset(&output, 0xa5);
        for (0..200) |size| try t.expectError(error.Payload, wire.decode(request, expected[200..][0..size], &output));
        try t.expectError(error.Payload, wire.decode(request, &encoded, &output));
        // Every field-presence bit (including the last data element), fixed
        // echo/header and padding is checked before mutating the output.
        const data_start = 402;
        for ([_]usize{ 0, 64, 128, 192, 256, 265, 298, 315, 348, 349, 350, 359, 368, 401, data_start, data_start + 127 * 9, 1599 }) |bit| {
            @memcpy(encoded[0..200], expected[200..400]);
            encoded[bit / 8] ^= @as(u8, 1) << @as(u3, @intCast(bit % 8));
            try t.expectError(error.Payload, wire.decode(request, encoded[0..200], &output));
            try t.expect(std.mem.allEqual(u8, &output, 0xa5));
        }
    }
    for ([_]wire.Request{ .{ .port = 16, .block = 0 }, .{ .port = 255, .block = 0 }, .{ .port = 0, .block = 32 } }) |request|
        try t.expectError(error.Query, wire.encode(request, null, &encoded));
}

fn checkAuxWire() !void {
    const wire = display_rpc.aux_wire;
    const golden = @embedFile("fixtures/aux-570.144.bin");
    const operations = [_]wire.Operation{ .caps, .{ .segment = 15 }, .{ .offset = 128 }, .segment_status, .offset_status,
        .{ .read = .{ .count = 16, .last = false } }, .{ .read = .{ .count = 1, .last = true } }, .stop };
    var buffer: [49]u8 = @splat(0xa5);
    for (operations, 0..) |operation, i| {
        const request = wire.Request{ .display_id = 0x80000000, .operation = operation };
        const pair = golden[i * 96 ..][0..96];
        try t.expectEqualSlices(u8, pair[0..48], try wire.encode(request, &buffer));
        try t.expect(buffer[48] == 0xa5);
        const reply = try wire.decode(request, 0, pair[48..96]);
        try t.expect(reply.kind == .ack and reply.count == wire.length(operation));
        if (operation == .read or operation == .caps) for (reply.data[0..reply.count], 0..) |value, j| try t.expectEqual(@as(u8, @truncate(j * 23 + i)), value);
        for (0..48) |size| {
            try t.expectError(error.Bounds, wire.encode(request, buffer[0..size]));
            try t.expectError(error.Payload, wire.decode(request, 0, pair[48..][0..size]));
        }
        @memcpy(buffer[0..48], pair[48..96]);
        put(&buffer, 36, wire.length(operation) + 1);
        try t.expectError(error.Payload, wire.decode(request, 0, buffer[0..48]));
        put(&buffer, 40, 7);
        try t.expectError(error.Payload, wire.decode(request, 0, buffer[0..48]));
        put(&buffer, 44, 0xffffffff);
        const error_reply = try wire.decode(request, 0x66, buffer[0..48]);
        try t.expect(error_reply.status == 0x66 and error_reply.retry_ms == 0xffffffff and error_reply.count == 0);
        try t.expect((try wire.decode(request, 0x1f, buffer[0..48])).retry_ms == 0);
    }
    for ([_]wire.Operation{ .{ .segment = 16 }, .{ .read = .{ .count = 0, .last = false } }, .{ .read = .{ .count = 17, .last = true } } }) |operation|
        try t.expectError(error.Query, wire.encode(.{ .display_id = 1, .operation = operation }, &buffer));
}

fn checkAuxReceiver(model: *Model) !void {
    const capture = try t.allocator.create(receiver.Capture);
    defer t.allocator.destroy(capture);
    const end = 20 * std.time.ns_per_ms;
    const Case = enum { full, short_final, defer_reply, defer_exhausted, rm_retry, prefix_nack, zero_read,
        hpd, prepared_hpd, stop_failure, stop_rpc, stop_ack, ack, expired, changed_base, caps_rejected, dynamic, dvi };
    for (std.enums.values(Case)) |case| {
        var session: transport.Session = undefined;
        var boot = try startBoot(model, &session);
        try model.replyRpc(&session, .{ .function = 0x1001, .result = 0 }, &.{ 0, 0, 0, 0 });
        try boot.complete((try boot.poll()).?.ticket);
        var token = try boot.handoff(deadline);
        var parent = try rm_graph.Owner.init(&token, 1, "AUX", deadline);
        try graphCreate(model, &parent);
        var refresh = try receiver.Refresh.init(&parent, 1, capture, end);
        var blob: [4096]u8 = undefined;
        receiverFixture(&blob);
        if (case == .dvi) receiverFixture(blob[0..128]);
        var segment: u8 = 0;
        var offset: u8 = 0;
        var aux_requests: usize = 0;
        var stops: usize = 0;
        var defers: usize = 0;
        var changed = false;
        var steps: usize = 0;
        errdefer |err| std.debug.print("AUX case={s} error={s} state={s} block={d} cursor={?} bytes={d} requests={d} stops={d}\n",
            .{@tagName(case), @errorName(err), @tagName(refresh.state), refresh.block, if (refresh.aux) |r| r.cursor else null, capture.edid_bytes, aux_requests, stops});
        while (refresh.state != .complete and refresh.state != .obsolete and steps < 1000) : (steps += 1) {
            model.count = 0;
            if (refresh.waiting()) {
                const sent = session.tx_sequence;
                try t.expect((try refresh.poll()) == null and sent == session.tx_sequence);
                model.now = if (case == .expired) end else @max(refresh.retry_at_ns, if (refresh.aux) |r| r.retry_at_ns else 0);
            }
            if (case == .expired and model.now == end) {
                try t.expectError(error.Deadline, refresh.poll());
                break;
            }
            if (case == .prepared_hpd and refresh.state == .aux_read and refresh.aux.?.state == .offset and !changed) {
                var post: [40]u8 = undefined;
                const notice = registeredPost(&post, .hotplug, true);
                put(&post, 0, parent.reservation.client); put(&post, 4, try parent.reservation.object(3));
                try model.replyRpc(&session, .{ .function = 0x1003, .result = 0 }, notice);
                const sent = session.tx_sequence;
                _ = (try refresh.poll()).?;
                try t.expect(refresh.channel.exchange.phase == .prepared and session.tx_sequence == sent);
                var delivery = try runtime_events.Dispatch.initDisplay(&refresh.channel, try parent.eventSink());
                try delivery.step();
                changed = true;
            }
            try t.expect((try refresh.poll()) == null);
            if (refresh.channel.exchange.phase != .waiting) continue;
            const query = refresh.channel.request.?;
            model.peerPut(session.link.?.command_read, get(&model.peer[0], 16));
            var buffer: [display_rpc.max_request_bytes]u8 = undefined;
            const payload = try display_rpc.encode(refresh.channel.object, query, &buffer);
            switch (query) {
                .supported => { put(&buffer, 28, 1); put(&buffer, 32, 1); },
                .connected => put(&buffer, 32, 1),
                .edid => put(&buffer, 32, 0), // Missing RAW data triggers the independent AUX path.
                .resource => { put(&buffer, 36, 2); put(&buffer, 40, 8); buffer[73] = @intFromBool(case == .dynamic); },
                .aux => |request| {
                    aux_requests += 1;
                    try t.expect(get(&buffer, 4) == parent.base.plan.handles.display and get(&buffer, 20) == 1);
                    const operation = request.operation;
                    var count: u32 = display_rpc.aux_wire.length(operation);
                    if (operation == .caps) {
                        buffer[44] = 0x14;
                        if (case == .caps_rejected) put(&buffer, 12, 0x1f);
                    } else if (operation == .segment) {
                        segment = operation.segment;
                    } else if (operation == .offset) {
                        offset = operation.offset;
                    } else if (operation == .read) {
                        const position = @as(usize, segment) * 256 + offset;
                        if (case == .short_final and operation.read.last and !changed) { count = 7; changed = true; }
                        if (case == .zero_read and operation.read.last) count = 0;
                        @memcpy(buffer[44..][0..count], blob[position..][0..count]);
                        if (case == .changed_base and refresh.aux_verifying and offset == 0) buffer[53] ^= 1;
                        offset +%= @intCast(count);
                        if (operation.read.last) segment = 0;
                        if ((case == .prefix_nack and refresh.block == 2 and !refresh.aux_verifying) or
                            case == .stop_failure or case == .stop_rpc or case == .stop_ack) put(&buffer, 64, 4);
                        if (case == .hpd and !changed) {
                            var post: [40]u8 = undefined;
                            const notice = registeredPost(&post, .hotplug, true);
                            put(&post, 0, parent.reservation.client); put(&post, 4, try parent.reservation.object(3));
                            try model.replyRpc(&session, .{ .function = 0x1003, .result = 0 }, notice);
                            _ = (try refresh.poll()).?;
                            var delivery = try runtime_events.Dispatch.initDisplay(&refresh.channel, try parent.eventSink());
                            try delivery.step();
                            changed = true;
                        }
                    } else if (operation == .stop) {
                        stops += 1;
                        segment = 0;
                        if (case == .stop_failure) put(&buffer, 12, 0x1f);
                    }
                    if ((case == .defer_reply or case == .defer_exhausted) and
                        (operation == .offset or operation == .offset_status) and (case == .defer_exhausted or defers < 7)) {
                        put(&buffer, 64, 8); defers += 1;
                    }
                    if ((case == .rm_retry and defers < 2) or case == .expired) {
                        if (operation == .offset) { put(&buffer, 12, 3); put(&buffer, 68, if (case == .expired) 1000 else 2); defers += 1; }
                    }
                    put(&buffer, 60, count);
                },
                else => return error.UnexpectedAux,
            }
            const stop = query == .aux and query.aux.operation == .stop;
            try model.replyRpc(&session, .{ .function = 76, .result = if (case == .stop_rpc and stop) 0x66 else 0 }, payload);
            if ((case == .ack and query == .aux and query.aux.operation == .read) or (case == .stop_ack and stop)) { model.fault = model.count + 4; model.after = true; }
            if ((case == .ack and query == .aux and query.aux.operation == .read) or
                ((case == .stop_failure or case == .stop_rpc or case == .stop_ack) and stop)) {
                try t.expectError(if (case == .ack or case == .stop_ack) error.Io else error.FirmwareResult, refresh.poll());
                break;
            }
            try t.expect((try refresh.poll()) == null);
        }
        try t.expect(steps < 1000);
        if (case == .ack or case == .expired or case == .stop_failure or case == .stop_rpc or case == .stop_ack) {
            try t.expect(session.state == .failed and refresh.state == .failed and parent.state == .loaned);
            try t.expectError(error.State, refresh.release(end + 1));
            continue;
        }
        try t.expect(refresh.channel.aux_open == null);
        if (case == .hpd or case == .prepared_hpd or case == .changed_base) {
            try t.expect(refresh.state == .obsolete);
            if (case == .hpd or case == .prepared_hpd) try t.expect(stops == 1);
        } else {
            const result = try refresh.borrow(end);
            const expected: receiver.Status = switch (case) {
                .caps_rejected, .dynamic => .edid_missing,
                .prefix_nack => .incomplete_edid,
                .defer_exhausted, .zero_read => .edid_rejected,
                else => .valid_edid,
            };
            try t.expectEqual(expected, result.status);
            if (expected == .valid_edid) {
                const size: usize = if (case == .dvi) 128 else 4096;
                try t.expect(result.source == .aux and result.edid_bytes == size);
                try t.expectEqualSlices(u8, blob[0..size], result.bytes[0..size]);
            }
            if (case == .dvi) try t.expect(result.report.audio_count == 0 and !result.report.hdmi);
            if (case == .defer_reply or case == .defer_exhausted) try t.expect(result.aux_retries == 7);
            if (case == .rm_retry) try t.expect(result.aux_retries == 2 and model.now >= 4 * std.time.ns_per_ms);
            if (case == .prefix_nack) try t.expect(stops == 1 and result.edid_bytes == 256);
            if (case == .dynamic) try t.expect(aux_requests == 0);
        }
        try refresh.release(end);
        try t.expect(parent.state == .ready and session.state == .active);
    }
}

fn checkI2cGraph(model: *Model) !void {
    const Case = enum { rejected, alloc_ack, alloc_rpc, free_reject, free_ack };
    for (std.enums.values(Case)) |case| {
        var session: transport.Session = undefined;
        var boot = try startBoot(model, &session);
        try model.replyRpc(&session, .{ .function = 0x1001, .result = 0 }, &.{ 0, 0, 0, 0 });
        try boot.complete((try boot.poll()).?.ticket);
        var token = try boot.handoff(deadline);
        var owner = try rm_graph.Owner.init(&token, 1, "I2C child", deadline);
        if (case == .free_reject or case == .free_ack) {
            try graphCreate(model, &owner);
            try owner.beginDestroy(deadline);
            for (0..8) |_| {
                model.count = 0;
                if (owner.state == .i2c_destroying) break;
                try graphOperation(model, &owner, 0);
            }
            try t.expect(owner.state == .i2c_destroying and owner.i2c.?.live and owner.base.state == .loaned);
        } else {
            for (0..4) |_| try graphOperation(model, &owner, 0);
            try t.expect((try owner.poll()) == null and owner.state == .i2c_creating);
        }
        model.count = 0;
        try t.expect((try owner.poll()) == null);
        var response: [32]u8 = undefined;
        const child = &owner.i2c.?;
        const encoded = try objects.encode(&child.plan, child.outstanding.?, &response);
        if (encoded.function == 103) try t.expect(get(&response, 4) == owner.base.plan.handles.subdevice and get(&response, 12) == 0x402c and get(&response, 20) == 0);
        put(&response, if (encoded.function == 103) 16 else 12, if (case == .rejected or case == .free_reject) 0x55 else 0);
        try model.replyRpc(&session, .{ .function = encoded.function, .result = if (case == .alloc_rpc) 0x66 else 0 }, encoded.bytes);
        if (case == .alloc_ack or case == .free_ack) { model.fault = model.count + 4; model.after = true; }
        if (case == .rejected) {
            try t.expect((try owner.poll()) == null and !child.live and child.rejected.? == 0x55);
            for (0..7) |_| {
                model.count = 0;
                if (owner.state == .ready) break;
                try graphOperation(model, &owner, 0);
            }
            var loan = try owner.loan(deadline);
            try t.expect(loan.object.i2c == 0);
            var returned = try @import("gsp_exchange.zig").Exchange.init(&loan.runtime, deadline);
            var handoff = try returned.handoff(deadline);
            try owner.reclaim(&handoff, deadline);
            model.count = 0;
            _ = try graphDestroy(model, &owner);
            try t.expect(session.state == .active and owner.state == .finished);
        } else {
            try t.expectError(if (case == .alloc_ack or case == .free_ack) error.Io else error.FirmwareResult, owner.poll());
            try t.expect(owner.state == .failed and session.state == .failed and owner.base.state == .loaned);
            for (owner.base.slots) |slot| try t.expect(slot == .live);
            try t.expectError(error.Retained, session.rm_names.retire(owner.reservation));
            const calls = model.count;
            try t.expectError(error.State, owner.poll());
            try t.expectError(error.State, owner.finish(deadline));
            try t.expect(model.count == calls);
        }
    }
}

fn checkDdcReceiver(model: *Model) !void {
    const capture = try t.allocator.create(receiver.Capture);
    defer t.allocator.destroy(capture);
    const end = 20 * std.time.ns_per_ms;
    const Case = enum { full, bounded, dvi, bad_base, bad_extension, no_ddc_port, rejected_ports, prefix_error,
        retry, exhausted, changed_base, changed_bus, hpd, ack, expired };
    for (std.enums.values(Case)) |case| {
        var session: transport.Session = undefined;
        var boot = try startBoot(model, &session);
        try model.replyRpc(&session, .{ .function = 0x1001, .result = 0 }, &.{ 0, 0, 0, 0 });
        try boot.complete((try boot.poll()).?.ticket);
        var token = try boot.handoff(deadline);
        var parent = try rm_graph.Owner.init(&token, 1, "DDC", deadline);
        try graphCreate(model, &parent);
        var refresh = try receiver.Refresh.init(&parent, 1, capture, end);
        var blob: [4096]u8 = undefined;
        receiverFixture(&blob);
        if (case == .dvi) receiverFixture(blob[0..128]);
        if (case == .bounded) { blob[126] = 32; receiverChecksum(blob[0..128]); }
        if (case == .bad_base) blob[0] = 1;
        if (case == .bad_extension) blob[255] ^= 1;
        var reads: usize = 0;
        var steps: usize = 0;
        errdefer |err| std.debug.print("DDC case={s} error={s} state={s} bytes={d} reads={d}\n", .{@tagName(case), @errorName(err), @tagName(refresh.state), capture.edid_bytes, reads});
        while (refresh.state != .complete and refresh.state != .obsolete and steps < 90) : (steps += 1) {
            model.count = 0;
            if (refresh.waiting()) {
                const sent = session.tx_sequence;
                try t.expect((try refresh.poll()) == null and session.tx_sequence == sent);
                model.now = refresh.retry_at_ns;
            }
            try t.expect((try refresh.poll()) == null);
            if (refresh.channel.exchange.phase != .waiting) continue;
            const query = refresh.channel.request.?;
            try t.expect(refresh.matches(&refresh.channel.exchange, end) == false); // Already submitted.
            model.peerPut(session.link.?.command_read, get(&model.peer[0], 16));
            var bytes: [display_rpc.max_request_bytes]u8 = undefined;
            const payload = try display_rpc.encode(refresh.channel.object, query, &bytes);
            switch (query) {
                .supported => { put(&bytes, 28, 1); put(&bytes, 32, 1); },
                .connected => put(&bytes, 32, 1),
                .edid => {
                    const raw_size: usize = if (case == .full or case == .bounded) 2048 else 0;
                    put(&bytes, 32, @intCast(raw_size));
                    @memcpy(bytes[40..][0..raw_size], blob[0..raw_size]);
                },
                .buses => put(&bytes, 36, if (case == .changed_bus and refresh.state == .bus_verify) 4 else 3),
                .resource => { put(&bytes, 36, 2); put(&bytes, 40, 1); },
                .ports => {
                    bytes[26] = if (case == .no_ddc_port) 1 else 7;
                    if (case == .rejected_ports) put(&bytes, 12, 0x55);
                },
                .ddc => |request| {
                    try t.expect(request.port == 2 and request.display_id == 1 and request.block < 32);
                    try t.expect(get(&bytes, 4) == parent.base.plan.handles.i2c and get(&bytes, 20) == 2);
                    var block = blob[@as(usize, request.block) * 128 ..][0..128].*;
                    if (case == .changed_base and refresh.state == .ddc_verify) { block[9] ^= 1; receiverChecksum(&block); }
                    _ = try display_rpc.ddc_wire.encode(.{ .port = request.port, .block = request.block }, &block, bytes[24..]);
                    if ((case == .retry and reads < 2) or case == .exhausted) {
                        put(&bytes, 12, if (reads % 2 == 0) 3 else 0x14);
                        @memset(bytes[24..payload.len], 0xee); // Error output is forbidden, including retry data.
                    }
                    if (case == .prefix_error and request.block == 16) put(&bytes, 12, 0x1f);
                    if (case == .hpd and reads == 0) {
                        var post: [40]u8 = undefined;
                        const notice = registeredPost(&post, .hotplug, true);
                        put(&post, 0, parent.reservation.client);
                        put(&post, 4, try parent.reservation.object(3));
                        try model.replyRpc(&session, .{ .function = 0x1003, .result = 0 }, notice);
                        _ = (try refresh.poll()).?;
                        var delivery = try runtime_events.Dispatch.initDisplay(&refresh.channel, try parent.eventSink());
                        try delivery.step();
                    }
                    reads += 1;
                },
                else => return error.UnexpectedDdc,
            }
            try model.replyRpc(&session, .{ .function = 76, .result = 0 }, payload);
            if (query == .ddc and (case == .ack or case == .expired)) {
                if (case == .ack) { model.fault = model.count + 4; model.after = true; } else model.now = end;
                try t.expectError(if (case == .ack) error.Io else error.Deadline, refresh.poll());
                try t.expect(session.state == .failed and refresh.state == .failed and parent.state == .loaned);
                try t.expectError(error.State, refresh.release(end + 1));
                break;
            }
            try t.expect((try refresh.poll()) == null);
            if (refresh.channel.exchange.phase == .idle and refresh.channel.supported != null and refresh.state == .connected)
                try t.expectError(error.Query, refresh.channel.begin(.{ .ddc = .{ .display_id = 1, .port = 2, .block = 0 } }, end));
        }
        try t.expect(steps < 90);
        if (case == .ack or case == .expired) continue;
        if (case == .changed_base or case == .changed_bus or case == .hpd) {
            try t.expect(refresh.state == .obsolete);
            try t.expectError(error.State, refresh.borrow(end));
        } else {
            const result = try refresh.borrow(end);
            const expected: receiver.Status = switch (case) {
                .bounded, .bad_extension, .prefix_error => .incomplete_edid,
                .no_ddc_port, .rejected_ports => .edid_missing,
                .bad_base => .invalid_edid,
                .exhausted => .edid_rejected,
                else => .valid_edid,
            };
            try t.expectEqual(expected, result.status);
            if (case == .full or case == .bounded or case == .retry) try t.expect(result.edid_bytes == 4096 and result.source == .ddc);
            if (case == .full) try t.expectEqualSlices(u8, &blob, result.bytes[0..4096]);
            if (case == .dvi) try t.expect(result.edid_bytes == 128 and result.report.audio_count == 0 and !result.report.hdmi);
            if (case == .retry or case == .exhausted) try t.expect(result.ddc_retries == 2);
            if (case == .exhausted) try t.expect(reads == 3 and result.edid_bytes == 0);
            if (case == .prefix_error) try t.expect(result.edid_bytes == 2048 and result.ddc_control_status.? == 0x1f);
            if (case == .no_ddc_port or case == .rejected_ports) try t.expect(reads == 0);
        }
        try refresh.release(end);
        try t.expect(parent.state == .ready and session.state == .active);
    }
}

test "GSP transport orders range publication, explicit acknowledgement and terminal ambiguous failures" {
    const model = try t.allocator.create(Model);
    defer t.allocator.destroy(model);
    try checkDdcWire();
    try checkAuxWire();
    try checkDisplayRpc(model);
    try checkObjects(model);
    try checkRuntimeEvents(model);
    try checkEventObjects(model);
    try checkRmGraph(model);
    try checkI2cGraph(model);
    try checkReceiver(model);
    try checkDdcReceiver(model);
    try checkAuxReceiver(model);
    try checkTopology(model);
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
        try t.expect(model.prepares == 1 and model.notifications == 1 and !model.notify_pending);
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
        try t.expectEqual(@as(usize, 1), model.notifications); // ACK does not kick RM.
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
    try t.expectEqual(@as(usize, 63), model.notifications); // One kick for all wrapped spans.
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
    try t.expect(model.prepares == 62 and model.notifications == 62);

    // Notification preflight precedes every command publication. Its own
    // identity, failure and time are part of the same terminal session.
    session = try model.start(3);
    session.port.notification = null; // Explicit memory-only fixture.
    try t.expectError(error.Notification, session.send(deadline, .{ .function = 79 }, "x"));
    try t.expect(model.count == 0 and model.notifications == 0);
    session = try model.start(3);
    model.signal_epoch = model.epoch + 1;
    try t.expectError(error.Stale, session.send(deadline, .{ .function = 79 }, "x"));
    try t.expectEqual(@as(usize, 0), model.count);
    for ([_]SignalPhase{ .prepare, .submit }) |phase| for ([_]bool{ false, true }) |after| {
        session = try model.start(3);
        model.signal_fault = phase;
        model.signal_after = after;
        try t.expectError(error.Io, session.send(deadline, .{ .function = 79 }, "x"));
        try t.expectEqual(error.NotifyFailure, session.last_io_error.?);
        try t.expectEqual(@as(u32, if (phase == .submit) 1 else 0), get(&model.peer[0], 16));
        try t.expectEqual(@as(usize, if (phase == .submit and after) 1 else 0), model.notifications);
        const calls = model.count;
        const notifications = model.notifications;
        try t.expectError(error.State, session.send(deadline + 100, .{ .function = 79 }, "retry"));
        try t.expectEqual(calls, model.count);
        try t.expectEqual(notifications, model.notifications);
    };
    for ([_]SignalPhase{ .prepare, .submit }) |phase| for ([_]bool{ false, true }) |stale| {
        session = try model.start(3);
        if (stale) model.signal_stale = phase else model.signal_expire = phase;
        try t.expectError(if (stale) error.Stale else error.Deadline, session.send(deadline, .{ .function = 79 }, "x"));
        try t.expectEqual(@as(u32, if (phase == .submit) 1 else 0), get(&model.peer[0], 16));
        try t.expectEqual(@as(u32, 0), session.tx_sequence);
    };

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
