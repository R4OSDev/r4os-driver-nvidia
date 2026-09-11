const std = @import("std");
const t = std.testing;
const hs = @import("falcon_hs.zig");
const core = @import("gsp_core.zig");
const run = @import("falcon_run.zig");
const fwsec_result = @import("fwsec_result.zig");
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
    halt_observed: bool = false,
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
            r.cpu_control => blk: {
                if (self.started and !self.hold_halt) self.halt_observed = true;
                break :blk (if (self.alias) @as(u32, b.cpu_alias) else 0) | (if (self.halt_observed) @as(u32, b.cpu_halted) else 0);
            },
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
    try checkCompleteRun();
}

// One device model composes the actual reset and actual HS executors. The
// reset cannot be replaced by a callback that merely reports completion.
const RunModel = struct {
    dma: Model,
    reset_edges: u32 = 0,
    propagation: u32 = 0,
    reset_complete: bool = false,
    sizes_read: u32 = 0,
    hwcfg: u32 = 0x20100,
    bcr: u32 = core.bits.bcr_riscv | core.bits.bcr_valid,
    riscv: bool = true,
    unstable: bool = false,
    scrub_after_reset: bool = false,
    reset_stuck: bool = false,
    wrong_core: bool = false,
    lost_valid: bool = false,
    fail_reset: bool = false,
    fwsec: ?fwsec_result.Command = null,
    result_words: [3]u32 = @splat(0),
    result_reads: u8 = 0,
    expire_result: ?usize = null,
    stale_result: ?usize = null,
    fail_result: ?usize = null,

    fn cast(p: *anyopaque) *RunModel {
        return @ptrCast(@alignCast(p));
    }
    fn generation(p: *anyopaque) u64 {
        return cast(p).dma.epoch;
    }
    fn now(p: *anyopaque) u64 {
        return cast(p).dma.clock;
    }
    fn config(self: *const RunModel) run.Options {
        const c = self.dma.config;
        return .{ .engine = c.engine, .boot0 = c.boot0, .epoch = c.epoch, .deadline = c.deadline, .plan = c.plan, .mailboxes = c.mailboxes, .fwsec = self.fwsec };
    }
    fn admit(p: *anyopaque, config_: *const run.Options) anyerror!void {
        const self = cast(p);
        try t.expectEqualDeep(self.config(), config_.*);
        self.dma.admits += 1;
        if (self.dma.deny) return error.Denied;
    }
    fn read(p: *anyopaque, address: u32) anyerror!u32 {
        const self = cast(p);
        try t.expectEqual(@as(u32, 1), self.dma.admits);
        if (self.fwsec) |command| {
            const registers = if (command == .frts) fwsec_result.frts_registers else fwsec_result.sb_registers;
            for (registers, 0..) |expected, index| {
                if (address != expected) continue;
                try t.expect(self.dma.started and self.dma.halt_observed and self.reset_complete);
                try t.expectEqual(index, self.result_reads);
                self.result_reads += 1;
                if (self.expire_result == index) self.dma.clock = self.dma.config.deadline;
                if (self.stale_result == index) self.dma.epoch += 1;
                if (self.fail_result == index) return error.ReadResult;
                return self.result_words[index];
            }
        }
        const offset = address - self.dma.base();
        return switch (offset) {
            0x3c0 => blk: {
                self.propagation += 1;
                break :blk 0x84 | @as(u32, if (self.reset_edges == 1 or (self.reset_complete and self.reset_stuck)) 1 else 0);
            },
            0xf4 => core.bits.reset_ready | (if (self.riscv) @as(u32, core.bits.riscv_enabled) else 0) |
                (if (self.reset_complete and self.scrub_after_reset) @as(u32, core.bits.scrubbing) else 0),
            0x1668 => if (self.reset_complete and self.wrong_core) core.bits.bcr_riscv | core.bits.bcr_valid else if (self.reset_complete and self.lost_valid) 0 else self.bcr,
            run.hwcfg_offset => blk: {
                try t.expect(self.reset_complete and self.reset_edges == 2 and self.propagation >= 10);
                self.sizes_read += 1;
                break :blk self.hwcfg ^ @as(u32, if (self.unstable and self.sizes_read == 2) 1 else 0);
            },
            else => try Model.read(&self.dma, address),
        };
    }
    fn write(p: *anyopaque, address: u32, value: u32) anyerror!void {
        const self = cast(p);
        try t.expectEqual(@as(u32, 1), self.dma.admits);
        switch (address - self.dma.base()) {
            0x3c0 => {
                if (self.reset_edges == 0) try t.expectEqual(@as(u32, 0x85), value) else {
                    try t.expect(self.reset_edges == 1 and self.propagation >= 10);
                    try t.expectEqual(@as(u32, 0x84), value);
                }
                self.reset_edges += 1;
                self.propagation = 0;
                if (self.fail_reset) return error.ResetPosted;
            },
            0x1668 => {
                try t.expect(self.reset_edges == 2 and self.propagation == 10 and value == 0);
                self.bcr = core.bits.bcr_valid;
            },
            0x84 => {
                try t.expect(self.reset_edges == 2 and self.propagation == 10);
                try t.expectEqual(self.dma.config.boot0, value);
            },
            else => {
                if (address - self.dma.base() == r.dma_command) try t.expect(self.reset_complete and self.sizes_read == 2);
                try Model.write(&self.dma, address, value);
                if (address - self.dma.base() == r.dma_control) self.reset_complete = true;
            },
        }
    }
    fn io(self: *RunModel) run.Io {
        return .{ .context = self, .generation = generation, .now_ns = now, .admit = admit, .read32 = read, .write32 = write };
    }
    fn drive(self: *RunModel, operation: *run.Operation) !void {
        for (0..192) |_| {
            if (try operation.step(self.io())) return;
            self.dma.clock += 1;
        }
        return error.Bound;
    }
};

