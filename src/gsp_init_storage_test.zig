const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const t = std.testing;
const init = @import("gsp_init.zig");
const radix = @import("gsp_radix.zig");
const Storage = @import("gsp_init_storage.zig").Storage;
const transport = @import("gsp_transport.zig");
const Fault = enum { none, allocation, pin_last, map_last, pin_header, map_header, direction, overlap, external_overlap, address, sync_last, timeout, regression, unmap, unpin, release, bounce };
var fault: Fault = .none;
var backing: ?[]align(4096) u8 = null;
var shadow: []u8 = undefined;
var pins: [7]bool = @splat(false);
var maps: [7]bool = @splat(false);
var pin_calls: usize = 0;
var sync_calls: usize = 0;
var close_calls: usize = 0;
var queries: usize = 0;
var closing = false;
var clock: u64 = 100;
var range_failure: i32 = 0;
var range_calls: usize = 0;
var range_failure_call: usize = 0;
const LogFault = enum { none, producer, timeout, regression, io };
var log_fault: LogFault = .none;
const offsets = [_]usize{ 0, 8192, 73728, 139264, 204800, 270336, 335872 };
const lengths = [_]usize{ 8192, 65536, 65536, 65536, 65536, 65536, 528384 };
fn address(index: usize) u64 {
    return 0x100000000 + index * 0x100000;
}
fn any(values: []const bool) bool {
    for (values) |value| if (value) return true;
    return false;
}
fn resources(out: *a.DriverResourceApi) callconv(.c) i32 {
    out.* = .{ .now_ns = @intFromPtr(&now) };
    return 0;
}
fn now() callconv(.c) u64 {
    return clock;
}
fn heap(out: *a.DriverHeapApi) callconv(.c) i32 {
    std.debug.assert(!closing);
    queries += 1;
    out.* = .{ .allocate = @intFromPtr(&allocate), .release = @intFromPtr(&release) };
    return 0;
}
fn allocate(bytes: u64, alignment: u32, out: *a.DriverHeapAllocation) callconv(.c) i32 {
    std.debug.assert(backing == null and bytes == 864256 and alignment == 4096);
    backing = t.allocator.alignedAlloc(u8, comptime std.mem.Alignment.fromByteUnits(4096), @intCast(bytes)) catch return -1;
    @memset(backing.?, 0xa5);
    out.* = .{ .handle = 0xe00000001, .cpu_address = @intFromPtr(backing.?.ptr), .byte_length = bytes, .alignment = 4096 };
    return if (fault == .allocation) -1 else 0;
}
fn release(handle: u64) callconv(.c) i32 {
    std.debug.assert(handle == 0xe00000001 and !any(&pins) and !any(&maps));
    close_calls += 1;
    if (fault == .release) return -1;
    t.allocator.free(backing.?);
    backing = null;
    return 0;
}
fn pin(cpu: u64, bytes: u32, flags: u32, out: *a.DmaPinnedBuffer) callconv(.c) i32 {
    const index = pin_calls;
    pin_calls += 1;
    std.debug.assert(index < 7 and !pins[index] and !maps[index] and flags == 0);
    std.debug.assert(cpu == @intFromPtr(backing.?.ptr) + offsets[index] and bytes == lengths[index]);
    pins[index] = true;
    out.* = .{ .handle = 0x1000 + index, .virt_addr = cpu, .bytes = bytes, .page_count = bytes / 4096 };
    if (fault == .pin_header and index == 3) out.version = 2;
    return if (fault == .pin_last and index == 6) -1 else 0; // Partial published pin.
}
fn map(pin_info: *const a.DmaPinnedBuffer, constraints: *const a.DmaConstraints, direction: u32, out: *a.DmaMapping) callconv(.c) i32 {
    const index = pin_info.handle - 0x1000;
    std.debug.assert(pins[index] and !maps[index]);
    std.debug.assert(direction == (if (index == 0) a.dma_direction_to_device else a.dma_direction_bidirectional));
    std.debug.assert(constraints.max_segments == (if (index == 6) @as(u32, 64) else 1));
    std.debug.assert(constraints.alignment == 4096 and constraints.dma_mask == radix.dma_mask and constraints.max_segment_bytes == lengths[index]);
    const source = backing.?[offsets[index]..][0..lengths[index]];
    std.debug.assert(std.mem.allEqual(u8, source, 0));
    maps[index] = true;
    out.* = .{ .handle = 0x2000 + index, .pin_handle = pin_info.handle, .requested_bytes = pin_info.bytes, .mapped_bytes = pin_info.bytes, .direction = direction, .flags = constraints.flags, .segment_count = if (index == 6) 3 else 1 };
    if (index < 6) {
        out.segments[0] = .{ .phys_addr = address(index), .bytes = pin_info.bytes };
    } else {
        out.segments[0] = .{ .phys_addr = address(6), .bytes = 4096 };
        out.segments[1] = .{ .phys_addr = 0x200000000, .bytes = 65536 };
        out.segments[2] = .{ .phys_addr = 0x300000000, .bytes = 112 * 4096 };
    }
    if (fault == .map_header and index == 3) out.segment_count = 2;
    if (fault == .direction and index == 6) out.direction = a.dma_direction_to_device;
    if (fault == .overlap and index == 4) out.segments[0].phys_addr = address(2) + 4096;
    if (fault == .external_overlap and index == 6) out.segments[2].phys_addr = 0x400000000;
    if (fault == .address and index == 0) out.segments[0].phys_addr = radix.dma_mask - 4095;
    if (fault == .bounce) {
        out.flags |= a.dma_mapping_flag_bounced;
        @memcpy(shadow[offsets[index]..][0..lengths[index]], source);
    }
    if (index == 6 and fault == .timeout) clock = 1100;
    if (index == 6 and fault == .regression) clock = 1;
    return if (fault == .map_last and index == 6) -1 else 0; // Partial mapping.
}
fn sync(mapping: *const a.DmaMapping) callconv(.c) i32 {
    const index = mapping.handle - 0x2000;
    std.debug.assert(maps[index] and pins[index] and index == sync_calls);
    if (index == 0) {
        std.debug.assert(std.mem.readInt(u64, backing.?[8..16], .little) == address(1));
        std.debug.assert(std.mem.readInt(u64, backing.?[4096..4104], .little) == address(6));
        std.debug.assert(std.mem.readInt(u64, backing.?[335872..335880], .little) == address(6));
        std.debug.assert(std.mem.allEqual(u8, backing.?[init.queues_offset + init.status_offset ..], 0));
    }
    if (fault == .bounce) @memcpy(shadow[offsets[index]..][0..lengths[index]], backing.?[offsets[index]..][0..lengths[index]]);
    sync_calls += 1;
    return if (fault == .sync_last and index == 6) -1 else 0;
}
fn unmap(mapping: *a.DmaMapping) callconv(.c) i32 {
    const index = mapping.handle - 0x2000;
    std.debug.assert(maps[index] and pins[index] and !any(maps[index + 1 ..]));
    close_calls += 1;
    if (fault == .unmap and index == 3) {
        mapping.* = .{};
        return -1;
    }
    maps[index] = false;
    mapping.* = .{};
    return 0;
}
fn unpin(pin_info: *a.DmaPinnedBuffer) callconv(.c) i32 {
    const index = pin_info.handle - 0x1000;
    std.debug.assert(pins[index] and !any(&maps) and !any(pins[index + 1 ..]));
    close_calls += 1;
    if (fault == .unpin and index == 3) {
        pin_info.* = .{};
        return -1;
    }
    pins[index] = false;
    pin_info.* = .{};
    return 0;
}

fn rangeSync(mapping: *const a.DmaMapping, offset: u32, bytes: u32, cpu: bool) i32 {
    const index = mapping.handle - 0x2000;
    std.debug.assert(index >= 1 and index <= 6 and maps[index] and pins[index]);
    std.debug.assert(bytes != 0 and bytes <= 65536 and offset <= lengths[index] - bytes);
    range_calls += 1;
    if (range_failure_call != 0 and range_calls == range_failure_call) return -31;
    if (range_failure != 0) return range_failure;
    const device = if (fault == .bounce) shadow else backing.?;
    if (index < 6) {
        std.debug.assert(cpu); // Log readers must never publish or acknowledge.
        if (log_fault == .io) return -31;
        if (offset != 0) switch (log_fault) {
            .producer => { const put = device[offsets[index]..][0..8]; std.mem.writeInt(u64, put, std.mem.readInt(u64, put, .little) + 1, .little); },
            .timeout => clock = 1000,
            .regression => clock = 1,
            .none => {},
            .io => unreachable,
        };
    }
    if (fault == .bounce) {
        const start = offsets[index] + offset;
        if (cpu) @memcpy(backing.?[start..][0..bytes], shadow[start..][0..bytes]) else @memcpy(shadow[start..][0..bytes], backing.?[start..][0..bytes]);
    }
    return 0;
}
fn rangeCpu(mapping: *const a.DmaMapping, offset: u32, bytes: u32) callconv(.c) i32 {
    return rangeSync(mapping, offset, bytes, true);
}
fn rangeDevice(mapping: *const a.DmaMapping, offset: u32, bytes: u32) callconv(.c) i32 {
    return rangeSync(mapping, offset, bytes, false);
}
fn apiTable() a.DriverApi {
    var table: a.DriverApi = undefined;
    table.magic = a.driver_magic;
    table.version = 34;
    table.size = @sizeOf(a.DriverApi);
    table.heap_query = heap;
    table.resource_query = resources;
    table.dma_pin_buffer = pin;
    table.dma_map_pinned = map;
    table.dma_sync_for_device = sync;
    table.dma_unmap = unmap;
    table.dma_unpin_buffer = unpin;
    table.dma_sync_range_for_device = rangeDevice;
    table.dma_sync_range_for_cpu = rangeCpu;
    return table;
}

// The real native port reads/writes aligned host memory through the ordinary
// DriverContext facade. This fixture supplies no hardware readiness proof.
const QueueNative = struct {
    const native = @import("gsp_sequencer_port.zig");
    const run = @import("gsp_run_memory.zig");
    // The DMA-sync failure is terminal for the shared run; exercise it last.
    const Case = enum { success, denied, retain_failure, posted_failure, late_write, lost_queue, runtime, runtime_missing, runtime_deny, runtime_late, runtime_idle_late, runtime_stale, runtime_seq, runtime_seq_deny, runtime_seq_timeout, runtime_seq_stale, runtime_seq_resume, runtime_seq_ack };
    memory: *run.Lease,
    words: []align(4096) u32,
    case: Case,
    mapped: bool = false,
    quiet: bool = false,
    retains: usize = 0,
    queue_accesses: usize = 0,
    flushes: usize = 0,
    runtime_admissions: usize = 0,
    log_calls: usize = 0,
    logs_enabled: bool = true,
    lockdown: bool = false,
    recovery_case: enum { success, skip, sb_error, unload_error, timeout, dma_timeout, clock_regression, stale, mapping, mmio, plan, posted, denied } = .success,
    recovery_epoch: u64 = 0,
    recovery_writes: usize = 0,
    sec_writes: usize = 0,
    recovery_admissions: usize = 0,
    fn from(p: *anyopaque) *QueueNative {
        return @ptrCast(@alignCast(p));
    }
    fn generation(p: *anyopaque) u64 {
        return from(p).memory.generation();
    }
    fn admit(_: *anyopaque, _: @import("gsp_sequencer.zig").Command) error{ Denied, Unsupported }!void {}
    fn access(p: *anyopaque, kind: native.Access, address_value: u32) anyerror!void {
        const self = from(p);
        const command = init.queues_offset + init.command_offset;
        const cursor = std.mem.readInt(u32, backing.?[command + 16 ..][0..4], .little);
        if (kind == .write and address_value == 0x110c00) {
            self.queue_accesses += 1;
            if (self.case == .denied or self.lockdown) return error.Denied;
            if (cursor != 0) {
                try t.expect(self.memory.retained and self.retains == 1);
                const record = try transport.message.decode(.{ .chip_id = 0x176 }, backing.?[command + 4096 ..][0..4096], 0);
                try t.expectEqualStrings("native queue fixture", record.payload);
                // After commandAdmission, during the last queue-only admission:
                // the native run lasts longer than this individual request.
                if (self.case == .late_write and self.queue_accesses == 4) clock = 500;
            }
        }
        if (kind == .read and address_value == 0 and self.words[0x110c00 / 4] == 0) {
            self.flushes += 1;
            if (self.case == .posted_failure) self.words[0] = 0;
        }
    }
    fn retain(p: *anyopaque) anyerror!void {
        const self = from(p);
        try t.expect(self.memory.retained);
        self.retains += 1;
        if (self.case == .retain_failure) return error.Retain;
    }
    fn quiesced(p: *anyopaque) bool {
        return from(p).quiet;
    }
    fn admitCommand(p: *anyopaque, port: *const native.Port, deadline: u64) !void {
        try t.expect(port.owner.?.context == p and deadline > clock);
        try access(p, .write, native.command_queue_head);
    }
    fn owner(self: *QueueNative) native.Owner {
        return .{ .context = self, .generation = generation, .admit = admit, .access = access, .retain = retain, .quiesced = quiesced, .queue_memory = self.memory, .admit_runtime = if (self.case == .runtime_missing) null else admitRuntime, .admit_command = admitCommand, .log_polling = if (self.case == .runtime_seq_resume) logPolling else null };
    }
    fn recoveryGeneration(p: *anyopaque) u64 { return from(p).recovery_epoch; }
    fn recoveryAdmit(p: *anyopaque, port: *const native.Port) !void {
        const self = from(p);
        try t.expect(port.failure.? == error.Deadline and self.memory.retained);
        self.recovery_admissions += 1;
        if (self.recovery_case == .denied) return error.Dependencies;
    }
    fn recoveryAccess(p: *anyopaque, kind: native.Access, address_value: u32) !void {
        const self = from(p);
        const hs = @import("falcon_hs.zig");
        const core = @import("gsp_core.zig");
        if (kind == .write) {
            self.recovery_writes += 1;
            if (address_value >= hs.reg.sec2 and address_value < hs.reg.sec2 + 0x2000) self.sec_writes += 1;
        }
        if (kind == .read and (address_value == hs.reg.gsp + hs.reg.dma_command or address_value == hs.reg.sec2 + hs.reg.dma_command)) {
            self.words[address_value / 4] = hs.bits.idle;
            if (self.recovery_case == .dma_timeout) clock = 100000000;
            if (self.recovery_case == .clock_regression) clock = 100;
        }
        if (kind == .read and address_value == core.reg.sec_mailbox0) {
            self.words[address_value / 4] = if (self.recovery_case == .unload_error) 7 else 0;
            self.words[0x1fa828 / 4] = 0;
        }
        if (self.recovery_case == .posted and kind == .read and address_value == 0 and self.recovery_writes != 0) self.words[0] = 0;
    }
    fn logPolling(p: *anyopaque, enable: bool) anyerror!void {
        const self = from(p);
        try t.expect(self.retains == 1 and self.memory.retained);
        self.log_calls += 1;
        self.logs_enabled = enable;
    }
    fn admitRuntime(p: *anyopaque, boot: *const @import("gsp_boot_events.zig").Boot) anyerror!void {
        const self = from(p);
        try t.expect(boot.state == .init_done and boot.pending == null and boot.session.pending == null);
        try t.expect(boot.session.epoch == self.memory.generation() and self.memory.retained);
        self.runtime_admissions += 1;
        if (self.case == .runtime_deny) return error.Dependencies;
        if (self.case == .runtime_late) clock = boot.deadline;
    }
    fn query(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = .{ .mmio_map = @intFromPtr(&mapWindow), .mmio_unmap = @intFromPtr(&unmapWindow), .collect = @intFromPtr(&collect) };
        return a.gfx_buffer_result_ok;
    }
    fn mapWindow(request: *const a.GfxMmioRequest, out: *a.GfxMmioWindow) callconv(.c) i32 {
        std.debug.assert(!queue_native.mapped and request.byte_length == queue_native.words.len * 4);
        queue_native.mapped = true;
        out.* = .{ .handle = .{ .id = 5, .generation = 8 }, .cpu_address = @intFromPtr(queue_native.words.ptr), .physical_address = request.resource_base, .byte_length = request.byte_length, .cache_policy = a.gfx_buffer_cache_uncached };
        return a.gfx_buffer_result_ok;
    }
    fn unmapWindow(_: *const a.GfxBufferHandle, quiet: u32) callconv(.c) i32 {
        std.debug.assert(queue_native.mapped and quiet == 1);
        queue_native.mapped = false;
        return a.gfx_buffer_result_ok;
    }
    fn collect() callconv(.c) i32 {
        return a.gfx_buffer_result_ok;
    }
};
var queue_native: *QueueNative = undefined;

