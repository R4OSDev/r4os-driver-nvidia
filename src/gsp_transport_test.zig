const std = @import("std");
const t = std.testing;
const transport = @import("gsp_transport.zig");
const boot_events = @import("gsp_boot_events.zig");
const sequencer = @import("gsp_sequencer.zig");
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