fn checkCompleteRun() !void {
    try checkFwsecResults();
    for ([_]hs.Engine{ .gsp, .sec2 }) |engine| {
        for ([_]bool{ false, true }) |riscv| {
            var model: RunModel = .{ .dma = .{ .config = options(engine) }, .riscv = riscv };
            var operation = try run.Operation.init(model.config());
            try model.drive(&operation);
            try t.expect(model.reset_edges == 2 and model.sizes_read == 2 and model.dma.started);
            try t.expectEqual(@as(u32, 65536), operation.hs_operation.?.options.imem_capacity);
            try t.expectEqual(@as(u32, 65536), operation.hs_operation.?.options.dmem_capacity);
            try t.expectEqual(@as(u32, 0xffffffff), operation.result.?.mailboxes[0].?);
            try t.expect(operation.result.?.fwsec == null and model.result_reads == 0);
            const writes = model.dma.writes;
            try t.expect(try operation.step(model.io()));
            model.dma.epoch += 1;
            try t.expectError(error.Stale, operation.step(model.io()));
            try t.expectEqual(writes, model.dma.writes);
        }
    }
    // Already-selected Falcon follows the original no-switch path even if
    // BCR.VALID retains zero. VALID is required after an actual switch write.
    var already: RunModel = .{ .dma = .{ .config = options(.sec2) }, .bcr = 0 };
    var already_op = try run.Operation.init(already.config());
    try already.drive(&already_op);
    try t.expect(!already_op.reset.core_switch_written and already.dma.started);
    const Fault = enum { denied, size, unstable, unavailable, scrub, reset, core_select, lost_valid, posted, hs_posted };
    for (std.enums.values(Fault)) |fault| {
        var model: RunModel = .{ .dma = .{ .config = options(.sec2) } };
        const expected: anyerror = switch (fault) {
            .denied => blk: {
                model.dma.deny = true;
                break :blk error.Denied;
            },
            .size => blk: {
                model.hwcfg = 0x300;
                break :blk error.Capacity;
            },
            .unstable => blk: {
                model.unstable = true;
                break :blk error.Unstable;
            },
            .unavailable => blk: {
                model.hwcfg = 0xbadf1234;
                break :blk error.RegisterUnavailable;
            },
            .scrub => blk: {
                model.scrub_after_reset = true;
                break :blk error.EngineState;
            },
            .reset => blk: {
                model.reset_stuck = true;
                break :blk error.EngineState;
            },
            .core_select => blk: {
                model.wrong_core = true;
                break :blk error.EngineState;
            },
            .lost_valid => blk: {
                model.lost_valid = true;
                break :blk error.EngineState;
            },
            .posted => blk: {
                model.fail_reset = true;
                break :blk error.ResetPosted;
            },
            .hs_posted => blk: {
                model.dma.fail_write = r.dma_command;
                break :blk error.PostedFailure;
            },
        };
        var operation = try run.Operation.init(model.config());
        try t.expectError(expected, model.drive(&operation));
        try t.expect(!model.dma.started);
        if (fault == .denied) try t.expect(model.reset_edges == 0 and !operation.reset.write_attempted) else try t.expect(operation.reset.write_attempted);
        const writes = model.dma.writes;
        const edges = model.reset_edges;
        try t.expectError(error.State, operation.step(model.io()));
        try t.expect(model.dma.writes == writes and model.reset_edges == edges);
    }
    var model: RunModel = .{ .dma = .{ .config = options(.gsp) } };
    var config = model.config();
    config.plan.dmem.command |= 0x10000;
    try t.expectError(error.Profile, run.Operation.init(config));
    var operation = try run.Operation.init(model.config());
    _ = try operation.step(model.io());
    var moved = operation;
    try t.expectError(error.State, moved.step(model.io()));
    model.dma.clock = model.dma.config.deadline;
    try t.expectError(error.Deadline, operation.step(model.io()));
    try t.expectEqual(@as(u32, 0), model.reset_edges);
}