fn checkNativeTeardown(memory: *@import("gsp_run_memory.zig").Lease, ctx: *const r4os.r4dev.DriverContext, table: *a.DriverApi) !void {
    const teardown = @import("gsp_teardown.zig");
    const native = QueueNative.native;
    const core = @import("gsp_core.zig");
    const hs = @import("falcon_hs.zig");
    const identity = @import("identity.zig");
    const words = try t.allocator.alignedAlloc(u32, comptime std.mem.Alignment.fromByteUnits(4096), 0x842000 / 4);
    defer t.allocator.free(words);
    table.gfx_memory_query = QueueNative.query;
    var snapshot: identity.Snapshot = .{ .pci = .{ .vendor_id = 0x10de, .device_id = 0x2504, .class_code = 3 }, .command = 2 };
    snapshot.bars[0] = .{ .kind = .memory32, .base = 0xfb000000, .bytes = words.len * 4 };
    for (std.enums.values(@FieldType(QueueNative, "recovery_case"))) |case| {
        errdefer |err| std.debug.print("native teardown fixture {s}: {s}\n", .{ @tagName(case), @errorName(err) });
        clock = 100;
        @memset(words, 0);
        words[0] = 0xb76000a1;
        for ([_]u32{ hs.reg.gsp, hs.reg.sec2 }) |base| {
            words[(base + 0xf4) / 4] = core.bits.reset_ready;
            words[(base + 0x108) / 4] = 0x20100;
            words[(base + hs.reg.cpu_control) / 4] = hs.bits.cpu_alias | hs.bits.cpu_halted;
        }
        words[0x118128 / 4] = 1;
        words[0x118234 / 4] = 0xff;
        words[0x1454 / 4] = if (case == .sb_error) 1 else 0;
        words[0x1fa828 / 4] = if (case == .skip) 0 else 0x500000;
        var fixture: QueueNative = .{ .memory = memory, .words = words, .case = .success,
            .recovery_case = case, .recovery_epoch = memory.generation() };
        queue_native = &fixture;
        var port: native.Port = .{};
        var owner = fixture.owner();
        owner.recovery = .{ .generation = QueueNative.recoveryGeneration, .admit = QueueNative.recoveryAdmit, .access = QueueNative.recoveryAccess };
        try port.open(ctx, &snapshot, words[0], 0, .{ .epoch = memory.generation(), .deadline_ns = 1000 }, owner);
        const old_port = try port.transportPort();
        const old_leaf = memory.queue.port();
        var reader: @import("gsp_logs.zig").Reader = .{};
        try reader.open(memory);
        try memory.retainForDevice();
        port.retained = true;
        port.effects_possible = true;
        port.failure = error.Deadline; // Retain the actual prior failure.
        memory.invalidate(); // Recovery must tolerate a failed transport.
        clock = 2000; // The old boot budget has expired.
        var recovery: teardown.Recovery = .{};
        if (case == .denied) {
            try t.expectError(error.Dependencies, recovery.open(&port, &reader, 100000000));
            try t.expect(port.phase == .boot and memory.recovery_owner == 0 and fixture.recovery_writes == 0);
        } else {
            try recovery.open(&port, &reader, 100000000);
            try t.expect(port.phase == .recovery and memory.recovery_owner == @intFromPtr(&recovery));
            try t.expect(!reader.enabled and port.failure.? == error.Deadline and memory.failed and memory.queue.failed);
            try t.expectEqual(@as(u64, 0), old_port.generation(old_port.context));
            var output: [8]u8 = undefined;
            try t.expectError(error.Phase, old_port.read(old_port.context, 100000000, .status, 0, &output));
            try t.expectError(error.QueueClosed, old_leaf.read(old_leaf.context, 100000000, .status, 0, &output));
            try t.expectError(error.Stale, reader.setPolling(true));
            try t.expectError(error.Busy, port.beginRecovery(@intFromPtr(&recovery), 200000000));
            var copy = recovery;
            try t.expectError(error.State, copy.step());
            try t.expect(port.recovery_failure == null);
            if (case == .timeout) clock = 100000000;
            if (case == .stale) fixture.recovery_epoch += 1;
            if (case == .mapping) memory.boot_storage.?.mapping.handle += 1;
            if (case == .mmio) port.window.handle.generation += 1;
            if (case == .plan) memory.fwsec_sb_storage.?.device.prepared_plan.?.ucode_id += 1;
            const result: ?anyerror = blk: {
                for (0..10000) |_| {
                    const done = recovery.step() catch |err| break :blk err;
                    if (done) break :blk null;
                    clock += 1000;
                }
                return error.Unbounded;
            };
            switch (case) {
                .success, .skip => {
                    try t.expect(result == null and recovery.report != null and recovery.phase == .complete);
                    try t.expectEqual(case == .skip, recovery.report.?.unload.booter.?.skipped);
                    try t.expect(recovery.report.?.sb.fwsec.?.command == .sb and !reader.enabled);
                    try t.expect((fixture.sec_writes == 0) == (case == .skip));
                },
                .sb_error, .unload_error, .timeout, .dma_timeout, .clock_regression, .stale, .mapping, .mmio, .plan, .posted => {
                    try t.expectEqual(@as(?anyerror, switch (case) {
                        .sb_error => error.SbError, .unload_error => error.BooterError,
                        .timeout, .dma_timeout => error.Deadline, .clock_regression => error.Clock,
                        .stale, .mapping, .mmio => error.Stale, .plan => error.Binding,
                        .posted => error.IdentityChanged, else => unreachable,
                    }), result);
                    const writes = fixture.recovery_writes;
                    try t.expectError(error.State, recovery.step());
                    try t.expect(recovery.report == null and writes == fixture.recovery_writes);
                    if (case == .sb_error) try t.expect(fixture.sec_writes == 0);
                },
                .denied => unreachable,
            }
            if (case == .mapping) memory.boot_storage.?.mapping.handle -= 1;
            if (case == .mmio) port.window.handle.generation -= 1;
            if (case == .plan) memory.fwsec_sb_storage.?.device.prepared_plan.?.ucode_id -= 1;
            try t.expect(fixture.recovery_admissions == 1 and port.failure.? == error.Deadline);
        }
        try t.expect(!port.close() and !memory.releaseBeforeSubmission() and !memory.init_storage.?.close());
        try t.expect(reader.close());
        // Host-only register model disposal. There is no production API for
        // declaring quiescence, releasing a submitted run or retrying it.
        port.recovery_owner = 0;
        fixture.quiet = true;
        try t.expect(port.close());
        memory.recovery_owner = 0;
        memory.failed = false;
        memory.queue.failed = false;
        memory.retained = false;
        memory.init_storage.?.device_access = false;
        try t.expect(fixture.mapped == false and close_calls == 0);
    }
    clock = 100;
}

fn checkNativeQueue(memory: *@import("gsp_run_memory.zig").Lease, ctx: *const r4os.r4dev.DriverContext, table: *a.DriverApi) !void {
    const native = QueueNative.native;
    const identity = @import("identity.zig");
    const words = try t.allocator.alignedAlloc(u32, comptime std.mem.Alignment.fromByteUnits(4096), 0x842000 / 4);
    defer t.allocator.free(words);
    const tx = try t.allocator.create([transport.message.max_bytes]u8);
    defer t.allocator.destroy(tx);
    const rx = try t.allocator.create([transport.message.max_bytes]u8);
    defer t.allocator.destroy(rx);
    table.gfx_memory_query = QueueNative.query;
    var snapshot: identity.Snapshot = .{ .pci = .{ .vendor_id = 0x10de, .device_id = 0x2504, .class_code = 3 }, .command = 2 };
    snapshot.bars[0] = .{ .kind = .memory32, .base = 0xfb000000, .bytes = words.len * 4 };
    const epoch = memory.generation();
    const command = init.queues_offset + init.command_offset;
    const status = init.queues_offset + init.status_offset;
    const header: [32]u8 = backing.?[command..][0..32].*;
    for (std.enums.values(QueueNative.Case)) |case| {
        errdefer |err| std.debug.print("native queue fixture {s}: {s}\n", .{ @tagName(case), @errorName(err) });
        clock = 100;
        @memset(words, 0);
        words[0] = 0xb76000a1;
        words[0x110c00 / 4] = 0xaabbccdd; // Observable host-only register sentinel.
        @memset(backing.?[command..][0..init.queue_bytes], 0);
        @memset(backing.?[status..][0..init.queue_bytes], 0);
        @memcpy(backing.?[command..][0..32], &header);
        @memcpy(backing.?[status..][0..32], &header);
        std.mem.writeInt(u32, backing.?[status + 24 ..][0..4], 64, .little);
        var fixture: QueueNative = .{ .memory = memory, .words = words, .case = case };
        queue_native = &fixture;
        var port: native.Port = .{};
        const run: native.Run = .{ .epoch = epoch, .deadline_ns = 1000, .resume_args = if (case == .runtime_seq_resume) .{ .libos_dma = address(0), .app_version = 7 } else null };
        if (case == .success) {
            var other = table.*;
            const wrong_ctx = r4os.r4dev.DriverContext.init(&other);
            try t.expectError(error.Stale, port.open(&wrong_ctx, &snapshot, words[0], 0, run, fixture.owner()));
            var wrong_run = run;
            wrong_run.epoch += 1;
            try t.expectError(error.Stale, port.open(ctx, &snapshot, words[0], 0, wrong_run, fixture.owner()));
            var absent = fixture.owner();
            absent.queue_memory = null;
            try port.open(ctx, &snapshot, words[0], 0, run, absent);
            try t.expectError(error.Unsupported, port.transportPort());
            try t.expect(fixture.retains == 0 and port.close());
        }
        try port.open(ctx, &snapshot, words[0], 0, run, fixture.owner());
        const io = try port.transportPort();
        var session = try transport.Session.init(io, .{ .chip_id = 0x176 }, epoch, tx, rx);
        const runtime_case = @intFromEnum(case) >= @intFromEnum(QueueNative.Case.runtime);
        if (!runtime_case) try session.connect(500);
        if (runtime_case) {
            try checkRuntimeHandoff(&port, &session, &fixture);
        } else if (case == .lost_queue) {
            memory.boot_storage.?.mapping.handle += 1;
            const calls = range_calls;
            try t.expectError(error.Stale, session.send(500, .{ .function = 79 }, "native queue fixture"));
            try t.expect(range_calls == calls and words[0x110c00 / 4] == 0xaabbccdd);
            memory.boot_storage.?.mapping.handle -= 1; // Restore injected descriptor corruption.
        } else if (case == .success) {
            try session.send(500, .{ .function = 79 }, "native queue fixture");
            try t.expect(words[0x110c00 / 4] == 0 and fixture.flushes == 1);
            try t.expect(memory.retained and port.effects_possible and fixture.retains == 1);
            words[0x110c00 / 4] = 0xaabbccdd;
            _ = try transport.message.encode(.{ .chip_id = 0x176 }, 0, .{ .function = 0x1003 }, "notify", backing.?[status + 4096 ..][0..4096]);
            std.mem.writeInt(u32, backing.?[status + 16 ..][0..4], 1, .little);
            const received = (try session.receive(500)).?;
            try session.acknowledge(500, received.ticket);
            try t.expect(words[0x110c00 / 4] == 0xaabbccdd and fixture.flushes == 1);
        } else {
            try t.expectError(error.Io, session.send(500, .{ .function = 79 }, "native queue fixture"));
            const published = case == .posted_failure or case == .late_write;
            try t.expectEqual(@as(u32, if (published) 1 else 0), std.mem.readInt(u32, backing.?[command + 16 ..][0..4], .little));
            try t.expectEqual(@as(u32, if (case == .posted_failure) 0 else 0xaabbccdd), words[0x110c00 / 4]);
            try t.expectEqual(switch (case) {
                .denied => error.Denied,
                .retain_failure => error.Retain,
                .posted_failure => error.IdentityChanged,
                .late_write => error.Deadline,
                else => unreachable,
            }, session.last_io_error.?);
            const calls = range_calls;
            const accesses = fixture.queue_accesses;
            try t.expectError(error.State, session.send(900, .{ .function = 79 }, "retry"));
            try t.expect(range_calls == calls and fixture.queue_accesses == accesses);
        }
        if (port.effects_possible) try t.expect(!port.close() and fixture.mapped);
        fixture.quiet = true; // Host fixture disposal only, no GPU was run.
        try t.expect(port.close() and !fixture.mapped);
        try t.expectEqual(@as(u64, 0), io.generation(io.context));
    }
    clock = 100;
}

