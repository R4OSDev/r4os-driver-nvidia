const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const t = std.testing;
const core = @import("gsp_core.zig");
const seq = @import("gsp_sequencer.zig");
const native = @import("gsp_sequencer_port.zig");
const hs = @import("falcon_hs.zig");
const firmware_run = @import("falcon_run.zig");
const identity = @import("identity.zig");
const r = core.reg;
const b = core.bits;
const boot0 = 0xb76000a1;
const args: core.Resume = .{ .libos_dma = 0x123456000, .app_version = 0x570144 };
const Model = struct {
    clock: u64 = 1000000,
    epoch: u64 = 7,
    ready: bool = false,
    riscv_enabled: bool = true,
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
    posted_address: ?u32 = null,
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
                break :blk (if (self.riscv_enabled) @as(u32, b.riscv_enabled) else 0) | (if (self.ready) @as(u32, b.reset_ready) else 0) |
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
        if (self.posted_failure or self.posted_address == address) return error.Posted;
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
    partial_map: bool = false,
    fail_collect: bool = false,
    hs_admissions: u32 = 0,
    booter_active: bool = false,
    booter_unload: bool = false,
    booter_mailboxes: u32 = 0,
    logs_enabled: bool = true,
    logs_calls: u32 = 0,
    frts_completed: bool = false,
    cold_prepared: bool = false,
    load_completed: bool = false,
    cold_admissions: u32 = 0,
    cold_admission_timeout: bool = false,
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
    fn admitFirmware(p: *anyopaque, options: *const firmware_run.Options) anyerror!void {
        const self = cast(p);
        try t.expect(options.epoch == self.epoch);
        if (options.booter) |command| {
            try t.expect(options.engine == .sec2);
            self.booter_active = true;
            self.booter_unload = command == .normal_unload;
        } else try t.expect(options.engine == .gsp);
        self.hs_admissions += 1;
    }
    fn admitCold(p: *anyopaque, command: core.Cold) anyerror!void {
        const self = cast(p);
        try t.expect(std.meta.eql(command.args, args));
        if (command.stage == .prepare) {
            if (!self.frts_completed or self.cold_prepared) return error.Dependencies;
        } else if (!self.cold_prepared or !self.load_completed) return error.Dependencies;
        self.cold_admissions += 1;
        if (self.cold_admission_timeout) self.clock = 1000000;
    }
    fn access(p: *anyopaque, kind: native.Access, address: u32) anyerror!void {
        const self = cast(p);
        self.accesses += 1;
        if (kind == .read and (address == r.cpuctl_alias or address == r.sec_cpuctl_alias)) return error.WriteOnly;
        // Host register model only: completed DMA and the existing halted
        // CPU word allow exercising actual MMIO wrappers without a real GPU.
        if (self.hs_admissions != 0 and kind == .read and (address == hs.reg.gsp + hs.reg.dma_command or address == hs.reg.sec2 + hs.reg.dma_command)) self.words[address / 4] = hs.bits.idle;
        if (self.booter_active and kind == .read and address == hs.reg.sec2 + hs.reg.mailbox0) {
            try t.expect(!self.logs_enabled);
            self.booter_mailboxes += 1;
            self.words[address / 4] = 0; // Host model of a successful Booter.
            if (self.booter_unload) self.words[0x1fa828 / 4] = 0;
            if (!self.booter_unload) self.words[r.riscv_cpuctl / 4] = b.active;
        }
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
    fn logs(p: *anyopaque, enable: bool) anyerror!void {
        const self = cast(p);
        try t.expect(self.booter_active and self.retains != 0);
        if (enable) try t.expect(!self.logs_enabled and self.booter_mailboxes != 0);
        self.logs_enabled = enable;
        self.logs_calls += 1;
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
        if (rig.partial_map) return a.gfx_buffer_error_budget;
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
        if (rig.fail_collect) return a.gfx_buffer_error_busy;
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

fn checkColdCore() !void {
    var checkpoint: u32 = 0;
    errdefer |err| std.debug.print("cold core check={d}: {s}\n", .{ checkpoint, @errorName(err) });
    for ([_]u64{ args.libos_dma, 0x100000000, @import("gsp_radix.zig").dma_mask - 4095 }) |address| {
        var model: Model = .{}; // RESET_READY remains a timed hint.
        const cold_args: core.Resume = .{ .libos_dma = address, .app_version = args.app_version };
        var op = try core.Operation.initCold(.{ .stage = .prepare, .args = cold_args }, model.epoch, model.clock + std.time.ns_per_s, boot0);
        checkpoint = 1;
        try model.drive(&op);
        try t.expectEqual(@as(usize, 5), model.write_count);
        try t.expectEqual(seq.Write{ .address = r.bcr, .value = 0x111 }, model.writes[2]);
        try t.expectEqual(seq.Write{ .address = r.mailbox0, .value = @truncate(address) }, model.writes[3]);
        try t.expectEqual(seq.Write{ .address = r.mailbox1, .value = @truncate(address >> 32) }, model.writes[4]);
        try t.expect(model.logs_calls == 0 and model.logs_enabled);
        // The owner must separately observe the actual Booter Load result
        // before this stage. This host core model supplies only ACTIVE.
        op = try core.Operation.initCold(.{ .stage = .finish, .args = cold_args }, model.epoch, model.clock + std.time.ns_per_s, boot0);
        checkpoint = 2;
        try model.drive(&op);
        try t.expectEqual(@as(usize, 6), model.write_count);
        try t.expectEqual(seq.Write{ .address = r.os, .value = args.app_version }, model.writes[5]);
        try t.expect(model.reset_edges == 2 and model.logs_calls == 0);
    }
    for ([_]u64{ 0, 1, 4097, @import("gsp_radix.zig").dma_mask + 1, std.math.maxInt(u64) }) |address| {
        checkpoint = 3;
        try t.expectError(error.BootArguments, core.Operation.initCold(.{ .stage = .prepare, .args = .{ .libos_dma = address, .app_version = 0 } }, 1, 1000, boot0));
    }
    for ([_]u32{ r.engine, r.bcr, r.mailbox0, r.mailbox1, r.os }) |address| {
        checkpoint = address;
        var model: Model = .{ .ready = true, .posted_address = address };
        var op = try core.Operation.initCold(.{ .stage = if (address == r.os) .finish else .prepare, .args = args }, model.epoch, model.clock + std.time.ns_per_s, boot0);
        try t.expectError(error.Posted, model.drive(&op));
        try t.expect(op.write_attempted and op.last_address.? == address and op.failure.? == error.Posted);
        const writes = model.write_count;
        try t.expectError(error.State, op.step(model.io()));
        try t.expectEqual(writes, model.write_count);
    }
    var model: Model = .{ .active = false };
    checkpoint = 4;
    var op = try core.Operation.initCold(.{ .stage = .finish, .args = args }, model.epoch, model.clock + std.time.ns_per_s, boot0);
    try t.expectError(error.NotActive, model.drive(&op));
    try t.expect(op.last_address.? == r.riscv_cpuctl and op.last_value.? == 0 and model.write_count == 1);
    model = .{ .riscv_enabled = false };
    checkpoint = 5;
    op = try core.Operation.initCold(.{ .stage = .prepare, .args = args }, model.epoch, model.clock + std.time.ns_per_s, boot0);
    try t.expectError(error.Resume, model.drive(&op));
    try t.expectEqual(@as(usize, 0), model.write_count);
    model = .{};
    checkpoint = 6;
    op = try core.Operation.initCold(.{ .stage = .prepare, .args = args }, model.epoch, model.clock + std.time.ns_per_s, boot0);
    model.epoch += 1;
    try t.expectError(error.Stale, op.step(model.io()));
    try t.expectEqual(@as(usize, 0), model.write_count);
    model = .{};
    checkpoint = 7;
    op = try core.Operation.initCold(.{ .stage = .finish, .args = args }, model.epoch, model.clock + 1000, boot0);
    try t.expect(!try op.step(model.io())); // OS written, ACTIVE still unobserved.
    model.clock = op.deadline;
    try t.expectError(error.Deadline, op.step(model.io()));
    try t.expect(op.last_address.? == r.os and model.write_count == 1);
}

test "firmware CPU storage GA106 core sequencing and native MMIO ownership" {
    var checkpoint: []const u8 = "cold-core";
    errdefer |err| std.debug.print("native core check={s}: {s}\n", .{ checkpoint, @errorName(err) });
    try checkColdCore();
    checkpoint = "existing-core";
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

    const words = try t.allocator.alignedAlloc(u32, comptime std.mem.Alignment.fromByteUnits(4096), 0x842000 / 4);
    checkpoint = "native-open";
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
    try port.open(&ctx, &snapshot, boot0, 0, .{ .epoch = 9, .deadline_ns = 10000000, .resume_args = args }, fixture.owner());
    const io = try port.sequencer();
    const initial_accesses = fixture.accesses;
    try t.expectError(error.Unsupported, io.admit(io.context, .core_resume));
    try t.expectError(error.Unsupported, port.beginColdBoot(.prepare, 1000000));
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
    words[(hs.reg.gsp + firmware_run.hwcfg_offset) / 4] = 0x20100;
    words[r.hwcfg2 / 4] = b.reset_ready;
    const hs_options: firmware_run.Options = .{
        .engine = .gsp,
        .boot0 = boot0,
        .epoch = fixture.epoch,
        .deadline = 1000000,
        .mailboxes = .{ 0x79, null },
        .plan = .{
            .imem = .{ .base = 0x123456000, .destination = 0, .source_offset = 0, .bytes = 512, .command = hs.bits.imem_command },
            .dmem = .{ .base = 0x123456200, .destination = 0, .source_offset = 0, .bytes = 512, .command = hs.bits.dmem_command },
            .boot_vector = 0,
            .signature_address = 16,
            .engine_mask = 0x400,
            .ucode_id = 9,
        },
    };
    try t.expectError(error.Unsupported, port.beginFirmware(hs_options));
    port.owner.?.admit_firmware = NativeRig.admitFirmware;
    var sec_options = hs_options;
    sec_options.engine = .sec2;
    sec_options.plan.ucode_id = 3;
    sec_options.plan.engine_mask = 1;
    sec_options.plan.imem.source_offset = 256;
    sec_options.plan.boot_vector = 256;
    sec_options.plan.dmem.base += 256;
    // Truncating an already opened aperture invalidates its retained mapping
    // stamp before firmware admission or any preceding DMA write.
    const full_aperture = port.window.byte_length;
    port.window.byte_length = 0x841000;
    try t.expectError(error.Stale, port.beginFirmware(sec_options));
    port.window.byte_length = full_aperture;
    try t.expectEqual(@as(u32, 0), fixture.hs_admissions);
    try port.beginFirmware(hs_options);
    try t.expectError(error.Busy, port.beginFirmware(hs_options));
    try t.expectError(error.Busy, port.sequencer());
    try t.expectError(error.Busy, io.read32(io.context, r.os));
    try t.expectError(error.Busy, io.write32(io.context, r.os, 1));
    try t.expectError(error.Denied, io.admit(io.context, .core_start));
    var hs_result: ?firmware_run.Result = null;
    for (0..128) |_| {
        hs_result = try port.stepFirmware();
        if (hs_result != null) break;
    }
    try t.expect(hs_result != null and hs_result.?.blocks == 4 and hs_result.?.mailboxes[0].? == 0x79 and hs_result.?.mailboxes[1] == null);
    try t.expect(hs_result.?.fwsec == null);
    try t.expectEqual(@as(u32, 1), fixture.hs_admissions);
    try t.expectEqual(@as(u32, 16), words[(hs.reg.gsp + hs.reg.second_offset + hs.reg.signature) / 4]);
    try t.expectEqual(@as(u32, 0x400), words[(hs.reg.gsp + hs.reg.second_offset + hs.reg.engine_mask) / 4]);
    try t.expectEqual(@as(u32, 9), words[(hs.reg.gsp + hs.reg.second_offset + hs.reg.ucode) / 4]);
    try t.expectEqual(@as(u32, 1), words[(hs.reg.gsp + hs.reg.second_offset + hs.reg.algorithm) / 4]);
    try t.expect(fixture.retains == 1 and !port.close() and fixture.unmaps == 0);
    // Same actual SDK/MMIO port retains the run through post-halt FWSEC
    // reads. Command results never mark the device quiescent or release it.
    const result_check = @import("fwsec_result.zig");
    checkpoint = "native-fwsec";
    for ([_]result_check.Command{ .sb, .{ .frts = 0x2ffee0000 } }) |command| {
        var fwsec_options = hs_options;
        fwsec_options.mailboxes = .{ null, null };
        fwsec_options.fwsec = command;
        const addresses = if (command == .frts) result_check.frts_registers else result_check.sb_registers;
        const expected: [3]u32 = if (command == .frts) .{ 0x0000ffff, 0x2fffdff, 0x2ffee09 } else .{ 1, 0xabcdefFF, 0xffff0000 };
        for (addresses, expected) |address, value| words[address / 4] = value;
        try port.beginFirmware(fwsec_options);
        hs_result = null;
        for (0..128) |_| {
            hs_result = try port.stepFirmware();
            if (hs_result != null) break;
        }
        try t.expect(hs_result != null and hs_result.?.fwsec != null);
        try t.expectEqualSlices(u32, &expected, &hs_result.?.fwsec.?.raw);
        if (command == .frts) fixture.frts_completed = true;
        try t.expect(fixture.retains == 1 and !port.close() and fixture.unmaps == 0);
    }
    // Cold preparation follows this port's checked FRTS result and uses the
    // run's original Libos address. SEC2 Booter Load remains a separate run.
    port.owner.?.admit_cold = NativeRig.admitCold;
    checkpoint = "native-cold-prepare";
    words[r.hwcfg2 / 4] = b.reset_ready | b.riscv_enabled;
    try port.beginColdBoot(.prepare, fixture.clock + 2 * std.time.ns_per_ms);
    try t.expectError(error.Busy, port.beginColdBoot(.prepare, fixture.clock + 2 * std.time.ns_per_ms));
    try t.expectError(error.Busy, port.beginFirmware(hs_options));
    try t.expectError(error.Busy, port.sequencer());
    try t.expectError(error.Busy, io.read32(io.context, r.os));
    try t.expectError(error.Busy, io.write32(io.context, r.os, 1));
    try t.expectError(error.Denied, io.admit(io.context, .core_start));
    for (0..128) |_| {
        if (try port.stepColdBoot()) break;
        fixture.clock += 10 * std.time.ns_per_us;
    }
    try t.expect(port.operation == null and port.cold_command == null and fixture.cold_admissions == 1);
    fixture.cold_prepared = true;
    try t.expectEqual(@as(u32, 0x111), words[r.bcr / 4]);
    try t.expectEqual(@as(u32, @truncate(args.libos_dma)), words[r.mailbox0 / 4]);
    try t.expectEqual(@as(u32, @truncate(args.libos_dma >> 32)), words[r.mailbox1 / 4]);
    try t.expect(fixture.logs_calls == 0 and fixture.retains == 1 and !port.close());
    const boot_check = @import("booter_result.zig");
    checkpoint = "native-booter";
    words[(hs.reg.sec2 + firmware_run.hwcfg_offset) / 4] = 0x20100;
    words[(hs.reg.sec2 + hs.reg.cpu_control) / 4] = b.alias | b.halted;
    for ([_]boot_check.Command{ .{ .normal_load = 0x123456000 }, .normal_unload }) |command| {
        var boot_options = sec_options;
        boot_options.booter = command;
        boot_options.mailboxes = try boot_check.arguments(command);
        boot_options.deadline = fixture.clock + 2 * std.time.ns_per_ms;
        words[boot_check.wpr_hi_register / 4] = 0x2fffff9;
        const prior_logs = fixture.logs_calls;
        if (command == .normal_load) {
            try t.expectError(error.Unsupported, port.beginFirmware(boot_options));
            port.owner.?.log_polling = NativeRig.logs;
        }
        try port.beginFirmware(boot_options);
        hs_result = null;
        for (0..192) |_| {
            hs_result = try port.stepFirmware();
            if (hs_result != null) break;
            // SEC2 leaves RESET_READY clear in this model. Advance the real
            // accessor clock so the documented hint wait can expire normally.
            fixture.clock += 10 * std.time.ns_per_us;
        }
        try t.expect(hs_result != null and hs_result.?.booter != null and !hs_result.?.booter.?.skipped);
        try t.expect(fixture.logs_enabled and fixture.logs_calls == prior_logs + 2);
        try t.expect(hs_result.?.mailboxes[0].? == 0 and hs_result.?.blocks == 4);
        try t.expect(fixture.retains == 1 and !port.close() and fixture.unmaps == 0);
        if (command == .normal_load) {
            fixture.load_completed = true; // The preceding actual-port result was checked.
            checkpoint = "native-cold-finish";
            const prior_flushes = fixture.flushes;
            try port.beginColdBoot(.finish, fixture.clock + 2 * std.time.ns_per_ms);
            try t.expect(!try port.stepColdBoot()); // Pure whole-stage admission.
            try t.expect(!try port.stepColdBoot()); // FALCON_OS only.
            try t.expect(try port.stepColdBoot()); // Actual-port ACTIVE observation.
            try t.expectEqual(args.app_version, words[r.os / 4]);
            // The fixture counts access-policy calls: one admission before
            // the OS write and one for its actual posted-write flush.
            try t.expect(fixture.flushes == prior_flushes + 2 and fixture.cold_admissions == 2);
            try t.expect(fixture.logs_calls == prior_logs + 2 and !port.close());
            checkpoint = "native-booter";
        }
        if (command == .normal_unload) {
            try t.expectEqual(@as(?u32, 0), hs_result.?.booter.?.wpr_hi_after);
            const flushes = fixture.flushes;
            try port.beginFirmware(boot_options);
            try t.expect((try port.stepFirmware()) == null);
            const skipped = (try port.stepFirmware()).?;
            try t.expect(skipped.booter.?.skipped and skipped.blocks == 0 and skipped.mailboxes[0] == null);
            try t.expect(fixture.logs_calls == prior_logs + 2 and fixture.flushes == flushes);
        }
    }
    // An invalid flush comes AFTER the write: preserve the actual effect and
    // keep the MMIO/DMA owner alive. Subsequent callbacks cannot write again.
    fixture.wrong_flush = true;
    checkpoint = "native-posted-cleanup";
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
    // Cold admission/late-failure paths use the same native mapping callbacks.
    // All quiescence flags below dispose host registers only; no GPU ran.
    for (0..7) |fault| {
        checkpoint = "native-cold-rejection";
        @memset(words, 0);
        words[0] = boot0;
        words[r.hwcfg2 / 4] = b.reset_ready | b.riscv_enabled;
        fixture = .{ .words = words, .frts_completed = fault >= 3, .wrong_flush = fault == 5, .cold_admission_timeout = fault == 6 };
        port = .{};
        var owner = fixture.owner();
        owner.admit_cold = NativeRig.admitCold;
        try port.open(&ctx, &snapshot, boot0, 0, .{ .epoch = 9, .deadline_ns = 10000000, .resume_args = if (fault == 0) null else args }, owner);
        if (fault == 0) {
            try t.expectError(error.BootArguments, port.beginColdBoot(.prepare, 1000000));
            try t.expect(fixture.cold_admissions == 0 and fixture.retains == 0 and port.operation == null);
        } else {
            try port.beginColdBoot(if (fault == 2) .finish else .prepare, 1000000);
            if (fault <= 2) {
                try t.expectError(error.Dependencies, port.stepColdBoot());
            } else if (fault == 3) {
                port.run.resume_args.?.libos_dma += 4096;
                try t.expectError(error.State, port.stepColdBoot());
            } else if (fault == 6) {
                try t.expectError(error.Deadline, port.stepColdBoot());
                try t.expect(!port.cold_admitted and fixture.retains == 0);
            } else {
                try t.expect(!try port.stepColdBoot()); // Admission is separate from effects.
                if (fault == 4) {
                    fixture.clock = 1000000;
                    try t.expectError(error.Deadline, port.stepColdBoot());
                } else {
                    try t.expect(!try port.stepColdBoot()); // Pre-reset observation.
                    try t.expectError(error.IdentityChanged, port.stepColdBoot()); // Posted reset write.
                }
            }
            try t.expect(port.operation != null and port.failure != null);
            try t.expectError(error.State, port.stepColdBoot());
            try t.expectEqual(@as(u32, if (fault == 5) 1 else 0), fixture.retains);
            if (fault == 5) {
                try t.expect(!port.close() and fixture.unmaps == 0 and port.operation.?.write_attempted);
                fixture.quiet = true;
            }
        }
        try t.expect(port.close() and !fixture.mapped and fixture.unmaps == 1);
    }
    checkpoint = "shared-bar0-lifetime";
    const bar0 = @import("bar0.zig");
    const chip = identity.chip(boot0, 0).?;
    @memset(words, 0);
    words[0] = boot0;
    fixture = .{ .words = words };
    var mapping: bar0.Owner = .{};
    defer _ = mapping.close();
    try mapping.open(&ctx, &snapshot, chip);
    var borrows: [bar0.max_borrowers]bar0.Lease = @splat(.{});
    for (&borrows) |*borrow| try borrow.acquire(&mapping, &ctx, &snapshot, chip);
    defer for (&borrows) |*borrow| { _ = borrow.release(); };
    var extra: bar0.Lease = .{};
    try t.expectError(error.Capacity, extra.acquire(&mapping, &ctx, &snapshot, chip));
    try t.expectError(error.Busy, borrows[0].acquire(&mapping, &ctx, &snapshot, chip));
    try t.expectError(error.Bounds, borrows[0].view(mapping.window.byte_length, 4));
    try t.expectError(error.Bounds, borrows[0].view(0, 0));
    const last = try borrows[0].view(mapping.window.byte_length - 4, 4);
    try t.expectEqual(@intFromPtr(words.ptr) + words.len * 4 - 4, last.cpu_address);
    var moved = borrows[0];
    try t.expect(!moved.valid() and !moved.release() and !mapping.close());
    mapping.window.handle.generation += 1;
    try t.expect(!borrows[0].valid() and !borrows[0].release() and !mapping.close());
    mapping.window.handle.generation -= 1;
    for (&borrows) |*borrow| try t.expect(borrow.release());
    var wrong = snapshot;
    wrong.pci.function += 1;
    try t.expectError(error.Stale, extra.acquire(&mapping, &ctx, &wrong, chip));
    wrong = snapshot;
    wrong.bars[0].bytes -= 4096;
    try t.expectError(error.Stale, extra.acquire(&mapping, &ctx, &wrong, chip));
    var other_api = api;
    const other_ctx = r4os.r4dev.DriverContext.init(&other_api);
    try t.expectError(error.Stale, extra.acquire(&mapping, &other_ctx, &snapshot, chip));
    port = .{};
    try port.openShared(&ctx, &snapshot, boot0, 0, .{ .epoch = 9, .deadline_ns = 10000000 }, fixture.owner(), &mapping);
    const shared_io = try port.sequencer();
    port.window.handle.generation += 1;
    try t.expectError(error.Stale, shared_io.read32(shared_io.context, 0));
    try t.expect(!port.close() and !mapping.close());
    port.window.handle.generation -= 1;
    try t.expect(port.close() and fixture.mapped and fixture.unmaps == 0);
    try port.openShared(&ctx, &snapshot, boot0, 0, .{ .epoch = 9, .deadline_ns = 10000000 }, fixture.owner(), &mapping);
    const effect_io = try port.sequencer();
    // Retention is exercised through an actual posted MMIO write. These
    // callbacks model host storage disposal, never real GPU quiescence.
    try effect_io.write32(effect_io.context, r.os, 0xaabb);
    try t.expect(!port.close() and !mapping.close() and fixture.unmaps == 0);
    fixture.quiet = true;
    try t.expect(port.close() and mapping.borrowedCount() == 0 and fixture.mapped and fixture.unmaps == 0);
    const serial = mapping.serial;
    fixture.fail_unmap = true;
    try t.expect(!mapping.close() and mapping.window.handle.id == 5);
    fixture.fail_unmap = false;
    fixture.fail_collect = true;
    try t.expect(!mapping.close() and !fixture.mapped and mapping.window.handle.id == 0);
    fixture.fail_collect = false;
    try t.expect(mapping.close() and mapping.serial == serial and mapping.close());
    // Partial or invalid mapping responses remain owned until cleanup; no
    // consumer receives a live view. Serial exhaustion cannot recycle a lease.
    for (0..2) |fault| {
        fixture = .{ .words = words, .partial_map = fault == 0, .wrong_map = fault == 1 };
        try t.expectError(error.Mapping, mapping.open(&ctx, &snapshot, chip));
        try t.expectError(error.Stale, extra.acquire(&mapping, &ctx, &snapshot, chip));
        try t.expect(mapping.close() and fixture.unmaps == 1);
    }
    fixture = .{ .words = words };
    mapping.serial = std.math.maxInt(u64);
    try mapping.open(&ctx, &snapshot, chip);
    try t.expectError(error.Exhausted, extra.acquire(&mapping, &ctx, &snapshot, chip));
    try t.expect(mapping.close() and mapping.serial == std.math.maxInt(u64));
}