fn resultModel(command: fwsec_result.Command) RunModel {
    var model: RunModel = .{ .dma = .{ .config = options(.gsp) }, .fwsec = command };
    model.dma.config.mailboxes = .{ null, null };
    // Unrelated bits are deliberately set; HI is not an exclusive end.
    model.result_words = switch (command) {
        .frts => |offset| .{ 0x0000ffff, @as(u32, @intCast((offset + 0xff000) >> 12)) << 4 | 3, @as(u32, @intCast(offset >> 12)) << 4 | 9 },
        .sb => .{ 0x31, 0x987654ff, 0xffff0000 },
    };
    return model;
}

fn checkFwsecResults() !void {
    const commands = [_]fwsec_result.Command{ .{ .frts = 0x2ffee0000 }, .sb };
    for (commands) |command| {
        var model = resultModel(command);
        var operation = try run.Operation.init(model.config());
        for (0..192) |_| {
            if (operation.phase == .fwsec_result) break;
            try t.expect(!(try operation.step(model.io())));
        }
        try t.expect(operation.phase == .fwsec_result and model.result_reads == 0 and operation.result == null);
        const writes = model.dma.writes;
        for (0..3) |index| {
            try t.expectEqual(index == 2, try operation.step(model.io()));
            try t.expectEqual(index + 1, model.result_reads);
            try t.expectEqual(index == 2, operation.result != null);
        }
        try t.expectEqualDeep(command, operation.result.?.fwsec.?.command);
        try t.expectEqualSlices(u32, &model.result_words, &operation.result.?.fwsec.?.raw);
        try t.expect(operation.result.?.mailboxes[0] == null and model.dma.mailbox_writes == 0);
        try t.expect(try operation.step(model.io()));
        try t.expectEqual(writes, model.dma.writes);
        try t.expectEqual(@as(u8, 3), model.result_reads);
        // Each original completion condition can independently fail. The
        // failed raw word remains available and no later read is attempted.
        const faults: [3]anyerror = if (command == .frts) .{ error.FrtsError, error.WprMissing, error.WprTarget } else .{ error.SbProtection, error.SbProgress, error.SbError };
        const values: [3]u32 = if (command == .frts) .{ 0x12340001, 0xf, 0x2ffed009 } else .{ 0x30, 0x987654fe, 0xabcd0001 };
        for (faults, values, 0..) |expected, value, index| {
            model = resultModel(command);
            model.result_words[index] = value;
            operation = try run.Operation.init(model.config());
            try t.expectError(expected, model.drive(&operation));
            try t.expect(operation.result == null and operation.halt_result != null);
            try t.expectEqual(index + 1, model.result_reads);
            try t.expectEqual(value, operation.fwsec_check.?.raw[index]);
            try t.expectEqual(expected, operation.fwsec_check.?.failure.?);
            const read_count = model.result_reads;
            const write_count = model.dma.writes;
            try t.expectError(error.State, operation.step(model.io()));
            try t.expect(model.result_reads == read_count and model.dma.writes == write_count);
        }
    }
    // The final observation must still share the original clock/epoch. A
    // register read itself may fail or consume the remainder of the deadline.
    const Fault = enum { unavailable, inaccessible, clock, epoch, io };
    for (std.meta.tags(Fault)) |fault| {
        var model = resultModel(commands[0]);
        const expected = switch (fault) {
            .unavailable => blk: { model.result_words[2] = 0xffffffff; break :blk error.RegisterUnavailable; },
            .inaccessible => blk: { model.result_words[2] = 0xbadf1234; break :blk error.RegisterUnavailable; },
            .clock => blk: { model.expire_result = 2; break :blk error.Deadline; },
            .epoch => blk: { model.stale_result = 2; break :blk error.Stale; },
            .io => blk: { model.fail_result = 2; break :blk error.ReadResult; },
        };
        var operation = try run.Operation.init(model.config());
        try t.expectError(expected, model.drive(&operation));
        try t.expect(operation.result == null and operation.halt_result != null);
        try t.expectEqual(expected, operation.failure.?);
        try t.expectEqual(@as(u8, 3), model.result_reads);
    }
    var model = resultModel(commands[0]);
    var invalid = model.config();
    invalid.engine = .sec2;
    try t.expectError(error.Options, run.Operation.init(invalid));
    invalid = model.config(); invalid.mailboxes[0] = 0;
    try t.expectError(error.Options, run.Operation.init(invalid));
    for ([_]u64{ 0, 1, (@as(u64, 1) << 40) - 0x100000 + 4096 }) |offset| {
        invalid = model.config(); invalid.fwsec = .{ .frts = offset };
        try t.expectError(error.Address, run.Operation.init(invalid));
    }
    // Highest complete GA106 range remains representable without truncation.
    invalid = model.config(); invalid.fwsec = .{ .frts = (@as(u64, 1) << 40) - 0x100000 };
    _ = try run.Operation.init(invalid);
}