fn nativeEvent(session: *transport.Session, function: u32, payload: []const u8) !void {
    try t.expect(session.pending == null and payload.len < 4000);
    const status = init.queues_offset + init.status_offset;
    const cursor = std.mem.readInt(u32, backing.?[status + 16 ..][0..4], .little);
    const start = status + 4096 + @as(usize, cursor) * 4096;
    _ = try transport.message.encode(session.profile, session.rx_sequence, .{ .function = function, .result = 0 }, payload, backing.?[start..][0..4096]);
    std.mem.writeInt(u32, backing.?[status + 16 ..][0..4], (cursor + 1) % 63, .little);
}

fn checkRuntimeHandoff(port: *QueueNative.native.Port, session: *transport.Session, fixture: *QueueNative) !void {
    const events = @import("gsp_boot_events.zig");
    const exchange = @import("gsp_exchange.zig");
    const native = QueueNative.native;
    const legacy = try port.sequencer();
    const command = init.queues_offset + init.command_offset;
    var boot = try events.Boot.init(session, 500);
    try t.expectError(error.State, port.handoffBoot(&boot));
    try t.expect((try boot.poll()) == null);
    // The successful runtime retains an engaged lockdown through the handoff.
    if (fixture.case == .runtime) {
        try nativeEvent(session, 0x101c, &.{1});
        const notice = (try boot.poll()).?;
        fixture.lockdown = true;
        try boot.complete(notice.ticket);
    }
    try nativeEvent(session, 0x1001, &.{ 0, 0, 0, 0 });
    const init_done = (try boot.poll()).?;
    try t.expect(init_done.event == .init_done);
    try t.expectError(error.State, port.handoffBoot(&boot)); // Not yet ACKed.
    try t.expectEqual(@as(usize, 0), fixture.runtime_admissions);
    try boot.complete(init_done.ticket);
    try t.expect(fixture.retains == 1 and fixture.memory.retained and port.effects_possible);
    // Same epoch alone does not identify the native queue/notification port.
    const saved = session.port;
    session.port = try fixture.memory.transportPort();
    try t.expectError(error.Binding, port.handoffBoot(&boot));
    session.port = saved;
    try t.expect(boot.state == .init_done and port.phase == .boot and port.failure == null);
    if (fixture.case == .runtime_missing) {
        try t.expectError(error.Unsupported, port.handoffBoot(&boot));
        try t.expect(boot.state == .init_done and port.phase == .boot and fixture.runtime_admissions == 0);
        return;
    }
    if (fixture.case == .runtime_idle_late) {
        clock = 500;
        try t.expectError(error.Deadline, port.handoffBoot(&boot));
        try t.expect(boot.state == .init_done and port.phase == .boot and fixture.runtime_admissions == 0);
        return;
    }
    if (fixture.case == .runtime_deny or fixture.case == .runtime_late) {
        try t.expectError(if (fixture.case == .runtime_deny) error.Dependencies else error.Deadline, port.handoffBoot(&boot));
        try t.expect(boot.state == .init_done and port.phase == .boot and fixture.runtime_admissions == 1);
        try t.expect(port.failure != null and port.runtime_session == null);
        try t.expectError(error.State, port.handoffBoot(&boot));
        try t.expectEqual(@as(usize, 1), fixture.runtime_admissions);
        return;
    }
    const window = port.window;
    const epoch = fixture.memory.generation();
    var token = try port.handoffBoot(&boot);
    try t.expectEqualDeep(window, port.window);
    try t.expectEqual(epoch, fixture.memory.generation());
    try t.expect(boot.state == .handed_off and token.session == session and !token.claimed);
    try t.expect(port.phase == .runtime and port.runtime_session == session and port.run.deadline_ns == 1000);
    try t.expectEqual(@as(usize, 1), fixture.runtime_admissions);
    var channel = try exchange.Exchange.init(&token, 2000);
    // Old boot callbacks cannot affect the transferred runtime or reset cores.
    try t.expectError(error.Phase, port.handoffBoot(&boot));
    try t.expectError(error.State, boot.poll());
    try t.expectError(error.Phase, port.transportPort());
    try t.expectError(error.Phase, legacy.read32(legacy.context, 0));
    try t.expectError(error.Phase, legacy.write32(legacy.context, native.command_queue_head, 0));
    try t.expectError(error.Phase, port.stepFirmware());
    try t.expectError(error.Phase, port.stepColdBoot());
    try t.expect(port.failure == null and session.state == .active and fixture.retains == 1);
    clock = 1200; // Beyond BOTH old boot deadlines; runtime request still valid.
    if (@intFromEnum(fixture.case) >= @intFromEnum(QueueNative.Case.runtime_seq)) return checkNativeRuntimeSequencer(port, &channel, fixture);
    try channel.begin(79, "native queue fixture", 2000);
    if (fixture.case == .runtime_stale) {
        fixture.memory.boot_storage.?.mapping.handle += 1;
        const calls = range_calls;
        try t.expectError(error.Stale, channel.poll(2000));
        try t.expect(range_calls == calls and fixture.queue_accesses == 0);
        fixture.memory.boot_storage.?.mapping.handle -= 1; // Restore injected corruption.
        return;
    }
    try t.expect(channel.in_lockdown and token.in_lockdown);
    try t.expect((try channel.poll(2000)) == null);
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, backing.?[command + 16 ..][0..4], .little));
    try nativeEvent(session, 0x101c, &.{0});
    const unlock = (try channel.poll(2000)).?;
    try t.expect(!unlock.response and channel.in_lockdown and fixture.lockdown);
    try channel.complete(unlock.ticket);
    fixture.lockdown = false; // Actual host-model handler, only after successful ACK.
    try t.expect(!channel.in_lockdown and (try channel.poll(2000)) == null);
    try t.expectEqual(@as(u32, 1), session.tx_sequence);
    try t.expect(fixture.words[native.command_queue_head / 4] == 0 and fixture.flushes == 1);
    try nativeEvent(session, 79, "accepted fixture response");
    const response = (try channel.poll(2000)).?;
    try t.expect(response.response);
    try t.expectEqualStrings("accepted fixture response", response.record.payload);
    try channel.complete(response.ticket);
    try t.expect(session.pending == null and channel.phase == .idle and port.failure == null);
    // A new request owns a new finite budget; repeated polls cannot extend it.
    try channel.begin(80, "native queue fixture", 1500);
    clock = 1500;
    const calls = range_calls;
    const accesses = fixture.queue_accesses;
    try t.expectError(error.Deadline, channel.poll(9000));
    try t.expect(range_calls == calls and fixture.queue_accesses == accesses and session.state == .failed);
    const io = session.port;
    try t.expectEqual(@as(u64, 0), io.generation(io.context));
    try t.expectError(error.Stale, io.publish(io.context, 9000, .command, 16, &.{ 0, 0, 0, 0 }));
    try t.expectEqual(calls, range_calls); // Raw facade cannot revive a failed runtime.
}

