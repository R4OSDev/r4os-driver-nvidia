const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const t = std.testing;
const core = @import("gsp_core.zig");
const seq = @import("gsp_sequencer.zig");
const native = @import("gsp_sequencer_port.zig");
const identity = @import("identity.zig");
const r = core.reg;
const b = core.bits;
const boot0 = 0xb76000a1;
const args: core.Resume = .{ .libos_dma = 0x123456000, .app_version = 0x570144 };
const Model = struct {
    clock: u64 = 1000000,
    epoch: u64 = 7,
    ready: bool = false,
    reset_edges: u32 = 0,
    propagation: u32 = 0,
    scrub_reads: u32 = 0,
    reads: u32 = 0,
    bcr: u32 = b.bcr_riscv | b.bcr_valid,
    alias: bool = true,
    halted: bool = true,
    handoff: bool = true,
    mailbox: u32 = 0,
    active: bool = true,
    logs_enabled: bool = true,
    logs_calls: u32 = 0,
    posted_failure: bool = false,
    read_error: ?u32 = null,
    writes: [12]seq.Write = undefined,
    write_count: usize = 0,
    fn cast(p: *anyopaque) *Model {
        return @ptrCast(@alignCast(p));
    }
    fn generation(p: *anyopaque) u64 {
        return cast(p).epoch;
    }
    fn now(p: *anyopaque) u64 {
        return cast(p).clock;
    }
    fn read(p: *anyopaque, address: u32) anyerror!u32 {
        const self = cast(p);
        self.reads += 1;
        if (self.read_error) |value| return value;
        return switch (address) {
            r.hwcfg2 => blk: {
                if (self.reset_edges == 2) self.scrub_reads += 1;
                break :blk b.riscv_enabled | (if (self.ready) @as(u32, b.reset_ready) else 0) |
                    (if (self.reset_edges == 2 and self.scrub_reads < 3) @as(u32, b.scrubbing) else 0);
            },
            r.engine => blk: {
                self.propagation += 1;
                break :blk 0x84 | @as(u32, if (self.reset_edges == 1) 1 else 0);
            },
            r.bcr => self.bcr,
            r.fbif => 0x1200,
            r.cpuctl, r.sec_cpuctl => (if (self.alias) @as(u32, b.alias) else 0) | (if (self.halted) @as(u32, b.halted) else 0),
            r.handoff => if (self.handoff) b.handoff_done else 0,
            r.sec_mailbox0 => self.mailbox,
            r.riscv_cpuctl => if (self.active) b.active else 0,
            else => error.UnexpectedRead,
        };
    }
    fn write(p: *anyopaque, address: u32, value: u32) anyerror!void {
        const self = cast(p);
        if (address == r.engine) {
            if (self.reset_edges == 0) {
                try t.expect(self.ready or self.clock >= 1000000 + core.pre_reset_ns);
                try t.expectEqual(@as(u32, 0x85), value);
            } else {
                try t.expectEqual(@as(u32, 1), self.reset_edges);
                try t.expect(self.propagation >= 10);
                try t.expectEqual(@as(u32, 0x84), value);
            }
            self.reset_edges += 1;
            self.propagation = 0;
        }
        if (address == r.bcr) {
            try t.expectEqual(@as(u32, 2), self.reset_edges);
            try t.expect(self.propagation == 10 and self.scrub_reads >= 3);
            self.bcr = value | b.bcr_valid;
        }
        self.writes[self.write_count] = .{ .address = address, .value = value };
        self.write_count += 1;
        if (self.posted_failure) return error.Posted;
    }
    fn logs(p: *anyopaque, enable: bool) anyerror!void {
        const self = cast(p);
        self.logs_enabled = enable;
        self.logs_calls += 1;
    }
    fn io(self: *Model) core.Io {
        return .{ .context = self, .generation = generation, .now_ns = now, .read32 = read, .write32 = write, .log_polling = logs };
    }
    fn operation(self: *Model, opcode: seq.Opcode) !core.Operation {
        return core.Operation.init(opcode, self.epoch, self.clock + std.time.ns_per_s, boot0, args);
    }
    fn drive(self: *Model, op: *core.Operation) !void {
        for (0..128) |_| {
            if (try op.step(self.io())) return;
            self.clock += 10000;
        }
        return error.Unbounded;
    }
};

