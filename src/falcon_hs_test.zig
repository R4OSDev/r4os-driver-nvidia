const std = @import("std");
const t = std.testing;
const hs = @import("falcon_hs.zig");
const r = hs.reg;
const b = hs.bits;

fn options(engine: hs.Engine) hs.Options {
    const offset: u32 = if (engine == .gsp) 0 else 256;
    return .{ .engine = engine, .boot0 = 0xb76000a1, .epoch = 7, .deadline = 1000000, .imem_capacity = 65536, .dmem_capacity = 65536, .mailboxes = .{ 0x12345678, 0x23456789 }, .plan = .{
        .imem = .{ .base = 0x12345678000, .source_offset = offset, .destination = 0, .bytes = 512, .command = b.imem_command },
        .dmem = .{ .base = 0x12345678200 + @as(u64, offset), .source_offset = 0, .destination = 0, .bytes = 512, .command = b.dmem_command },
        .boot_vector = offset,
        .signature_address = 16,
        .engine_mask = if (engine == .gsp) 0x400 else 1,
        .ucode_id = if (engine == .gsp) 9 else 3,
    } };
}
const Model = struct {
    config: hs.Options,
    clock: u64 = 100,
    epoch: u64 = 7,
    admits: u32 = 0,
    reads: u32 = 0,
    writes: u32 = 0,
    bases: u32 = 0,
    commands: u32 = 0,
    idle_reads: u32 = 0,
    idle_seen: bool = false,
    queue_wait: bool = true,
    last_status: u32 = b.full,
    destination: ?u32 = null,
    source: ?u32 = null,
    brom: u32 = 0,
    mailbox_writes: u32 = 0,
    started: bool = false,
    alias: bool = true,
    deny: bool = false,
    hold_full: bool = false,
    hold_idle: bool = false,
    hold_halt: bool = false,
    unavailable: bool = false,
    fail_write: ?u32 = null,
    expire_write: ?u32 = null,

    fn cast(p: *anyopaque) *Model {
        return @ptrCast(@alignCast(p));
    }
    fn generation(p: *anyopaque) u64 {
        return cast(p).epoch;
    }
    fn now(p: *anyopaque) u64 {
        return cast(p).clock;
    }
    fn admit(p: *anyopaque, config: *const hs.Options) anyerror!void {
        const self = cast(p);
        self.admits += 1;
        try t.expectEqualDeep(self.config, config.*);
        if (self.deny) return error.Denied;
    }
    fn base(self: *const Model) u32 {
        return if (self.config.engine == .gsp) r.gsp else r.sec2;
    }
    fn read(p: *anyopaque, address: u32) anyerror!u32 {
        const self = cast(p);
        try t.expectEqual(@as(u32, 1), self.admits);
        self.reads += 1;
        if (self.unavailable) return 0xbadf1234;
        return switch (address - self.base()) {
            r.fbif_offset + r.fbif_control => 0x1200,
            r.fbif_offset + r.transcfg => 0x3452,
            r.dma_command => blk: {
                if (self.hold_full) break :blk b.full;
                if (self.commands == 2) {
                    self.idle_reads += 1;
                    if (self.hold_idle or self.idle_reads == 1) break :blk 0;
                    self.idle_seen = true;
                } else if (self.queue_wait) {
                    self.queue_wait = false;
                    self.last_status = b.full;
                    break :blk b.full;
                }
                self.last_status = b.idle;
                break :blk b.idle;
            },
            r.cpu_control => (if (self.alias) @as(u32, b.cpu_alias) else 0) | (if (self.started and !self.hold_halt) @as(u32, b.cpu_halted) else 0),
            r.mailbox0 => if (self.started) 0xffffffff else error.EarlyMailbox,
            r.mailbox1 => if (self.started) 0xbadf7777 else error.EarlyMailbox,
            else => error.UnexpectedRead,
        };
    }
    fn write(p: *anyopaque, address: u32, value: u32) anyerror!void {
        const self = cast(p);
        const offset = address - self.base();
        try t.expectEqual(@as(u32, 1), self.admits);
        self.writes += 1;
        switch (offset) {
            r.fbif_offset + r.fbif_control => try t.expectEqual(@as(u32, 0x1280), value),
            r.dma_control => try t.expectEqual(@as(u32, 0), value),
            r.fbif_offset + r.transcfg => try t.expectEqual(@as(u32, 0x3455), value),
            r.dma_base => {
                try t.expect(self.last_status & b.full == 0 and self.bases < 2);
                if (self.bases == 1) try t.expect(self.commands == 2 and self.idle_seen);
                const transfer = if (self.bases == 0) self.config.plan.imem else self.config.plan.dmem;
                try t.expectEqual(@as(u32, @truncate(transfer.base >> 8)), value);
                self.bases += 1;
                self.commands = 0;
                self.idle_reads = 0;
                self.idle_seen = false;
            },
            r.dma_base_high => {
                const transfer = if (self.bases == 1) self.config.plan.imem else self.config.plan.dmem;
                try t.expectEqual(@as(u32, @intCast((transfer.base >> 40) & 0x1ff)), value);
            },
            r.dma_destination => {
                try t.expect(self.last_status & b.full == 0);
                try t.expectEqual(self.commands * 256, value);
                self.destination = value;
            },
            r.dma_source_offset => {
                const transfer = if (self.bases == 1) self.config.plan.imem else self.config.plan.dmem;
                try t.expectEqual(self.commands * 256 + transfer.source_offset, value);
                self.source = value;
            },
            r.dma_command => {
                try t.expect(self.last_status & b.full == 0 and self.destination != null and self.source != null and self.commands < 2);
                try t.expectEqual(@as(u32, if (self.bases == 1) b.imem_command else b.dmem_command), value);
                self.commands += 1;
                self.destination = null;
                self.source = null;
                self.queue_wait = true;
            },
            r.second_offset + r.signature => {
                try t.expect(self.bases == 2 and self.commands == 2 and self.idle_seen);
                try t.expectEqual(@as(u32, 16), value);
                self.brom += 1;
            },
            r.second_offset + r.engine_mask => {
                try t.expectEqual(@as(u32, 1), self.brom);
                try t.expectEqual(@as(u32, self.config.plan.engine_mask), value);
                self.brom += 1;
            },
            r.second_offset + r.ucode => {
                try t.expectEqual(@as(u32, 2), self.brom);
                try t.expectEqual(@as(u32, self.config.plan.ucode_id), value);
                self.brom += 1;
            },
            r.second_offset + r.algorithm => {
                try t.expectEqual(@as(u32, 3), self.brom);
                try t.expectEqual(@as(u32, 1), value);
                self.brom += 1;
            },
            r.boot_vector => {
                try t.expectEqual(@as(u32, 4), self.brom);
                try t.expectEqual(self.config.plan.boot_vector, value);
            },
            r.mailbox0, r.mailbox1 => {
                const index: usize = if (offset == r.mailbox0) 0 else 1;
                try t.expectEqual(self.config.mailboxes[index].?, value);
                self.mailbox_writes += 1;
            },
            r.cpu_control, r.cpu_alias => {
                try t.expectEqual(@as(u32, if (self.alias) r.cpu_alias else r.cpu_control), offset);
                try t.expect(self.brom == 4 and !self.started);
                try t.expectEqual(@as(u32, 2), value);
                self.started = true;
            },
            else => return error.UnexpectedWrite,
        }
        if (self.expire_write == offset) self.clock = self.config.deadline;
        if (self.fail_write == offset) return error.PostedFailure;
    }
    fn io(self: *Model) hs.Io {
        return .{ .context = self, .generation = generation, .now_ns = now, .admit = admit, .read32 = read, .write32 = write };
    }
    fn drive(self: *Model, operation: *hs.Operation) !void {
        for (0..128) |_| {
            if (try operation.step(self.io())) return;
            self.clock += 1;
        }
        return error.Bound;
    }
};