fn checkNativeRuntimeSequencer(port: *QueueNative.native.Port, channel: *@import("gsp_exchange.zig").Exchange, fixture: *QueueNative) !void {
    const native = QueueNative.native;
    const seq = @import("gsp_sequencer.zig");
    const core = @import("gsp_core.zig");
    const session = channel.session;
    const limit = 20000;
    const limits: seq.Limits = .{ .register_bytes = port.window.byte_length, .default_timeout_ns = 5000, .poll_interval_ns = 100 };
    try channel.begin(79, "native queue fixture", limit);
    try t.expect((try channel.poll(limit)) == null); // An RM response is already outstanding.
    var execution: native.RuntimeSequencer = .{};
    try t.expectError(error.State, execution.begin(port, channel, limits)); // No notification yet.
    const words: []const u32 = switch (fixture.case) {
        .runtime_seq => &.{ 0, 0x1000, 0xa500, 1, 0x1000, 0xff, 0x10003, 4, 0x1000, 7, 2, 0x1004, 0xff, 0x79, 3, 0x600d, 3, 2, 6, 7 },
        .runtime_seq_deny => &.{ 0, 0x1000, 0x79, 8 },
        .runtime_seq_timeout => &.{ 0, 0x1000, 0x79, 2, 0x1004, 1, 1, 1, 0xbeef },
        .runtime_seq_stale => &.{ 0, 0x1000, 0x79, 6 },
        .runtime_seq_ack => &.{ 0, 0x1000, 0x79 },
        .runtime_seq_resume => &.{8},
        else => unreachable,
    };
    var bytes: [128]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], @intCast(words.len + 1), .little);
    std.mem.writeInt(u32, bytes[4..8], @intCast(words.len), .little);
    for (words, 0..) |value, index| std.mem.writeInt(u32, bytes[40 + index * 4 ..][0..4], value, .little);
    try nativeEvent(session, 0x1002, bytes[0 .. 40 + words.len * 4]);
    const dispatch = (try channel.poll(limit)).?;
    const cursor = session.link.?.status_read;
    const queue_offset: usize = if (cursor.queue == .command) init.command_offset else init.status_offset;
    const cursor_offset = init.queues_offset + queue_offset + cursor.offset;
    const before_ack = std.mem.readInt(u32, backing.?[cursor_offset..][0..4], .little);
    const ranges = range_calls;
    const accesses = fixture.queue_accesses;
    const flushes = fixture.flushes;
    if (fixture.case == .runtime_seq_deny) {
        try t.expectError(error.Unsupported, execution.begin(port, channel, limits));
        try t.expect(execution.failed and fixture.words[0x1000 / 4] == 0 and range_calls == ranges and fixture.flushes == flushes);
    } else {
        try execution.begin(port, channel, limits);
        try t.expect(fixture.words[0x1000 / 4] == 0 and range_calls == ranges and fixture.flushes == flushes);
        var concurrent: native.RuntimeSequencer = .{};
        try t.expectError(error.Busy, concurrent.begin(port, channel, limits));
        try t.expectError(error.Pending, channel.poll(limit));
        var scratch: [4]u8 = @splat(0);
        const io = session.port;
        try t.expectError(error.Busy, io.read(io.context, limit, cursor.queue, cursor.offset, &scratch));
        try t.expectError(error.Busy, io.publish(io.context, limit, cursor.queue, cursor.offset, &scratch));
        const notification = io.notification.?;
        try t.expectError(error.Busy, notification.prepare(notification.context, limit));
        try t.expectError(error.Busy, notification.submit(notification.context, limit));
        try t.expect(port.failure == null and range_calls == ranges and fixture.queue_accesses == accesses);
        try t.expect(!execution.close() and !port.close());
        switch (fixture.case) {
            .runtime_seq => {
                fixture.words[0x1004 / 4] = 0x79;
                fixture.words[core.reg.cpuctl / 4] = core.bits.alias | core.bits.halted;
                var steps: usize = 0;
                while (steps < 16) : (steps += 1) {
                    const progress = try execution.step();
                    if (progress == .complete) break;
                    try t.expectEqual(before_ack, std.mem.readInt(u32, backing.?[cursor_offset..][0..4], .little));
                    if (progress == .wait_until) clock = progress.wait_until;
                }
                try t.expect(steps < 16 and execution.complete and port.runtime_sequence == null);
                try t.expectEqual(@as(u32, 0x1a503), execution.execution.?.runner.saved[7]);
                try t.expectEqual(core.bits.start, fixture.words[core.reg.cpuctl_alias / 4]);
                try t.expectEqual(dispatch.ticket.next, std.mem.readInt(u32, backing.?[cursor_offset..][0..4], .little));
                try t.expect(channel.phase == .waiting and channel.function == 79 and channel.deadline == limit);
                try t.expectEqual(accesses, fixture.queue_accesses); // Event ACK never rings the command doorbell.
                const completed_ranges = range_calls;
                const completed_flushes = fixture.flushes;
                try t.expect((try execution.step()) == .complete);
                try t.expect(range_calls == completed_ranges and fixture.flushes == completed_flushes and execution.close());
                try nativeEvent(session, 79, "accepted fixture response");
                const response = (try channel.poll(limit)).?;
                try t.expect(response.response);
                try channel.complete(response.ticket);
                try t.expect(channel.phase == .idle and session.state == .active);
                // Display owns an additional semantic receipt. Native CPU
                // completion must release it as well as the shared exchange.
                const display_rpc = @import("gsp_display_rpc.zig");
                var token = try channel.handoff(limit);
                var display = try display_rpc.Channel.init(&token, .{ .epoch = session.epoch, .client = 0xc100, .display = 0xd073 }, limit);
                var display_execution: native.RuntimeSequencer = .{};
                try t.expectError(error.State, display_execution.beginDisplay(port, &display, limits));
                @memset(&bytes, 0);
                std.mem.writeInt(u32, bytes[0..4], 4, .little);
                std.mem.writeInt(u32, bytes[4..8], 3, .little);
                std.mem.writeInt(u32, bytes[44..48], 0x1000, .little);
                std.mem.writeInt(u32, bytes[48..52], 0x79, .little);
                try nativeEvent(session, 0x1002, bytes[0..52]);
                const notice = (try display.poll(limit)).?;
                try t.expect(notice.value == .notification);
                try display_execution.beginDisplay(port, &display, limits);
                try t.expect((try display_execution.step()) == .complete);
                try t.expect(fixture.words[0x1000 / 4] == 0x79 and display.pending == null and display.exchange.pending == null and session.pending == null);
                try t.expect(display_execution.close());
                const display_ranges = range_calls;
                var reclaimed = try display.handoff(limit);
                channel.* = try @import("gsp_exchange.zig").Exchange.init(&reclaimed, limit);
                try t.expect(range_calls == display_ranges and channel.phase == .idle and port.runtime_sequence == null);
                try t.expectEqual(accesses, fixture.queue_accesses);
                return;
            },
            .runtime_seq_timeout => {
                _ = try execution.step();
                _ = try execution.step();
                clock = execution.execution.?.runner.phase_deadline.?;
                try t.expectError(error.Timeout, execution.step());
                const failure = execution.execution.?.runner.failure.?;
                try t.expect(failure.vendor_error == 0xbeef and failure.word_index == 3 and failure.last_value == 0);
            },
            .runtime_seq_stale => {
                _ = try execution.step();
                fixture.memory.boot_storage.?.mapping.handle += 1;
                try t.expectError(error.Stale, execution.step());
                fixture.memory.boot_storage.?.mapping.handle -= 1; // Restore descriptor corruption, never revive execution.
            },
            .runtime_seq_ack => {
                range_failure = -9;
                defer range_failure = 0;
                try t.expectError(error.Io, execution.step());
                try t.expect(execution.execution.?.runner.state == .complete and !execution.execution.?.acknowledged);
            },
            .runtime_seq_resume => {
                try t.expect((try execution.step()) == .wait_until);
                try t.expect(fixture.log_calls == 1 and !fixture.logs_enabled);
                // The host register model reports no RISC-V engine. Keep the
                // suspended logs and resume phase; no cleanup-side re-enable.
                try t.expectError(error.Io, execution.step());
                try t.expect(execution.operation.?.logs_suspended);
                try t.expectEqual(error.Resume, execution.operation.?.failure.?);
            },
            else => unreachable,
        }
    }
    try t.expect(execution.failed and channel.phase == .failed and session.state == .failed and session.pending != null);
    if (fixture.case != .runtime_seq_ack) try t.expectEqual(before_ack, std.mem.readInt(u32, backing.?[cursor_offset..][0..4], .little));
    const failed_ranges = range_calls;
    const failed_flushes = fixture.flushes;
    try t.expectError(error.State, execution.step());
    try t.expect(range_calls == failed_ranges and fixture.flushes == failed_flushes and fixture.queue_accesses == accesses);
    try t.expect(!execution.close() and !port.close() and fixture.mapped and fixture.memory.retained);
    fixture.quiet = true; // Host-only disposal proof, not real hardware quiescence.
    try t.expect(!port.close()); // Even a quiet device cannot discard borrowed metadata first.
    try t.expect(execution.close() and range_calls == failed_ranges and fixture.flushes == failed_flushes);
    if (fixture.case == .runtime_seq_resume) try t.expect(fixture.log_calls == 1 and !fixture.logs_enabled);
    fixture.quiet = false;
}

const RangeNotification = struct {
    lease: *@import("gsp_init_storage.zig").QueueLease,
    calls: usize = 0,
    fn from(p: *anyopaque) *RangeNotification {
        return @ptrCast(@alignCast(p));
    }
    fn generation(p: *anyopaque) u64 {
        return from(p).lease.generation();
    }
    fn prepare(_: *anyopaque, _: u64) anyerror!void {} // Pure host queue fixture.
    fn submit(p: *anyopaque, _: u64) anyerror!void {
        const self = from(p);
        const device = if (fault == .bounce) shadow else backing.?;
        const command = init.queues_offset + init.command_offset;
        try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, device[command + 16 ..][0..4], .little));
        const record = try transport.message.decode(.{ .chip_id = 0x176 }, device[command + 4096 ..][0..4096], 0);
        try t.expectEqualStrings("real range facade", record.payload);
        self.calls += 1;
    }
};

fn fillRawLog(index: usize, next: u64) void {
    const logs = @import("gsp_logs.zig");
    const device = if (fault == .bounce) shadow else backing.?;
    const bytes = device[offsets[index + 1]..][0..init.log_bytes];
    const first = next - @min(next, logs.capacity);
    for (first..next) |word| std.mem.writeInt(u64, bytes[8 + (word % logs.capacity) * 8 ..][0..8], word ^ (@as(u64, index) << 48), .little);
    std.mem.writeInt(u64, bytes[0..8], next, .little);
}
fn checkLogReader(memory: *@import("gsp_run_memory.zig").Lease) !void {
    const logs = @import("gsp_logs.zig");
    const output = try t.allocator.alloc(u8, logs.output_bytes);
    defer t.allocator.free(output);
    shadow = try t.allocator.alloc(u8, init.output_bytes);
    defer t.allocator.free(shadow);
    for ([_]Fault{ .none, .bounce }) |kind| {
        fault = kind;
        @memcpy(shadow, backing.?);
        for (0..init.log_count) |index| fillRawLog(index, 0);
        var reader: logs.Reader = .{};
        try reader.open(memory);
        var other: logs.Reader = .{};
        try t.expectError(error.Busy, other.open(memory));
        var copy = reader;
        try t.expect(copy.generation() == 0 and !copy.close());
        try t.expect(!memory.releaseBeforeSubmission() and !memory.init_storage.?.close());
        const calls = range_calls;
        try t.expectError(error.LogRange, reader.capture(init.log_count, 1000, output));
        try t.expectError(error.LogRange, reader.capture(0, 1000, output[0..8]));
        try t.expectError(error.LogAlias, reader.capture(0, 1000, backing.?[0..logs.output_bytes]));
        const pack = memory.boot_storage.?.allocation;
        const aliased: [*]u8 = @ptrFromInt(pack.cpu_address);
        try t.expectError(error.LogAlias, reader.capture(0, 1000, aliased[0..logs.output_bytes]));
        try reader.setPolling(false);
        try t.expectError(error.Suspended, reader.capture(0, 1000, output));
        try t.expect(!memory.releaseBeforeSubmission());
        try reader.setPolling(true);
        reader.busy = true; // Serialized reentrancy simulation, no second task.
        try t.expectError(error.Busy, reader.capture(0, 1000, output));
        try t.expectError(error.Busy, reader.setPolling(false));
        try t.expect(!reader.close());
        reader.busy = false;
        try t.expectEqual(calls, range_calls);
        const mapping = &memory.init_storage.?.pieces[5].mapping;
        mapping.handle += 1;
        try t.expectError(error.Stale, reader.capture(0, 1000, output));
        try t.expect(!reader.close());
        mapping.handle -= 1;
        for (0..init.log_count) |index| {
            const empty = try reader.capture(index, 1000, output);
            try t.expect(empty.word_count == 0 and empty.next_word == 0 and empty.lost_words == 0);
            const put = 3 + index;
            fillRawLog(index, put);
            const observed = try reader.capture(index, 1000, output);
            try t.expect(observed.epoch == memory.generation() and observed.log == index and observed.first_word == 0 and observed.word_count == put);
            for (0..put) |word| try t.expectEqual(word ^ (@as(u64, index) << 48), std.mem.readInt(u64, output[word * 8 ..][0..8], .little));
            try t.expect((try reader.capture(index, 1000, output)).word_count == 0);
        }
        fillRawLog(0, logs.capacity + 7);
        const wrapped = try reader.capture(0, 1000, output);
        try t.expect(wrapped.first_word == 7 and wrapped.lost_words == 4 and wrapped.word_count == logs.capacity);
        for (0..wrapped.word_count) |word| try t.expectEqual(@as(u64, word + 7), std.mem.readInt(u64, output[word * 8 ..][0..8], .little));
        for ([_]LogFault{ .producer, .timeout, .regression }) |injection| {
            const prior = reader.previous[0];
            fillRawLog(0, prior + 4);
            log_fault = injection;
            @memset(output, 0x5a);
            const expected = switch (injection) { .producer => error.ProducerChanged, .timeout => error.Timeout, .regression => error.ClockRegression, .none, .io => unreachable };
            try t.expectError(expected, reader.capture(0, 1000, output));
            try t.expect(reader.previous[0] == prior and !reader.busy and !memory.failed);
            try t.expect(std.mem.allEqual(u8, output, 0));
            log_fault = .none;
            clock = 100;
            fillRawLog(0, prior + 4);
            try t.expect((try reader.capture(0, 1000, output)).word_count == 4);
        }
        const before_deadline = range_calls;
        try t.expectError(error.Timeout, reader.capture(0, 100, output));
        try t.expectError(error.InvalidDeadline, reader.capture(0, std.math.maxInt(u64), output));
        try t.expectEqual(before_deadline, range_calls);
        try t.expect(reader.close() and reader.close() and memory.log_owner == 0);
        try t.expectError(error.Stale, reader.capture(0, 1000, output));
    }
    fault = .none;
    // Counter overflow is not silently folded into a new producer epoch.
    var reader: logs.Reader = .{};
    try reader.open(memory);
    fillRawLog(0, std.math.maxInt(u64));
    const edge = try reader.capture(0, 1000, output);
    try t.expectEqual(std.math.maxInt(u64) - logs.capacity, edge.lost_words);
    fillRawLog(0, 1);
    try t.expectError(error.CounterRegression, reader.capture(0, 1000, output));
    try t.expect(memory.failed and reader.generation() == 0 and !memory.releaseBeforeSubmission());
    try reader.setPolling(false);
    try t.expectError(error.Stale, reader.setPolling(true));
    try t.expect(reader.close());
}
fn checkLogSyncFailure(memory: *@import("gsp_run_memory.zig").Lease) !void {
    const logs = @import("gsp_logs.zig");
    const output = try t.allocator.alloc(u8, logs.output_bytes);
    defer t.allocator.free(output);
    var reader: logs.Reader = .{};
    try reader.open(memory);
    range_failure = -123;
    try t.expectError(error.Synchronization, reader.capture(0, 1000, output));
    try t.expectEqual(@as(i32, -123), memory.last_log_status);
    try t.expect(reader.previous[0] == 0 and memory.failed and !memory.releaseBeforeSubmission());
    try t.expect(reader.close());
    try t.expectError(error.Stale, reader.open(memory));
    range_failure = 0;
}