// Exercises real volatile accessors against host memory furnished through the
// actual DriverContext -> GfxDriverMemoryApi path. This is not hardware MMIO.
const NativeRig = struct {
    words: []align(4096) u32,
    clock: u64 = 100,
    epoch: u64 = 9,
    mapped: bool = false,
    retains: u32 = 0,
    accesses: u32 = 0,
    flushes: u32 = 0,
    unmaps: u32 = 0,
    quiet: bool = false,
    wrong_flush: bool = false,
    fail_unmap: bool = false,
    wrong_map: bool = false,
    fn cast(p: *anyopaque) *NativeRig {
        return @ptrCast(@alignCast(p));
    }
    fn generation(p: *anyopaque) u64 {
        return cast(p).epoch;
    }
    fn now() callconv(.c) u64 {
        return rig.clock;
    }
    fn admit(_: *anyopaque, _: seq.Command) error{ Denied, Unsupported }!void {}
    fn access(p: *anyopaque, kind: native.Access, address: u32) anyerror!void {
        const self = cast(p);
        self.accesses += 1;
        if (kind == .read and (address == r.cpuctl_alias or address == r.sec_cpuctl_alias)) return error.WriteOnly;
        if (kind == .read and address == 0 and self.retains != 0) {
            self.flushes += 1;
            if (self.wrong_flush) self.words[0] = 0;
        }
    }
    fn retain(p: *anyopaque) anyerror!void {
        cast(p).retains += 1;
    }
    fn quiesced(p: *anyopaque) bool {
        return cast(p).quiet;
    }
    fn owner(self: *NativeRig) native.Owner {
        return .{ .context = self, .generation = generation, .admit = admit, .access = access, .retain = retain, .quiesced = quiesced };
    }
    fn resourceQuery(out: *a.DriverResourceApi) callconv(.c) i32 {
        out.* = .{ .now_ns = @intFromPtr(&now) };
        return 0;
    }
    fn memoryQuery(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = .{ .mmio_map = @intFromPtr(&map), .mmio_unmap = @intFromPtr(&unmap), .collect = @intFromPtr(&collect) };
        return a.gfx_buffer_result_ok;
    }
    fn map(request: *const a.GfxMmioRequest, out: *a.GfxMmioWindow) callconv(.c) i32 {
        std.debug.assert(!rig.mapped and request.byte_length == rig.words.len * 4 and request.cache_policy == a.gfx_buffer_cache_uncached);
        rig.mapped = true;
        out.* = .{ .handle = .{ .id = 5, .generation = 8 }, .cpu_address = @intFromPtr(rig.words.ptr), .physical_address = request.resource_base, .byte_length = request.byte_length, .cache_policy = if (rig.wrong_map) a.gfx_buffer_cache_write_back else a.gfx_buffer_cache_uncached };
        return a.gfx_buffer_result_ok;
    }
    fn unmap(handle: *const a.GfxBufferHandle, quiet: u32) callconv(.c) i32 {
        std.debug.assert(rig.mapped and handle.id == 5 and quiet == 1);
        rig.unmaps += 1;
        if (rig.fail_unmap) return a.gfx_buffer_error_busy;
        rig.mapped = false;
        return a.gfx_buffer_result_ok;
    }
    fn collect() callconv(.c) i32 {
        std.debug.assert(!rig.mapped);
        return a.gfx_buffer_result_ok;
    }
    fn table() a.DriverApi {
        var api: a.DriverApi = undefined;
        api.magic = a.driver_magic;
        api.version = 34;
        api.size = @sizeOf(a.DriverApi);
        api.resource_query = resourceQuery;
        api.gfx_memory_query = memoryQuery;
        return api;
    }
};
var rig: *NativeRig = undefined;