test "firmware CPU storage HS Falcon DMA honors queue ordering, PKC and irreversible failure" {
    for ([_]hs.Engine{ .gsp, .sec2 }) |engine| {
        for ([_]bool{ false, true }) |alias| {
            var config = options(engine);
            if (!alias) config.mailboxes = .{ null, null };
            var model: Model = .{ .config = config, .alias = alias };
            var operation = try hs.Operation.init(config);
            try model.drive(&operation);
            try t.expectEqual(@as(u32, 4), operation.result.blocks);
            try t.expect(model.started and model.idle_seen and operation.dma_attempted and operation.start_attempted);
            try t.expectEqual(@as(u32, if (alias) 2 else 0), model.mailbox_writes);
            try t.expectEqual(if (alias) @as(?u32, 0xffffffff) else null, operation.result.mailboxes[0]);
            try t.expectEqual(if (alias) @as(?u32, 0xbadf7777) else null, operation.result.mailboxes[1]);
            const writes = model.writes;
            try t.expect(try operation.step(model.io()));
            try t.expectEqual(writes, model.writes);
            model.epoch += 1;
            try t.expectError(error.Stale, operation.step(model.io()));
        }
    }
    const config = options(.sec2);
    var bad = config;
    bad.plan.ucode_id = 9;
    try t.expectError(error.Profile, hs.Operation.init(bad));
    bad = config;
    bad.dmem_capacity = 256;
    try t.expectError(error.Capacity, hs.Operation.init(bad));
    bad = config;
    bad.plan.dmem.base += 256;
    try t.expectError(error.Layout, hs.Operation.init(bad));
    bad = config;
    bad.plan.signature_address = 132;
    try t.expectError(error.Layout, hs.Operation.init(bad));
    bad = config;
    bad.plan.imem.base = 0x1fffffffffe00;
    try t.expectError(error.Address, hs.Operation.init(bad));
    bad = config;
    bad.plan.dmem.command |= 0x10000;
    try t.expectError(error.Profile, hs.Operation.init(bad));
    var model: Model = .{ .config = config, .deny = true };
    var operation = try hs.Operation.init(config);
    try t.expectError(error.Denied, operation.step(model.io()));
    try t.expect(model.reads == 0 and model.writes == 0 and !operation.write_attempted);
    for ([_]hs.Phase{ .base_wait, .block_wait, .idle, .halt }) |phase| {
        model = .{ .config = config };
        operation = try hs.Operation.init(config);
        for (0..128) |_| {
            if (operation.phase == phase) break;
            _ = try operation.step(model.io());
        }
        try t.expectEqual(phase, operation.phase);
        if (phase == .idle) model.hold_idle = true else if (phase == .halt) model.hold_halt = true else model.hold_full = true;
        const writes = model.writes;
        try t.expect(!try operation.step(model.io()));
        try t.expectEqual(writes, model.writes);
        model.clock = config.deadline;
        try t.expectError(error.Deadline, operation.step(model.io()));
        try t.expectError(error.State, operation.step(model.io()));
        try t.expectEqual(writes, model.writes);
    }
    for ([_]u32{ r.fbif_offset + r.fbif_control, r.dma_command, r.cpu_alias }) |offset| {
        for ([_]bool{ false, true }) |expire| {
            model = .{ .config = config, .fail_write = if (expire) null else offset, .expire_write = if (expire) offset else null };
            operation = try hs.Operation.init(config);
            if (expire) try t.expectError(error.Deadline, model.drive(&operation)) else try t.expectError(error.PostedFailure, model.drive(&operation));
            try t.expect(operation.write_attempted and operation.last_address.? == r.sec2 + offset);
            const writes = model.writes;
            try t.expectError(error.State, operation.step(model.io()));
            try t.expectEqual(writes, model.writes);
        }
    }
    model = .{ .config = config, .unavailable = true };
    operation = try hs.Operation.init(config);
    try t.expectError(error.RegisterUnavailable, model.drive(&operation));
    try t.expect(model.writes == 0 and operation.last_value.? == 0xbadf1234);
    model = .{ .config = config };
    operation = try hs.Operation.init(config);
    _ = try operation.step(model.io());
    var moved = operation;
    try t.expectError(error.State, moved.step(model.io()));
    model.clock = 1;
    try t.expectError(error.Clock, operation.step(model.io()));
    try t.expect(model.writes == 0);
}