test "firmware CPU storage complete run lease retains all boot DMA owners" {
    const run = @import("gsp_run_memory.zig");
    const boot_storage = @import("gsp_boot_storage.zig");
    const security = @import("fwsec_storage.zig");
    const booter = @import("booter.zig");
    const booters = @import("booter_storage.zig");
    var table = apiTable();
    var other_table = apiTable();
    const ctx = r4os.r4dev.DriverContext.init(&table);
    fault = .none;
    closing = false;
    clock = 100;
    pin_calls = 0;
    sync_calls = 0;
    close_calls = 0;
    queries = 0;
    range_calls = 0;
    range_failure = 0;
    var storage: Storage = .{};
    defer {
        closing = true;
        _ = storage.close();
    }
    const init_report = try storage.stage(&ctx, 0x176, &.{}, 1000);
    // The init queues use the real storage/SDK path above. The six other
    // already-admitted owners use descriptor fixtures. The boot pack has real
    // CPU metadata for live FRTS binding checks; no fabricated CPU pointer is
    // dereferenced. The capture/VRAM owner graph below is a host fixture, not
    // an actual display hold or GPU execution (covered by the lifecycle case).
    var b: boot_storage.Storage = .{ .context = ctx };
    b.image.context = ctx;
    b.image.piece_count = 1;
    b.image.allocation = .{ .handle = 101, .cpu_address = 0x100000, .byte_length = 4096 };
    b.allocation = .{ .handle = 102, .cpu_address = 0x110000, .byte_length = 32768 };
    b.image.report = .{ .root_address = 0x500000000, .image_bytes = 4096, .allocation_bytes = 4096, .table_bytes = 4096, .mappings = 1, .segments = 1, .bounced = 0 };
    b.report = .{ .image = b.image.report.?, .boot_address = 0x501000000, .signature_address = 0x501006000, .metadata_address = 0x501007000, .pack_bounced = false, .app_version = 0x79 };
    var f: security.Storage = .{ .complete = true, .allocation = .{ .handle = 103, .cpu_address = 0x120000, .byte_length = 65536 } };
    f.device.context = ctx;
    f.device.prepared_plan = .{ .imem = .{ .base = 0x502000000, .destination = 0, .source_offset = 0, .bytes = 4096, .command = 0x614 }, .dmem = .{ .base = 0x502001000, .destination = 0, .source_offset = 0, .bytes = 4096, .command = 0x600 }, .boot_vector = 0, .signature_address = 0, .engine_mask = 1, .ucode_id = 1 };
    for ([_]*a.DmaMapping{ &b.image.pieces[0].mapping, &b.mapping, &f.device.mapping }, 0..) |mapping, n| {
        mapping.* = .{ .handle = 201 + n, .pin_handle = 301 + n, .segment_count = 1 };
        mapping.segments[0] = .{ .phys_addr = 0x500000000 + n * 0x1000000, .bytes = 65536 };
    }
    var p: booters.Pair = .{ .api = ctx.api, .context = ctx.resources().?, .complete = true, .generation = 7 };
    for (&p.images, 0..) |*image, n| {
        const bytes: u32 = if (n == 0) 60416 else 40192;
        const code: u32 = if (n == 0) 35072 else 20224;
        image.allocation = .{ .handle = 104 + n, .cpu_address = 0x130000 + n * 65536, .byte_length = bytes };
        image.prepared = .{ .operation = @enumFromInt(n), .info = .{ .image_bytes = bytes, .code_offset = 256, .code_bytes = code, .data_offset = code + 256, .data_bytes = bytes - code - 256, .signature_offset = code + 272 }, .fuse_version = 1, .signature_index = 0 };
        image.device.context = ctx;
        image.device.mapping = .{ .handle = 204 + n, .pin_handle = 304 + n, .segment_count = 1 };
        image.device.mapping.segments[0] = .{ .phys_addr = 0x503000000 + n * 0x1000000, .bytes = bytes };
        image.device.prepared_plan = try booter.loadPlan(image.prepared.?, image.device.mapping.segments[0].phys_addr, bytes);
    }
    var s: security.Storage = .{ .complete = true, .allocation = .{ .handle = 106, .cpu_address = 0x150000, .byte_length = 65536 } };
    s.device.context = ctx;
    s.device.prepared_plan = f.device.prepared_plan;
    s.device.prepared_plan.?.imem.base = 0x505000000;
    s.device.prepared_plan.?.dmem.base = 0x505001000;
    s.device.prepared_plan.?.engine_mask = 0x400;
    s.device.prepared_plan.?.ucode_id = 9;
    s.device.mapping = .{ .handle = 206, .pin_handle = 306, .segment_count = 1 };
    s.device.mapping.segments[0] = .{ .phys_addr = 0x505000000, .bytes = 65536 };
    const wpr = @import("gsp_wpr.zig");
    const reservation = @import("boot_vram_lease.zig");
    const pack = try t.allocator.alloc(u8, boot_storage.pack_bytes);
    defer t.allocator.free(pack);
    @memset(pack, 0);
    const desc_fields = [_]u32{ 5, 20480, 2176, 22656, 16, 0, 0, 0, 0, 2048, 2048, 4096, 6144, 10496, 1, 0, 0, 0, 0, 24576, 0 };
    var descriptor: [84]u8 = undefined;
    for (desc_fields, 0..) |value, index| std.mem.writeInt(u32, descriptor[index * 4 ..][0..4], value, .little);
    var raw = @import("fwsec_test.zig").preflightFixture();
    raw.put(.bcr, 1);
    raw.put(.riscv_cpuctl, 0x10);
    const prepared = try wpr.prepare(&.{ .chip_id = 0x176, .raw = raw, .image_bytes = wpr.image_bytes, .descriptor = &descriptor, .signature_bytes = wpr.signature_bytes });
    @memcpy(pack[boot_storage.metadata_offset..][0..wpr.bytes], &prepared.unbound_template);
    b.allocation.cpu_address = @intFromPtr(pack.ptr);
    b.vram_plan = prepared.plan;
    b.pin.handle = b.mapping.pin_handle;
    var capture: @import("boot_vram.zig").Capture = .{ .context = ctx, .ready = true };
    capture.self_address = @intFromPtr(&capture);
    capture.boot.held_generation = 9;
    capture.scanout_original = .{ .instance_control = 9, .instance_address = 0x10 };
    // Explicit host-only retained mapping fixture for this DMA lifetime test.
    var boot_mapping: @import("boot_mapping.zig").Capture = .{ .parent = &capture, .epoch = 9, .ready = true };
    boot_mapping.self_address = @intFromPtr(&boot_mapping);
    capture.mapping_owner = boot_mapping.self_address;
    const context_bytes = try std.testing.allocator.alloc(u8, 65536);
    defer std.testing.allocator.free(context_bytes);
    var boot_context: @import("boot_context.zig").Capture = .{ .parent = &capture, .epoch = 9, .ready = true,
        .instance_active = true, .framebuffer_bytes = prepared.plan.fb_bytes, .span = .{ .address = 0x100000, .bytes = 65536 }, .reference = .{ .reference = .{ .id = 71, .generation = 1 } }, .map = .{ .lease = .{ .id = 72, .generation = 1 }, .cpu_address = @intFromPtr(context_bytes.ptr), .byte_length = context_bytes.len } };
    boot_context.stamp = boot_context.map;
    boot_context.self_address = @intFromPtr(&boot_context);
    capture.context_owner = boot_context.self_address;
    var held: reservation.Lease = .{ .display = &capture, .boot_mapping = &boot_mapping, .boot_context = &boot_context, .backing = &b, .epoch = 9, .serial = 7, .plan = prepared.plan, .allocation = b.allocation.handle, .cpu_address = b.allocation.cpu_address, .mapping = b.mapping.handle, .pin = b.pin.handle, .metadata_address = b.report.?.metadata_address };
    held.self_address = @intFromPtr(&held);
    capture.borrower = held.self_address;
    b.vram_owner = held.self_address;
    f.self_address = @intFromPtr(&f);
    f.frts_binding = try held.borrowFrts(f.self_address);
    var lease: run.Lease = .{};
    f.command = 0x15; // A bare FRTS command without a retained VRAM target is invalid.
    try t.expectError(error.Storage, lease.acquire(&ctx, &b, &storage, &f, &s, &p));
    f.frts_owner = &held;
    f.command = 0x19; // SB may not replace the boot FRTS image.
    try t.expectError(error.Storage, lease.acquire(&ctx, &b, &storage, &f, &s, &p));
    f.command = 0x15;
    try t.expectError(error.Storage, lease.acquire(&ctx, &b, &storage, &f, &f, &p));
    try t.expectError(error.Storage, lease.acquire(&ctx, &b, &storage, &s, &f, &p));
    var other_boot = b;
    try t.expectError(error.Storage, lease.acquire(&ctx, &other_boot, &storage, &f, &s, &p));
    s.command = 0x15;
    try t.expectError(error.Storage, lease.acquire(&ctx, &b, &storage, &f, &s, &p));
    s.command = 0x19;
    s.complete = false;
    try t.expectError(error.Storage, lease.acquire(&ctx, &b, &storage, &f, &s, &p));
    s.complete = true;
    s.device.context = r4os.r4dev.DriverContext.init(&other_table);
    try t.expectError(error.Storage, lease.acquire(&ctx, &b, &storage, &f, &s, &p));
    s.device.context = ctx;
    s.device.mapping.segments[0].phys_addr = f.device.mapping.segments[0].phys_addr;
    try t.expectError(error.Overlap, lease.acquire(&ctx, &b, &storage, &f, &s, &p));
    s.device.mapping.segments[0].phys_addr = 0x505000000;
    s.device.mapping.pin_handle = f.device.mapping.pin_handle;
    try t.expectError(error.Mapping, lease.acquire(&ctx, &b, &storage, &f, &s, &p));
    s.device.mapping.pin_handle = 306;
    f.device.context = r4os.r4dev.DriverContext.init(&other_table);
    try t.expectError(error.Storage, lease.acquire(&ctx, &b, &storage, &f, &s, &p));
    f.device.context = ctx;
    p.images[1].device.context = r4os.r4dev.DriverContext.init(&other_table);
    try t.expectError(error.Storage, lease.acquire(&ctx, &b, &storage, &f, &s, &p));
    p.images[1].device.context = ctx;
    p.complete = false;
    try t.expectError(error.Storage, lease.acquire(&ctx, &b, &storage, &f, &s, &p));
    p.complete = true;
    p.images[1].device.mapping.segments[0].phys_addr = p.images[0].device.mapping.segments[0].phys_addr;
    try t.expectError(error.Overlap, lease.acquire(&ctx, &b, &storage, &f, &s, &p));
    p.images[1].device.mapping.segments[0].phys_addr = 0x504000000;
    f.device.mapping.segments[0].phys_addr = address(0);
    try t.expectError(error.Overlap, lease.acquire(&ctx, &b, &storage, &f, &s, &p));
    f.device.mapping.segments[0].phys_addr = 0x502000000;
    s.allocation.cpu_address = f.allocation.cpu_address;
    try t.expectError(error.Overlap, lease.acquire(&ctx, &b, &storage, &f, &s, &p));
    s.allocation.cpu_address = 0x150000;
    try t.expectEqual(@as(usize, 0), range_calls);
    try t.expectEqual(@as(u64, 0), storage.queue_epoch);

    try lease.acquire(&ctx, &b, &storage, &f, &s, &p);
    const epoch = lease.generation();
    try t.expect(epoch != 0 and range_calls == 1);
    var moved = lease;
    try t.expectEqual(@as(u64, 0), moved.generation());
    try t.expect(!moved.releaseBeforeSubmission());
    var duplicate: run.Lease = .{};
    try t.expectError(error.Storage, duplicate.acquire(&ctx, &b, &storage, &f, &s, &p));
    try t.expect(!b.close() and !b.image.close() and !f.close() and !f.device.close() and !s.close() and !s.device.close() and !storage.close() and !p.close());
    try t.expect(f.complete and b.report != null and b.image.report != null and storage.report != null and close_calls == 0);
    const inputs = try lease.inputs();
    try t.expectEqual(@as(u32, 0x15), inputs.fwsec_command);
    try t.expect(held.validates(inputs.frts.?) and s.complete);
    try t.expectEqual(@as(usize, 7), lease.allocations.len);
    try t.expectEqual(@as(usize, 13), lease.mapped_count);
    try t.expectEqual(s.device.prepared_plan.?.imem.base, inputs.fwsec_sb.imem.base);
    for (&p.images, inputs.booters) |*image, binding| {
        try t.expectEqual(image.prepared.?.operation, binding.prepared.operation);
        try t.expectEqual(image.device.prepared_plan.?.imem.base, binding.plan.imem.base);
        try t.expect(!image.close() and !image.device.close());
        try t.expect(image.prepared != null);
    }
    try t.expectEqual(init_report.init.libos_address, inputs.resume_args.libos_dma);
    try t.expectEqual(@as(u32, 0x79), inputs.resume_args.app_version);
    try t.expectEqual(f.device.prepared_plan.?.imem.base, inputs.fwsec.imem.base);
    try checkDeviceStartup(&lease, &ctx, &table, &capture, &held);
    try checkNativeTeardown(&lease, &ctx, &table);
    try checkLogReader(&lease);
    try t.expect(lease.failed and lease.log_owner == 0);
    try t.expect(lease.releaseBeforeSubmission());
    try lease.acquire(&ctx, &b, &storage, &f, &s, &p);
    const port = try lease.transportPort();
    var bytes: [32]u8 = @splat(0x79);
    try port.read(port.context, 1000, .status, 0, &bytes);
    try t.expect(std.mem.allEqual(u8, &bytes, 0));
    const calls = range_calls;
    b.mapping.handle += 1;
    try t.expectEqual(@as(u64, 0), port.generation(port.context));
    try t.expectError(error.Stale, port.read(port.context, 1000, .status, 0, &bytes));
    try t.expect(!lease.releaseBeforeSubmission() and range_calls == calls);
    b.mapping.handle -= 1;
    p.images[1].device.mapping.pin_handle += 1;
    try t.expectEqual(@as(u64, 0), lease.generation());
    try t.expect(!lease.releaseBeforeSubmission() and !p.close());
    p.images[1].device.mapping.pin_handle -= 1; // Restore the model's injected descriptor corruption.
    s.device.mapping.pin_handle += 1;
    try t.expectEqual(@as(u64, 0), lease.generation());
    try t.expect(!lease.releaseBeforeSubmission() and !s.close());
    s.device.mapping.pin_handle -= 1;
    s.command = 0x15;
    try t.expectEqual(@as(u64, 0), lease.generation());
    try t.expect(!lease.releaseBeforeSubmission() and !s.close());
    s.command = 0x19;
    try checkNativeQueue(&lease, &ctx, &table);
    try t.expect(lease.retained and lease.failed and lease.queue.failed);
    try t.expectError(error.Stale, lease.retainForDevice()); // The last ACK's DMA error cannot be revived.
    lease.invalidate();
    try t.expectEqual(@as(u64, 0), port.generation(port.context));
    try t.expect(!lease.releaseBeforeSubmission());
    try t.expect(!b.close() and !b.image.close() and !f.close() and !f.device.close() and !s.close() and !s.device.close() and !storage.close() and !p.close());
    try t.expect(close_calls == 0 and any(&maps) and any(&pins));
    // Fixture disposal only: there is deliberately no production clear API
    // until an actual native quiescence implementation can supply evidence.
    lease.retained = false;
    storage.device_access = false;
    try t.expect(lease.releaseBeforeSubmission());
    try t.expectEqual(@as(u64, 0), port.generation(port.context));
    try t.expect(b.execution_owner == 0 and b.image.execution_owner == 0 and f.device.execution_owner == 0 and s.device.execution_owner == 0 and storage.execution_owner == 0 and p.images[0].device.execution_owner == 0 and p.images[1].device.execution_owner == 0);
    try lease.acquire(&ctx, &b, &storage, &f, &s, &p);
    try t.expect(lease.generation() != epoch);
    try checkLogSyncFailure(&lease);
    try t.expect(lease.releaseBeforeSubmission());
    try lease.acquire(&ctx, &b, &storage, &f, &s, &p);
    range_failure = -79;
    try t.expectError(error.Synchronization, port.read(port.context, 1000, .status, 0, &bytes));
    try t.expectEqual(@as(u64, 0), lease.generation());
    try t.expect(lease.releaseBeforeSubmission()); // No device submission.
    range_failure = 0;
    try t.expect(held.releaseFrtsBeforeSubmission(f.self_address, f.frts_binding.?));
    try t.expect(held.releaseBeforeSubmission());
    closing = true;
    try t.expect(storage.close());
    try t.expect(backing == null and !any(&maps) and !any(&pins));
}