test "firmware CPU storage GA106 core sequencing and native MMIO ownership" {
    // Full reset: hint timeout is not failure, both edges propagate through
    // ten reads, scrubbing precedes switching, full BOOT0 goes into FALCON_RM.
    var model: Model = .{};
    var operation = try model.operation(.core_reset);
    try model.drive(&operation);
    try t.expectEqual(@as(usize, 6), model.write_count);
    try t.expectEqual(seq.Write{ .address = r.bcr, .value = 0 }, model.writes[2]);
    try t.expectEqual(seq.Write{ .address = r.rm, .value = boot0 }, model.writes[3]);
    try t.expectEqual(seq.Write{ .address = r.fbif, .value = 0x1280 }, model.writes[4]);
    try t.expectEqual(seq.Write{ .address = r.dmactl, .value = 0 }, model.writes[5]);
    for ([_]bool{ false, true }) |alias| {
        model = .{ .alias = alias };
        operation = try model.operation(.core_start);
        try model.drive(&operation);
        try t.expectEqual(seq.Write{ .address = if (alias) r.cpuctl_alias else r.cpuctl, .value = 2 }, model.writes[0]);
        operation = try model.operation(.core_halt);
        model.halted = false;
        try t.expect(!try operation.step(model.io()));
        model.halted = true;
        try t.expect(try operation.step(model.io()));
        try t.expectEqual(@as(usize, 1), model.write_count);
    }
    // Resume uses SEC2, not GSP STARTCPU; it requires handoff AND mailbox=0
    // before log polling/OS and an active RISC-V CPU before completion.
    for ([_]u32{ 0, 0xdead }) |mailbox| {
        model = .{ .ready = true, .mailbox = mailbox };
        operation = try model.operation(.core_resume);
        if (mailbox == 0) {
            try model.drive(&operation);
            try t.expect(model.logs_enabled and model.logs_calls == 2);
            try t.expectEqual(seq.Write{ .address = r.os, .value = args.app_version }, model.writes[6]);
        } else {
            try t.expectError(error.SecMailbox, model.drive(&operation));
            try t.expect(!model.logs_enabled and operation.logs_suspended and model.logs_calls == 1);
            try t.expectEqual(@as(usize, 6), model.write_count);
        }
        try t.expectEqual(seq.Write{ .address = r.bcr, .value = 0x111 }, model.writes[2]);
        try t.expectEqual(seq.Write{ .address = r.mailbox0, .value = 0x23456000 }, model.writes[3]);
        try t.expectEqual(seq.Write{ .address = r.mailbox1, .value = 1 }, model.writes[4]);
        try t.expectEqual(seq.Write{ .address = r.sec_cpuctl_alias, .value = 2 }, model.writes[5]);
    }
    model = .{ .ready = true, .active = false };
    operation = try model.operation(.core_resume);
    try t.expectError(error.NotActive, model.drive(&operation));
    for ([_]u32{ 0xffffffff, 0xbadf1234, 0xffff0000 }) |bad| {
        model = .{ .read_error = bad };
        operation = try model.operation(.core_halt);
        try t.expectError(error.RegisterUnavailable, operation.step(model.io()));
        try t.expectEqual(@as(usize, 0), model.write_count);
    }
    model = .{ .posted_failure = true };
    operation = try model.operation(.core_start);
    try t.expectError(error.Posted, operation.step(model.io()));
    try t.expect(operation.write_attempted and operation.failure.? == error.Posted);
    try t.expectError(error.State, operation.step(model.io()));
    try t.expectEqual(@as(usize, 1), model.write_count);
    model = .{ .halted = false };
    operation = try model.operation(.core_halt);
    try t.expect(!try operation.step(model.io()));
    const reads = model.reads;
    model.clock = operation.deadline;
    try t.expectError(error.Deadline, operation.step(model.io()));
    try t.expectEqual(reads, model.reads);

    const words = try t.allocator.alignedAlloc(u32, comptime std.mem.Alignment.fromByteUnits(4096), 0x841000 / 4);
    defer t.allocator.free(words);
    var fixture: NativeRig = .{ .words = words };
    rig = &fixture;
    @memset(words, 0);
    words[0] = boot0;
    words[r.cpuctl / 4] = b.alias | b.halted;
    var api = NativeRig.table();
    const ctx = r4os.r4dev.DriverContext.init(&api);
    var snapshot: identity.Snapshot = .{ .pci = .{ .vendor_id = 0x10de, .device_id = 0x2504, .class_code = 3 }, .command = 2 };
    snapshot.bars[0] = .{ .kind = .memory32, .base = 0xfb000000, .bytes = words.len * 4 };
    var port: native.Port = .{};
    try port.open(&ctx, &snapshot, boot0, 0, .{ .epoch = 9, .deadline_ns = 10000000 }, fixture.owner());
    const io = try port.sequencer();
    const initial_accesses = fixture.accesses;
    try t.expectError(error.Unsupported, io.admit(io.context, .core_resume));
    try t.expectError(error.Denied, io.admit(io.context, .{ .write = .{ .address = 0, .value = 0 } }));
    try t.expectError(error.Denied, io.admit(io.context, .{ .store = .{ .address = r.cpuctl_alias, .index = 0 } }));
    try t.expectError(error.Denied, io.admit(io.context, .{ .write = .{ .address = @intCast(words.len * 4), .value = 0 } }));
    try t.expectEqual(initial_accesses, fixture.accesses);
    var commands: [8]u8 = undefined;
    std.mem.writeInt(u32, commands[0..4], @intFromEnum(seq.Opcode.core_start), .little);
    std.mem.writeInt(u32, commands[4..8], @intFromEnum(seq.Opcode.core_halt), .little);
    var runner = try seq.Runner.init(.{ .capacity_words = 3, .commands = &commands, .saved = @splat(0) }, io, .{
        .profile = .{ .chip_id = 0x176 },
        .epoch = 9,
        .deadline_ns = 10000000,
        .default_timeout_ns = 1000000,
        .poll_interval_ns = 1000,
        .register_bytes = words.len * 4,
    });
    try t.expectEqual(seq.Progress.advanced, try runner.step());
    try t.expectEqual(seq.Progress.complete, try runner.step());
    try t.expectEqual(@as(u32, 2), words[r.cpuctl_alias / 4]);
    try t.expect(fixture.retains == 1 and fixture.flushes == 1);
    try t.expect(!port.close() and fixture.unmaps == 0);
    // An invalid flush comes AFTER the write: preserve the actual effect and
    // keep the MMIO/DMA owner alive. Subsequent callbacks cannot write again.
    fixture.wrong_flush = true;
    try t.expectError(error.IdentityChanged, io.write32(io.context, r.os, 0xaabb));
    try t.expectEqual(@as(u32, 0xaabb), words[r.os / 4]);
    try t.expectError(error.State, io.write32(io.context, r.os, 0xccdd));
    try t.expect(!port.close() and fixture.unmaps == 0);
    fixture.quiet = true;
    fixture.fail_unmap = true;
    try t.expect(!port.close() and port.window.handle.id == 5);
    try t.expectEqual(@as(u64, 0), io.generation(io.context));
    fixture.fail_unmap = false;
    try t.expect(port.close() and !fixture.mapped);
    try t.expectError(error.State, io.read32(io.context, r.os));
    // Bad descriptors are rejected before reads, and their handles are still
    // reclaimed through the same kernel cleanup path.
    fixture = .{ .words = words, .wrong_map = true };
    port = .{};
    try t.expectError(error.Mapping, port.open(&ctx, &snapshot, boot0, 0, .{ .epoch = 9, .deadline_ns = 10000000 }, fixture.owner()));
    try t.expect(fixture.accesses == 0 and fixture.mapped);
    try t.expect(port.close() and fixture.unmaps == 1);
}