test "firmware CPU storage GSP queue lease binds range I/O and retains all backing before device quiescence" {
    var table = apiTable();
    const ctx = r4os.r4dev.DriverContext.init(&table);
    shadow = try t.allocator.alloc(u8, init.output_bytes);
    defer t.allocator.free(shadow);
    const tx = try t.allocator.create([65536]u8);
    defer t.allocator.destroy(tx);
    const rx = try t.allocator.create([65536]u8);
    defer t.allocator.destroy(rx);
    for ([_]Fault{ .none, .bounce }) |case| {
        fault = case;
        closing = false;
        clock = 100;
        pin_calls = 0;
        sync_calls = 0;
        close_calls = 0;
        range_calls = 0;
        range_failure = 0;
        var storage: Storage = .{};
        _ = try storage.stage(&ctx, 0x176, &.{}, 1000);
        table.version = 33;
        try t.expectError(error.Api, storage.borrowQueues());
        table.version = 34;
        table.size = 640;
        try t.expectError(error.Api, storage.borrowQueues());
        table.size = @sizeOf(a.DriverApi);
        table.dma_sync_range_for_cpu = null;
        try t.expectError(error.Api, storage.borrowQueues());
        table.dma_sync_range_for_cpu = rangeCpu;
        table.dma_sync_range_for_device = null;
        try t.expectError(error.Api, storage.borrowQueues());
        table.dma_sync_range_for_device = rangeDevice;
        try t.expectEqual(@as(usize, 0), range_calls);
        range_failure = -1; // Real provider admission failure publishes no lease.
        try t.expectError(error.Synchronization, storage.borrowQueues());
        try t.expectEqual(@as(i32, -1), storage.last_queue_status);
        try t.expectEqual(@as(u64, 0), storage.queue_epoch);
        range_failure = 0;
        var lease = try storage.borrowQueues();
        const first_epoch = lease.generation();
        var old_copy = lease;
        try t.expect(first_epoch != 0);
        try t.expectError(error.Busy, storage.borrowQueues());
        try t.expect(!storage.close());
        try t.expect(storage.report != null and close_calls == 0 and any(&maps));
        try t.expect(lease.releaseBeforeSubmission());
        try t.expect(lease.releaseBeforeSubmission());
        lease = try storage.borrowQueues();
        try t.expect(lease.generation() != first_epoch);
        try t.expectEqual(@as(u64, 0), old_copy.generation());
        try t.expect(!old_copy.releaseBeforeSubmission());
        var port = lease.port();
        var notification: RangeNotification = .{ .lease = &lease };
        port.notification = .{ .context = &notification, .generation = RangeNotification.generation, .prepare = RangeNotification.prepare, .submit = RangeNotification.submit };
        var bytes: [80]u8 = @splat(0x5a);
        const calls = range_calls;
        try t.expectError(error.QueueRange, port.read(port.context, 1000, .status, init.queue_bytes, bytes[0..1]));
        try t.expectError(error.QueueRange, port.publish(port.context, 1000, .command, 0, bytes[0..0]));
        try t.expectError(error.QueueRange, port.read(port.context, 1000, .command, std.math.maxInt(usize), &bytes));
        try t.expectError(error.QueueAlias, port.read(port.context, 1000, .status, 0, backing.?[0..4]));
        try t.expectError(error.QueueAlias, port.publish(port.context, 1000, .command, 0, backing.?[0..4]));
        try t.expectEqual(calls, range_calls);
        const map_handle = storage.pieces[6].mapping.handle;
        storage.pieces[6].mapping.handle += 1;
        try t.expectEqual(@as(u64, 0), port.generation(port.context));
        try t.expectError(error.QueueClosed, port.read(port.context, 1000, .status, 0, &bytes));
        storage.pieces[6].mapping.handle = map_handle;
        const device = if (case == .bounce) shadow else backing.?;
        const command = init.queues_offset + init.command_offset;
        const status = init.queues_offset + init.status_offset;
        // CPU-owned test model only: publish the peer header/data without any
        // real GPU engine. The actual lease/SDK callback path performs every
        // range translation, copy and acknowledgement below.
        @memcpy(device[status..][0..32], device[command..][0..32]);
        std.mem.writeInt(u32, device[status + 24 ..][0..4], 64, .little);
        device[command + 36] = 0x83;
        const page_table_first = std.mem.readInt(u64, device[init.queues_offset..][0..8], .little);
        var session = try transport.Session.init(port, .{ .chip_id = 0x176 }, lease.generation(), tx, rx);
        try session.connect(1000);
        try session.send(1000, .{ .function = 79 }, "real range facade");
        try t.expectEqual(@as(usize, 1), notification.calls);
        const command_record = try transport.message.decode(.{ .chip_id = 0x176 }, device[command + 4096 ..][0..4096], 0);
        try t.expectEqualStrings("real range facade", command_record.payload);
        try t.expectEqual(@as(u8, 0x83), device[command + 36]);
        try t.expectEqual(page_table_first, std.mem.readInt(u64, device[init.queues_offset..][0..8], .little));
        _ = try transport.message.encode(.{ .chip_id = 0x176 }, 0, .{ .function = 0xf0000790 }, "reply", device[status + 4096 ..][0..4096]);
        std.mem.writeInt(u32, device[status + 16 ..][0..4], 1, .little);
        const received = (try session.receive(1000)).?;
        try t.expectEqualStrings("reply", received.record.payload);
        try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, device[command + 32 ..][0..4], .little));
        try t.expect(!storage.close());
        try session.acknowledge(1000, received.ticket);
        try t.expectEqual(@as(usize, 1), notification.calls);
        try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, device[command + 32 ..][0..4], .little));
        try t.expectEqual(@as(u8, 0x83), device[command + 36]);
        // Model-only latch test: there is intentionally no production clear
        // API until actual native quiescence has been implemented/verified.
        try t.expect(lease.retainForDevice());
        try t.expect(!lease.releaseBeforeSubmission());
        try t.expect(!storage.close());
        try t.expect(storage.report != null and close_calls == 0 and any(&maps) and any(&pins));
        storage.device_access = false; // Fixture only; no GPU ever submitted.
        range_failure = -123;
        @memset(&bytes, 0x5a);
        try t.expectError(error.Synchronization, port.read(port.context, 1000, .status, 0, &bytes));
        try t.expectEqual(@as(i32, -123), lease.last_status);
        try t.expect(std.mem.allEqual(u8, &bytes, 0x5a));
        try t.expect(!lease.retainForDevice());
        try t.expectError(error.QueueClosed, port.publish(port.context, 1000, .command, 16, bytes[0..4]));
        try t.expect(!storage.close());
        range_failure = 0;
        try t.expect(lease.releaseBeforeSubmission());
        try t.expectEqual(@as(u64, 0), port.generation(port.context));
        try t.expectError(error.QueueClosed, port.read(port.context, 1000, .status, 0, &bytes));
        closing = true;
        try t.expect(storage.close());
        try t.expect(backing == null and !any(&maps) and !any(&pins));
    }
}

test "firmware CPU storage GSP init owns bidirectional logs and queues with exact partial cleanup" {
    var table = apiTable();
    const ctx = r4os.r4dev.DriverContext.init(&table);
    shadow = try t.allocator.alloc(u8, init.output_bytes);
    defer t.allocator.free(shadow);
    const excluded = [_]init.Span{.{ .address = 0x400000000, .bytes = 4096 }};
    for (std.enums.values(Fault)) |case| {
        fault = case;
        clock = 100;
        closing = false;
        pin_calls = 0;
        sync_calls = 0;
        close_calls = 0;
        queries = 0;
        @memset(shadow, 0xa5);
        var storage: Storage = .{};
        const failure: ?anyerror = switch (case) {
            .allocation => error.Memory,
            .pin_last => error.Pin,
            .map_last => error.Map,
            .pin_header, .map_header, .direction => error.Descriptor,
            .overlap, .external_overlap => error.Overlap,
            .address => error.Address,
            .sync_last => error.Synchronization,
            .timeout => error.Timeout,
            .regression => error.ClockRegression,
            else => null,
        };
        if (failure) |expected| {
            try t.expectError(expected, storage.stage(&ctx, 0x176, &excluded, 1000));
            try t.expect(storage.report == null);
        } else {
            const report = try storage.stage(&ctx, 0x176, &excluded, 1000);
            try t.expectEqual(@as(usize, 7), report.mappings);
            try t.expectEqual(@as(usize, 3), report.queue_segments);
            try t.expectEqual(@as(usize, 7), sync_calls);
            try t.expectEqual(address(0), report.init.libos_address);
            try t.expectEqual(address(0) + 4096, report.init.rm_address);
            try t.expectEqual(address(6), report.init.queues_address);
            try t.expectEqual(if (case == .bounce) @as(usize, 7) else 0, report.bounced);
            if (case == .bounce) try t.expectEqualSlices(u8, backing.?, shadow);
        }
        try t.expectError(error.Busy, storage.stage(&ctx, 0x176, &excluded, 1000));
        closing = true;
        if (case == .unmap or case == .unpin or case == .release) {
            try t.expect(!storage.close());
            try t.expect(storage.report == null and storage.context != null and backing != null);
        }
        fault = .none;
        try t.expect(storage.close());
        const calls = close_calls;
        try t.expect(storage.close());
        try t.expectEqual(calls, close_calls);
        try t.expectEqual(@as(usize, 1), queries);
        try t.expect(backing == null and !any(&maps) and !any(&pins));
    }
}

// Drives the actual resident device owner and native MMIO port against host
// RAM. The model acknowledges firmware-engine writes and emits one GSP record;
// it does not simulate authentication, real hardware timing or UEFI recovery.
const DeviceModel = struct {
    var boot_info: a.GfxNativeBootInfo = .{};
    fn bootInfo(out: *a.GfxNativeBootInfo) callconv(.c) i32 { out.* = boot_info; return a.gfx_output_ok; }
    fn log(_: [*:0]const u8) callconv(.c) void {}
    fn tick(words: []u32, frts: u64, bad_frts: bool) void {
        const core = @import("gsp_core.zig");
        const hs = @import("falcon_hs.zig");
        for ([_]u32{ hs.reg.gsp, hs.reg.sec2 }) |base| {
            if (words[(base + hs.reg.dma_command) / 4] != hs.bits.idle)
                words[(base + hs.reg.dma_command) / 4] = hs.bits.idle;
            if (words[(base + 0x1668) / 4] == 0) words[(base + 0x1668) / 4] = 1;
            if (words[(base + 0x3c0) / 4] & 1 != 0 and base == hs.reg.gsp)
                words[core.reg.riscv_cpuctl / 4] = core.bits.halted;
            if (words[(base + hs.reg.cpu_alias) / 4] == core.bits.start) {
                words[(base + hs.reg.cpu_alias) / 4] = 0;
                if (base == hs.reg.gsp and words[core.reg.bcr / 4] & core.bits.bcr_riscv != 0) {
                    words[core.reg.riscv_cpuctl / 4] = core.bits.active;
                } else if (base == hs.reg.gsp) {
                    words[0x1438 / 4] = if (bad_frts) 0x10000 else 0;
                    words[0x1fa828 / 4] = @intCast(((frts + 0xff000) >> 12) << 4);
                    words[0x1fa824 / 4] = @intCast((frts >> 12) << 4);
                } else {
                    if (words[core.reg.sec_mailbox0 / 4] == 0xff and words[(core.reg.sec_mailbox0 + 4) / 4] == 0xff) {
                        words[0x1fa828 / 4] = 0;
                    } else if (words[core.reg.bcr / 4] & core.bits.bcr_riscv != 0) {
                        // Successful normal Booter Load starts the prepared
                        // GSP RISC-V core; Cold.finish verifies that result.
                        words[core.reg.riscv_cpuctl / 4] = core.bits.active;
                    }
                    words[core.reg.sec_mailbox0 / 4] = 0;
                }
            }
        }
    }
};

fn checkDeviceStartup(lease: *@import("gsp_run_memory.zig").Lease, ctx: *const r4os.r4dev.DriverContext,
    table: *a.DriverApi, capture: *@import("boot_vram.zig").Capture, held: *@import("boot_vram_lease.zig").Lease) !void
{
    const driver = @import("gsp_device.zig");
    const core = @import("gsp_core.zig");
    const hs = @import("falcon_hs.zig");
    const identity = @import("identity.zig");
    const words = try t.allocator.alignedAlloc(u32, comptime std.mem.Alignment.fromByteUnits(4096), 0x842000 / 4);
    defer t.allocator.free(words);
    const target = try t.allocator.create(driver.Device);
    defer t.allocator.destroy(target);
    var fixture: QueueNative = .{ .memory = lease, .words = words, .case = .success };
    queue_native = &fixture;
    const saved_table = table.*;
    defer table.* = saved_table;
    table.version = a.driver_api_thread_work_version;
    table.gfx_memory_query = QueueNative.query;
    table.log_info = DeviceModel.log;
    table.log_warn = DeviceModel.log;
    table.log_error = DeviceModel.log;
    var snapshot: identity.Snapshot = .{ .pci = .{ .vendor_id = 0x10de, .device_id = 0x2504, .class_code = 3 }, .command = 7 };
    snapshot.bars[0] = .{ .kind = .memory32, .base = 0xfb000000, .bytes = words.len * 4 };
    snapshot.bars[1] = .{ .kind = .memory64, .base = 0xd0000000, .bytes = 0x10000000 };
    snapshot.bars[2] = .{ .kind = .upper };
    snapshot.bars[3] = .{ .kind = .memory64, .base = 0xe0000000, .bytes = 0x2000000 };
    snapshot.bars[4] = .{ .kind = .upper };
    const chip = identity.chip(0xb76000a1, 0).?;
    capture.snapshot = snapshot;
    capture.chip = chip;
    capture.operation = try @import("pramin.zig").Capture.init(.{ .epoch = capture.boot.held_generation,
        .deadline = 1000000, .boot0 = 0xb76000a1, .boot1 = 0, .vga = 0x10e08, .range = .{ .address = 0x10e0000, .bytes = 131072 } });
    capture.boot.recovery_required = true; // The existing captured-PRAMIN fixture's hold.
    DeviceModel.boot_info = .{ .generation = 1, .physical_address = 0xd0000000, .byte_length = 4096,
        .width = 32, .height = 32, .pitch = 128, .state = a.display_state_preparing };
    capture.original_boot = DeviceModel.boot_info;
    capture.boot.display = .{ .table = .{ .boot_info = @intFromPtr(&DeviceModel.bootInfo) } };
    try capture.registers.open(ctx, &snapshot, chip);
    try capture.register_access.acquire(&capture.registers, ctx, &snapshot, chip);
    defer {
        std.debug.assert(capture.register_access.release());
        std.debug.assert(capture.registers.close());
        capture.snapshot = null;
        capture.chip = null;
        capture.operation = null;
        capture.original_boot = null;
        capture.boot.display = null;
        capture.boot.recovery_required = false;
    }
    const original_plan = lease.fwsec_storage.?.device.prepared_plan.?;
    lease.fwsec_storage.?.device.prepared_plan.?.engine_mask = 0x400;
    lease.fwsec_storage.?.device.prepared_plan.?.ucode_id = 9;
    defer lease.fwsec_storage.?.device.prepared_plan = original_plan;
    const command = init.queues_offset + init.command_offset;
    const status = init.queues_offset + init.status_offset;
    const header = backing.?[command..][0..32].*;
    const Case = enum { success, old_api, preboot_partial, frts_error, timeout, stolen_display, unknown_event,
        static_bad_region, static_ack_failure, static_timeout,
        runtime_healthy, runtime_lockdown, runtime_unknown, runtime_unowned, runtime_sequence_timeout,
        runtime_log_failure, runtime_moving_log };
    for (std.enums.values(Case)) |case| {
        const exercise_runtime = @intFromEnum(case) >= @intFromEnum(Case.runtime_healthy);
        const boot_success = case == .success or @intFromEnum(case) >= @intFromEnum(Case.static_bad_region);
        errdefer |err| std.debug.print("native device startup {s}: {s}\n", .{ @tagName(case), @errorName(err) });
        @memset(words, 0);
        words[0] = 0xb76000a1;
        for ([_]u32{ hs.reg.gsp, hs.reg.sec2 }) |base| {
            words[(base + 0xf4) / 4] = core.bits.reset_ready | core.bits.riscv_enabled;
            words[(base + 0x108) / 4] = 0x20100;
            words[(base + hs.reg.cpu_control) / 4] = hs.bits.cpu_alias | hs.bits.cpu_halted;
        }
        words[0x118128 / 4] = 1;
        words[0x118234 / 4] = 0xff;
        words[core.reg.riscv_cpuctl / 4] = core.bits.halted;
        clock = 100;
        @memset(backing.?[command..][0..init.queue_bytes], 0);
        @memset(backing.?[status..][0..init.queue_bytes], 0);
        @memset(backing.?[init.logs_offset..][0 .. init.log_count * init.log_bytes], 0);
        @memcpy(backing.?[command..][0..32], &header);
        var reader: @import("gsp_logs.zig").Reader = .{};
        try reader.open(lease);
        target.* = .{};
        if (case == .old_api) {
            table.version = a.driver_api_thread_work_version - 1;
            try t.expectError(error.Api, target.open(ctx, capture, held, lease, &reader));
            try t.expect(target.self_address == 0 and !lease.retained and capture.firmware_owner == 0);
            table.version += 1;
            try t.expect(reader.close());
            continue;
        }
        if (case == .success) {
            capture.snapshot.?.command &= ~@as(u16, 4);
            try t.expectError(error.BusMasterDisabled, target.open(ctx, capture, held, lease, &reader));
            try t.expect(target.self_address == 0 and !lease.retained and capture.firmware_owner == 0);
            capture.snapshot.?.command |= 4;
        }
        if (case == .preboot_partial) {
            // Own header/read cursor + absent peer, system data/cursor, then
            // failure synchronizing registry data. No firmware sees this run.
            range_failure_call = range_calls + 6;
            try t.expectError(error.Io, target.open(ctx, capture, held, lease, &reader));
            range_failure_call = 0;
            try t.expect(target.session.?.state == .failed and target.session.?.tx_sequence == 1);
            try t.expect(std.mem.readInt(u32, backing.?[command + 16 ..][0..4], .little) == 1);
            try t.expect(!target.port.effects_possible and !lease.retained and capture.firmware_owner == 0);
            try t.expect(target.closeBeforeSubmission() and reader.close());
            // Retained host fixture mappings are still owned here. Reset only
            // their injected failure before staging a different model case.
            lease.failed = false;
            lease.queue.failed = false;
            continue;
        }
        try target.open(ctx, capture, held, lease, &reader);
        try t.expect(target.phase == .frts and !target.port.effects_possible and capture.firmware_owner == 0);
        const session = &target.session.?;
        try t.expect(session.preloaded and session.tx_sequence == 2 and session.tx_write == 2);
        try t.expect(std.mem.allEqual(u8, backing.?[status..][0..32], 0));
        const before_repeat = range_calls;
        try t.expectError(error.State, target.port.preloadInit(session, &.{1}, &.{1}));
        try t.expect(range_calls == before_repeat and !lease.retained);
        const system_message = try transport.message.decode(.{ .chip_id = 0x176 }, backing.?[command + 4096 ..][0..4096], 0);
        const registry_message = try transport.message.decode(.{ .chip_id = 0x176 }, backing.?[command + 8192 ..][0..4096], 1);
        try t.expect(system_message.rpc.function == 72 and system_message.rpc.sequence == 0 and system_message.payload.len == 928);
        try t.expect(registry_message.rpc.function == 73 and registry_message.rpc.sequence == 0);
        try t.expect(std.mem.readInt(u64, system_message.payload[0..8], .little) == snapshot.bars[0].base);
        try t.expect(std.mem.readInt(u64, system_message.payload[8..16], .little) == snapshot.bars[1].base);
        try t.expect(std.mem.readInt(u64, system_message.payload[16..24], .little) == snapshot.bars[3].base);
        try t.expect(std.mem.readInt(u64, system_message.payload[64..72], .little) == 0x10000);
        try t.expect(std.mem.readInt(u64, system_message.payload[72..80], .little) == 0x800000000000);
        try t.expect(std.mem.readInt(u64, system_message.payload[920..928], .little) == 4096 and system_message.payload[896] == 1);
        try t.expect(std.mem.readInt(u32, registry_message.payload[4..8], .little) == 3);
        try t.expect(std.mem.indexOf(u8, registry_message.payload, "RMForcePcieConfigSave\x00") != null);
        const original_epoch = capture.boot.held_generation;
        var injected = false;
        var notified = false;
        var boot_lockdown = false;
        var steps: usize = 0;
        while (target.phase != .ready and target.phase != .failed and steps < 12000) : (steps += 1) {
            clock += 1000;
            DeviceModel.tick(words, held.plan.?.frts.offset, case == .frts_error);
            if (!injected and target.port.effects_possible) {
                if (case == .timeout) clock = target.phase_deadline;
                if (case == .stolen_display) capture.boot.held_generation += 1;
                injected = true;
            }
            if (target.phase == .notifications and !notified) {
                if (!boot_lockdown) {
                    @memcpy(backing.?[status..][0..32], &header);
                    std.mem.writeInt(u32, backing.?[status + 24 ..][0..4], 64, .little);
                    // The firmware can consume both async commands before
                    // initializing its producer/header and emitting INIT_DONE.
                    std.mem.writeInt(u32, backing.?[status + 64 ..][0..4], 2, .little);
                }
                if (case == .runtime_lockdown and !boot_lockdown) {
                    try nativeEvent(&target.session.?, 0x101c, &.{1});
                    boot_lockdown = true;
                } else {
                    try nativeEvent(&target.session.?, if (case == .unknown_event) 0xdead else 0x1001, &.{ 0, 0, 0, 0 });
                    notified = true;
                }
            }
            _ = target.step();
        }
        if (steps == 12000 or (boot_success and target.phase != .ready)) {
            std.debug.print("device phase={s} error={?} recovery={?} fw={?} core={?}\n", .{ @tagName(target.phase), target.failure,
                target.recovery_failure, if (target.port.firmware_operation) |op| op.failure else null,
                if (target.port.operation) |op| op.failure else null });
        }
        try t.expect(steps < 12000 and target.port.effects_possible and lease.retained and capture.firmware_owner == @intFromPtr(target));
        if (boot_success) {
            try t.expect(target.phase == .ready and target.handoff != null and target.frts_result != null and target.load_result != null);
            try t.expect(target.boot.?.handled_events == @as(u64, if (boot_lockdown) 2 else 1) and target.session.?.pending == null and target.port.phase == .runtime);
            try t.expect(session.tx_sequence == 2 and session.tx_write == 2 and session.tx_peer_read == 2);
            if (case == .success) {
                var foreign = try transport.Session.init(session.port, session.profile, session.epoch, &target.tx, &target.rx);
                try t.expectError(error.Stale, foreign.connect(target.deadline));
                try t.expect(session.state == .active); // Cannot adopt an old nonempty CPU queue.
            }
            try checkDeviceStatic(target, words, held.plan.?.frts.offset, case);
            if (exercise_runtime) try checkDeviceRuntime(target, words, held.plan.?.frts.offset, case);
        } else {
            try t.expect(target.phase == .failed and target.failure != null);
            if (case == .stolen_display) try t.expect(target.recovery_failure != null) else
                try t.expect(target.recovery.report != null and target.port.phase == .recovery and !reader.enabled);
        }
        try t.expect(!target.closeBeforeSubmission() and !capture.close() and !lease.releaseBeforeSubmission());
        // Dispose host-only fixture effects. Production exposes no equivalent
        // release or replay operation; neither model success nor halt is proof.
        capture.boot.held_generation = original_epoch;
        capture.firmware_owner = 0;
        lease.retained = false;
        lease.failed = false;
        lease.recovery_owner = 0;
        lease.queue.failed = false;
        lease.init_storage.?.device_access = false;
        target.port.effects_possible = false;
        target.port.recovery_owner = 0;
        target.port.phase = .boot;
        target.port.runtime_session = null;
        target.port.runtime_sequence = null; // Dispose retained host-only fault metadata.
        try t.expect(target.port.close());
        try t.expect(reader.close());
    }
    @memset(backing.?[command..][0..init.queue_bytes], 0);
    @memset(backing.?[status..][0..init.queue_bytes], 0);
    @memset(backing.?[init.logs_offset..][0 .. init.log_count * init.log_bytes], 0);
    @memcpy(backing.?[command..][0..32], &header);
    clock = 100;
    for ([_]u32{ 0, 4 }) |reg| try t.expect(driver.allowed(.read, reg) and !driver.allowed(.write, reg));
    try t.expect(!driver.allowed(.read, core.reg.cpuctl_alias) and !driver.allowed(.write, 0x610000));
    try t.expect(!driver.allowed(.write, 0x1700) and !driver.allowed(.read, 0x110101));
    for ([_]u32{ core.reg.hwcfg2, core.reg.sec_hwcfg2, core.reg.riscv_cpuctl, core.reg.handoff,
        hs.reg.gsp + 0x108, hs.reg.sec2 + 0x108 }) |reg|
        try t.expect(driver.allowed(.read, reg) and !driver.allowed(.write, reg));
}

fn deviceSequence(target: *@import("gsp_device.zig").Device, words: []const u32) !void {
    var payload: [128]u8 = @splat(0);
    std.mem.writeInt(u32, payload[0..4], @intCast(words.len + 1), .little);
    std.mem.writeInt(u32, payload[4..8], @intCast(words.len), .little);
    for (words, 0..) |value, index| std.mem.writeInt(u32, payload[40 + index * 4 ..][0..4], value, .little);
    try nativeEvent(&target.session.?, 0x1002, payload[0 .. 40 + words.len * 4]);
}

fn checkDeviceStatic(target: *@import("gsp_device.zig").Device, words: []u32, frts: u64, scenario: anytype) !void {
    const static = @import("gsp_static.zig");
    const native = @import("gsp_sequencer_port.zig");
    const channel = &target.running.channel.?;
    const session = &target.session.?;
    const owner = target.port.owner.?;
    const deadline = channel.deadline.?;
    const command = init.queues_offset + init.command_offset;
    const status = init.queues_offset + init.status_offset;
    const physical = target.vram.?.plan.?.fb_bytes;
    try t.expect(target.running.static_info == null and channel.phase == .prepared);
    // A firmware CPU command cannot acquire the queue notifier's authority.
    if (!channel.in_lockdown) {
        try t.expectError(error.Register, owner.access(owner.context, .write, native.command_queue_head));
        try t.expectError(error.Unsupported, owner.admit(owner.context, .{ .write = .{ .address = native.command_queue_head, .value = 0 } }));
    } else {
        try t.expectError(error.Lockdown, owner.admit_command.?(owner.context, &target.port, deadline));
        try t.expect(target.step() == .idle and session.tx_sequence == 2);
        try nativeEvent(session, 0x101c, &.{0});
        try t.expect(target.step() == .progress and !channel.in_lockdown);
    }
    var print: [9]u8 = @splat(0);
    print[4] = 1; // Libos payload length, excluding its8-byte prefix.
    print[8] = 'S';
    try nativeEvent(session, 0x100c, &print);
    try t.expect(target.step() == .progress and channel.deadline == deadline and session.tx_sequence == 2);
    words[native.command_queue_head / 4] = 0x79797979;
    _ = target.step();
    try t.expect(target.phase == .ready and channel.phase == .waiting and session.tx_sequence == 3 and session.tx_write == 3);
    try t.expect(words[native.command_queue_head / 4] == 0 and channel.deadline == deadline);
    const request = try transport.message.decode(session.profile, backing.?[command + 3 * 4096 ..][0..4096], 2);
    try t.expect(request.rpc.function == static.function and request.rpc.sequence == 2);
    try t.expect(request.payload.len == static.payload_bytes and std.mem.allEqual(u8, request.payload, 0));
    std.mem.writeInt(u32, backing.?[status + 64 ..][0..4], 3, .little); // Firmware consumes TX.
    words[native.command_queue_head / 4] = 0x79797979;
    var response: [static.payload_bytes]u8 = @splat(0);
    std.mem.writeInt(u32, response[344..348], 2, .little);
    std.mem.writeInt(u64, response[360..368], physical / 2 - 1, .little);
    response[380] = 1; response[381] = 1;
    std.mem.writeInt(u64, response[400..408], physical / 2, .little);
    std.mem.writeInt(u64, response[408..416], physical - 1, .little);
    std.mem.writeInt(u64, response[416..424], 4096, .little);
    response[430] = 1;
    std.mem.writeInt(u64, response[1224..1232], physical, .little);
    std.mem.writeInt(u64, response[1536..1544], physical - 65536, .little);
    std.mem.writeInt(u64, response[1544..1552], physical - 131072, .little);
    for ([_]u32{0xcaf00001, 0xcaf00002, 0xcaf00003}, 0..) |value, index|
        std.mem.writeInt(u32, response[1600 + index * 4 ..][0..4], value, .little);
    if (scenario == .static_timeout) {
        // A notification while waiting neither republishes nor extends RPC.
        clock = deadline - 1;
        try nativeEvent(session, 0x100c, &print);
        try t.expect(target.step() == .progress and channel.deadline == deadline and session.tx_sequence == 3);
        clock = deadline;
    } else {
        if (scenario == .static_bad_region) std.mem.writeInt(u64, response[400..408], 0, .little);
        try nativeEvent(session, static.function, &response);
        // Three receive range reads, then the one response ACK write.
        if (scenario == .static_ack_failure) range_failure_call = range_calls + 4;
    }
    _ = target.step();
    range_failure_call = 0;
    const failed = scenario == .static_timeout or scenario == .static_bad_region or scenario == .static_ack_failure;
    try t.expect(words[native.command_queue_head / 4] == 0x79797979 and session.tx_sequence == 3);
    if (!failed) {
        const info = target.running.static_info orelse return error.MissingStaticInfo;
        try t.expect(channel.phase == .idle and channel.deadline == null and session.pending == null);
        try t.expect(info.client == 0xcaf00001 and info.device == 0xcaf00002 and info.subdevice == 0xcaf00003);
        try t.expect(info.fb_bytes == physical and info.region_count == 2 and info.regions[1].protected and info.regions[1].reserved == 4096);
        try t.expect(info.regions[0].iso and info.regions[0].compressed and info.regions[0].bytes == physical / 2);
        // Snapshot survives reuse of the borrowed DMA receive buffer.
        @memset(&target.rx, 0xa5);
        try t.expect(target.running.static_info.?.client == info.client);
        return;
    }
    try t.expect(target.running.static_info == null and target.running.failure != null);
    try t.expectEqual(if (scenario == .static_timeout) error.Deadline else if (scenario == .static_bad_region) error.Region else error.Io,
        target.running.failure.?);
    const receipt = session.pending;
    try t.expect((receipt != null) == (scenario != .static_timeout));
    var steps: usize = 0;
    while (target.phase != .failed and steps < 12000) : (steps += 1) {
        clock += 1000;
        DeviceModel.tick(words, frts, false);
        _ = target.step();
    }
    try t.expect(steps < 12000 and target.phase == .failed and target.memory.?.retained and target.recovery.report != null);
    try t.expect(std.meta.eql(receipt, session.pending) and target.port.phase == .recovery and !target.reader.?.enabled);
}

fn checkDeviceRuntime(target: *@import("gsp_device.zig").Device, words: []u32, frts: u64, scenario: anytype) !void {
    const core = @import("gsp_core.zig");
    const original_deadline = target.deadline;
    const reader = target.reader.?;
    const initial_events = target.running.snapshot.events;
    try t.expect(target.running.self_address == @intFromPtr(&target.running) and target.handoff.?.claimed);
    // Runtime idle uses a fresh finite observation deadline, never the old
    // boot deadline and never an unbounded wait or a claimed heartbeat.
    clock = original_deadline + 1;
    try t.expect(target.step() == .idle and target.phase == .ready and target.failure == null);
    try t.expect(target.running.channel.?.deadline == null and target.deadline == original_deadline);
    try t.expect(target.running.snapshot.last_poll_ns == clock and target.running.snapshot.events == initial_events);
    var fails = false;
    switch (scenario) {
        .runtime_unknown => {
            try nativeEvent(&target.session.?, 0xdead, &.{});
            _ = target.step();
            fails = true;
        },
        .runtime_unowned => {
            try nativeEvent(&target.session.?, 0x1007, &.{ 0, 0, 0, 0, 1, 0, 0, 0 });
            _ = target.step();
            try t.expect(target.running.failure != null and target.running.failure.? == error.Unsupported);
            fails = true;
        },
        .runtime_sequence_timeout => {
            try deviceSequence(target, &.{ 3, 100000 });
            try t.expect(target.step() == .progress and target.running.sequence.self_address != 0);
            clock = target.running.sequence.deadline;
            _ = target.step();
            fails = true;
        },
        .runtime_log_failure, .runtime_moving_log => {
            const index = target.running.log_index;
            const bytes = backing.?[init.logs_offset + index * init.log_bytes ..][0..init.log_bytes];
            std.mem.writeInt(u64, bytes[0..8], 1, .little);
            std.mem.writeInt(u64, bytes[8..16], 0x79797979, .little);
            clock = target.running.next_log;
            log_fault = if (scenario == .runtime_log_failure) .io else .producer;
            const progress = target.step();
            log_fault = .none;
            if (scenario == .runtime_log_failure) {
                fails = true;
            } else {
                try t.expect(progress == .idle and target.phase == .ready and target.running.snapshot.moving_logs == 1);
                try t.expect(reader.previous[index] == 0 and target.running.snapshot.raw_words == 0 and !target.memory.?.failed);
            }
        },
        .runtime_healthy, .runtime_lockdown => {
            const io_owner = target.port.owner.?;
            if (scenario == .runtime_lockdown) {
                try nativeEvent(&target.session.?, 0x101c, &.{1});
                try t.expect(target.step() == .progress);
                try t.expect(target.boot.?.in_lockdown and target.running.channel.?.in_lockdown);
                try t.expectError(error.Lockdown, io_owner.access(io_owner.context, .write, core.reg.mailbox0));
                try nativeEvent(&target.session.?, 0x101c, &.{0});
                try t.expect(target.step() == .progress and !target.running.channel.?.in_lockdown);
                try t.expect(target.boot.?.in_lockdown); // Old boot token cannot keep runtime locked.
                try io_owner.access(io_owner.context, .write, core.reg.mailbox0);
            }
            var print: [15]u8 = @splat(0);
            std.mem.writeInt(u32, print[4..8], 7, .little);
            @memcpy(print[8..], "50%\r\nOK");
            try nativeEvent(&target.session.?, 0x100c, &print);
            try t.expect(target.step() == .progress and target.running.channel.?.pending == null);
            var xid: [272]u8 = @splat(0);
            std.mem.writeInt(u32, xid[0..4], 79, .little);
            std.mem.writeInt(u32, xid[4..8], 3, .little);
            std.mem.writeInt(u32, xid[8..12], 4, .little);
            @memcpy(xid[12..16], "diag");
            try nativeEvent(&target.session.?, 0x1006, &xid);
            try t.expect(target.step() == .progress and target.running.snapshot.xid_count == 1 and target.running.snapshot.last_xid == 79);
            const nocat: [1208]u8 = @splat(0);
            try nativeEvent(&target.session.?, 0x1020, &nocat);
            try t.expect(target.step() == .progress and target.running.snapshot.nocat_count == 1);
            try deviceSequence(target, &.{ 0, core.reg.mailbox0, 0x7979, 4, core.reg.mailbox0, 0 });
            try t.expect(target.step() == .progress and target.running.sequence.self_address != 0);
            var count: usize = 0;
            while (target.running.sequence.self_address != 0 and count < 16) : (count += 1) {
                clock += 1000;
                try t.expect(target.step() == .progress);
            }
            try t.expect(count < 16 and target.running.snapshot.sequencers == 1 and words[core.reg.mailbox0 / 4] == 0x7979);
            try t.expect(target.session.?.pending == null and target.port.runtime_sequence == null);
            for (0..init.log_count) |index| {
                const bytes = backing.?[init.logs_offset + index * init.log_bytes ..][0..init.log_bytes];
                std.mem.writeInt(u64, bytes[0..8], index + 1, .little);
            }
            for (0..init.log_count) |_| {
                clock = target.running.next_log;
                try t.expect(target.step() == .idle);
            }
            try t.expect(target.running.snapshot.raw_words == 15 and target.running.snapshot.lost_words == 0);
            try t.expect(target.running.snapshot.events == initial_events + @as(u64, if (scenario == .runtime_lockdown) 6 else 4));
            try t.expect(target.running.snapshot.last_event_ns < target.running.snapshot.last_poll_ns);
        },
        else => unreachable,
    }
    if (fails) {
        const receipt = target.session.?.pending;
        var steps: usize = 0;
        while (target.phase != .failed and steps < 12000) : (steps += 1) {
            clock += 1000;
            DeviceModel.tick(words, frts, false);
            _ = target.step();
        }
        try t.expect(steps < 12000 and target.phase == .failed and target.running.failure != null and target.failure != null);
        try t.expect(target.recovery.report != null and target.port.phase == .recovery and !reader.enabled);
        try t.expect(std.meta.eql(receipt, target.session.?.pending) and target.memory.?.retained);
        if (scenario != .runtime_log_failure) try t.expect(receipt != null);
    } else try t.expect(target.phase == .ready and target.running.failure == null and target.memory.?.retained);
}
