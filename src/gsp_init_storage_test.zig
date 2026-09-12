const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const t = std.testing;
const ControlModel = @import("gsp_control_test_model.zig").Model;
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
    return nativeReply(session, function, 0, payload);
}
fn nativeReply(session: *transport.Session, function: u32, result: u32, payload: []const u8) !void {
    try t.expect(session.pending == null and payload.len < 4000);
    const status = init.queues_offset + init.status_offset;
    const cursor = std.mem.readInt(u32, backing.?[status + 16 ..][0..4], .little);
    const start = status + 4096 + @as(usize, cursor) * 4096;
    _ = try transport.message.encode(session.profile, session.rx_sequence, .{ .function = function, .result = result }, payload, backing.?[start..][0..4096]);
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
    var receiver_logs: usize = 0;
    var ddc_logs: usize = 0;
    var aux_logs: usize = 0;
    var wiring_logs: usize = 0;
    var hpd_logs: usize = 0;
    var xpio_logs: usize = 0;
    var memory_logs: usize = 0;
    var region_logs: usize = 0;
    var aperture_logs: usize = 0;
    var vaspace_logs: usize = 0;
    var control_logs: usize = 0;
    fn log(text: [*:0]const u8) callconv(.c) void {
        const line = std.mem.span(text);
        if (std.mem.startsWith(u8, line, "NVIDIA gsp-receiver:")) receiver_logs += 1;
        if (std.mem.startsWith(u8, line, "NVIDIA gsp-ddc:")) ddc_logs += 1;
        if (std.mem.startsWith(u8, line, "NVIDIA gsp-aux:")) aux_logs += 1;
        if (std.mem.startsWith(u8, line, "NVIDIA gsp-wire:")) wiring_logs += 1;
        if (std.mem.startsWith(u8, line, "NVIDIA gsp-hpd:")) hpd_logs += 1;
        if (std.mem.startsWith(u8, line, "NVIDIA gsp-xpio:")) xpio_logs += 1;
        if (std.mem.startsWith(u8, line, "NVIDIA gsp-memory:")) memory_logs += 1;
        if (std.mem.startsWith(u8, line, "NVIDIA gsp-region:")) region_logs += 1;
        if (std.mem.startsWith(u8, line, "NVIDIA gsp-aperture:")) aperture_logs += 1;
        if (std.mem.startsWith(u8, line, "NVIDIA gsp-vaspace:")) vaspace_logs += 1;
        if (std.mem.startsWith(u8, line, "NVIDIA gsp-control:")) control_logs += 1;
    }
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

const CatalogModel = struct {
    var active: bool = false;
    var legacy: bool = false;
    var reject: bool = false;
    var serial: u64 = 0;
    var sequence: u64 = 0;
    var count: u32 = 0;
    var invalidations: usize = 0;
    var first: a.GfxReceiverInfo = .{};
    var last: a.GfxReceiverInfo = .{};
    fn query(output: *a.GfxDriverOutputApi) callconv(.c) i32 {
        output.* = if (legacy) .{ .size = 24 } else .{ .register_source = @intFromPtr(&register),
            .replace_receivers = @intFromPtr(&replace), .close_source = @intFromPtr(&close) };
        return a.gfx_output_ok;
    }
    fn register(adapter: u32, output: *a.GfxReceiverSource) callconv(.c) i32 {
        std.debug.assert(!active and adapter == 0x01000000);
        serial += 1; active = true; count = 0; sequence = 0; invalidations = 0;
        output.* = .{ .adapter_id = adapter, .generation = serial };
        return a.gfx_output_ok;
    }
    fn replace(input: *const a.GfxReceiverUpdate) callconv(.c) i32 {
        std.debug.assert(active and input.source.generation == serial and input.sequence > sequence and
            input.count <= 32 and (input.count == 0) == (input.receivers == 0));
        if (reject) return a.gfx_output_error_capacity;
        if (input.count == 0 and count != 0) invalidations += 1;
        sequence = input.sequence; count = input.count;
        if (count != 0) {
            const records: [*]const a.GfxReceiverInfo = @ptrFromInt(input.receivers);
            first = records[0]; last = records[count - 1];
            std.debug.assert(first.connector_id != 0 and last.connector_id != 0);
        }
        return a.gfx_output_ok;
    }
    fn close(input: *const a.GfxReceiverSource) callconv(.c) i32 {
        if (!active and input.generation == serial) return a.gfx_output_error_stale;
        std.debug.assert(active and input.generation == serial);
        active = false; count = 0;
        return a.gfx_output_ok;
    }
};

fn checkDeviceStartup(lease: *@import("gsp_run_memory.zig").Lease, ctx: *const r4os.r4dev.DriverContext,
    table: *a.DriverApi, capture: *@import("boot_vram.zig").Capture, held: *@import("boot_vram_lease.zig").Lease) !void
{
    const driver = @import("gsp_device.zig");
    const core = @import("gsp_core.zig");
    const hs = @import("falcon_hs.zig");
    const identity = @import("identity.zig");
    const words = try t.allocator.alignedAlloc(u32, comptime std.mem.Alignment.fromByteUnits(4096), 0xbc0000 / 4);
    defer t.allocator.free(words);
    const target = try t.allocator.create(driver.Device);
    defer t.allocator.destroy(target);
    var fixture: QueueNative = .{ .memory = lease, .words = words, .case = .success };
    queue_native = &fixture;
    const saved_table = table.*;
    defer table.* = saved_table;
    table.version = a.driver_api_thread_work_version;
    table.gfx_memory_query = QueueNative.query;
    ControlModel.install(table);
    table.gfx_output_query = CatalogModel.query;
    table.log_info = DeviceModel.log;
    table.log_warn = DeviceModel.log;
    table.log_error = DeviceModel.log;
    table.pci_enable_msi = IrqModel.enableMsi;
    table.pci_disable_msi = IrqModel.disableMsi;
    table.irq_register = IrqModel.register;
    table.irq_unregister = IrqModel.unregister;
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
    // The earlier storage-lifetime fixture did not need translated extents.
    // Supply an explicit retained physical surface for the real runtime's
    // memory inventory; the independent BAR1 reader tests own translation.
    const boot_mapping = held.boot_mapping.?;
    try t.expect(boot_mapping.range_count == 0 and boot_mapping.page_count == 0);
    boot_mapping.ranges[0] = .{ .address = 0x10000, .bytes = 4096 };
    boot_mapping.range_count = 1;
    boot_mapping.surface_bytes = 4096;
    boot_mapping.framebuffer_bytes = held.plan.?.fb_bytes;
    defer {
        boot_mapping.range_count = 0;
        boot_mapping.surface_bytes = 0;
        boot_mapping.framebuffer_bytes = 0;
    }
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
        post_control_error, post_wrong_gpc, post_bad_vector, post_ack_failure, post_timeout,
        irq_intx, irq_register_error, irq_msi_uncertain, irq_cause, irq_wake_failure, irq_close_busy, irq_unregister_failure,
        rm_base_reject, rm_i2c_reject, rm_event_reject, rm_free_error, rm_timeout, rm_ack_failure, rm_foreign_event, rm_event_ack,
        rm_vaspace_reject, rm_vaspace_short, rm_vaspace_bounds, rm_vaspace_ack, rm_vaspace_timeout, rm_vaspace_free,
        control_allocation, control_cache, control_alias, control_sync, control_register_reject, control_virtual_reject, control_map_reject,
        control_short, control_bounds, control_map_address, control_ack, control_timeout, control_unmap, control_free, control_dma_unmap, control_release, control_gpu_acquire, control_gpu_release,
        memory_caps_reject, memory_caps_none, memory_caps_rpc, memory_caps_short, memory_caps_wrong, memory_caps_ack, memory_caps_timeout,
        mapping_success, mapping_reject, mapping_offset, mapping_ack, mapping_timeout, mapping_release, mapping_segment, mapping_gpu,
        vram_success, vram_budget, vram_physical_reject, vram_virtual_reject, vram_map_reject, vram_commit, vram_size, vram_ack, vram_timeout, vram_free, vram_finish,
        vram_surface_linear, vram_surface_tiled, vram_surface_changed, vram_surface_contiguity,
        vram_storage, vram_storage_bounds, vram_storage_contiguity, vram_storage_acquire, vram_storage_descriptor, vram_storage_no_clear,
        context_success, context_classes, context_engine, context_query_reject, context_page, context_duplicate,
        context_group_reject, context_share_reject, context_share_changed, context_ack, context_timeout, context_free,
        context_methods, context_methods_acquire, context_methods_free, context_methods_release,
        context_fifo_success, context_fifo_allocate, context_fifo_bind, context_fifo_token, context_fifo_enable,
        context_fifo_changed, context_fifo_ack, context_fifo_timeout, context_fifo_disable, context_fifo_free, context_fifo_dma,
        context_copy_success, context_copy_class, context_copy_allocate, context_copy_changed, context_copy_timeout, context_copy_completion,
        context_copy_rc, context_copy_rc_unmatched, context_copy_mmu, context_copy_xid, context_copy_fault_ack, context_copy_irq,
        context_copy_capacity, context_copy_oom, context_copy_invalid, context_copy_lost_idle, context_copy_fastpath,
        context_upload_success, context_upload_timeout, context_upload_fault, context_upload_sync,
        context_upload_release, context_upload_acquire, context_upload_retry,
        context_display_success, context_display_timeout, context_display_fault, context_display_cursor, context_display_notifier, context_display_map,
        context_display_image, context_display_image_timeout, context_display_image_fault, context_display_image_lost,
        context_display_image_position_timeout, context_display_image_position_fault,
        context_display_image_link_reject, context_display_image_link_timeout, context_display_image_link_stale,
        context_display_image_link_late_reject, context_display_image_link_ack, context_display_image_link_fault,
        context_display_image_link_dvi,
        context_display_present, context_display_present_timeout, context_display_present_fault,
        context_display_present_initial_timeout, context_display_present_initial_fault, context_display_present_initial_release,
        context_display_present_initial_acquire, context_display_present_initial_retry,
        display_root_success, display_root_classes, display_root_reject, display_root_static, display_root_preserve, display_root_free,
        display_root_ack, display_root_timeout, display_root_wrong,
        display_dma_success, display_dma_instance_ack, display_dma_instance_reject, display_dma_oom, display_dma_segment, display_dma_unmap,
        display_dma_pushbuffer, display_dma_allocate, display_dma_ack, display_dma_free, display_dma_busy, display_dma_release, display_dma_fault,
        outputs_empty, outputs_all, outputs_rejected, outputs_partial, outputs_missing, outputs_incomplete, outputs_bad_edid,
        outputs_edid_rejected, outputs_ddc, outputs_ddc_bus_changed, outputs_aux, outputs_wiring, outputs_virtual, outputs_changed, outputs_final_changed, outputs_final_rejected, outputs_hpd, outputs_sequence, outputs_ack, outputs_timeout, catalog_rejected,
        runtime_healthy, runtime_lockdown, runtime_unknown, runtime_unowned, runtime_sequence_timeout,
        runtime_log_failure, runtime_moving_log };
    for (std.enums.values(Case)) |case| {
        ControlModel.reset(@tagName(case));
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
        try t.expect(!CatalogModel.active);
        CatalogModel.reject = case == .catalog_rejected;
        IrqModel.reset();
        target.irq_wake = .{ .context = @intFromPtr(target), .signal = IrqModel.wake };
        capture.snapshot.?.caps.msi = if (case == .irq_intx) 0 else 0x68;
        capture.snapshot.?.interrupt_line = 11;
        capture.snapshot.?.interrupt_pin = 1;
        if (case == .old_api) {
            table.version = a.driver_api_thread_work_version - 1;
            try t.expectError(error.Api, target.open(ctx, capture, held, lease, &reader, null));
            try t.expect(target.self_address == 0 and !lease.retained and capture.firmware_owner == 0);
            table.version += 1;
            CatalogModel.legacy = true;
            try t.expectError(error.Api, target.open(ctx, capture, held, lease, &reader, null));
            try t.expect(!target.port.effects_possible and !CatalogModel.active and !lease.retained);
            CatalogModel.legacy = false;
            try t.expect(target.closeBeforeSubmission());
            try t.expect(reader.close());
            continue;
        }
        if (case == .success) {
            capture.snapshot.?.command &= ~@as(u16, 4);
            try t.expectError(error.BusMasterDisabled, target.open(ctx, capture, held, lease, &reader, null));
            try t.expect(target.self_address == 0 and !lease.retained and capture.firmware_owner == 0);
            capture.snapshot.?.command |= 4;
        }
        if (case == .preboot_partial) {
            // Own header/read cursor + absent peer, system data/cursor, then
            // failure synchronizing registry data. No firmware sees this run.
            range_failure_call = range_calls + 6;
            try t.expectError(error.Io, target.open(ctx, capture, held, lease, &reader, null));
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
        const board_rom = @import("tests.zig").portFixture();
        var supplied_board = try @import("vbios.zig").parse(&board_rom, 0x2504);
        if (case == .outputs_wiring) {
            supplied_board.validated_device = 0xbeef;
            try t.expectError(error.Binding, target.open(ctx, capture, held, lease, &reader, &supplied_board));
            try t.expect(target.self_address == 0 and !CatalogModel.active);
            supplied_board.validated_device = 0x2504;
        }
        if (case == .outputs_virtual) supplied_board.ports[0].virtual = true;
        try target.open(ctx, capture, held, lease, &reader, if (case == .outputs_wiring or case == .outputs_virtual) &supplied_board else null);
        supplied_board = .{}; // Device must own a complete copy beyond the caller's lifetime.
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
            if (target.phase == .ready) try checkDevicePostInit(target, words, held.plan.?.frts.offset, case);
            if (target.phase == .ready) try checkDeviceIrq(target, words, held.plan.?.frts.offset, case);
            if (target.phase == .ready and !target.stopped) try checkDeviceRm(target, words, held.plan.?.frts.offset, case);
            if (target.phase == .ready and std.mem.startsWith(u8, @tagName(case), "mapping_")) try checkDeviceMappings(target, table, @tagName(case));
            if (target.phase == .ready and std.mem.startsWith(u8, @tagName(case), "vram_")) try checkDeviceVram(target, table, @tagName(case));
            if (target.phase == .ready and std.mem.startsWith(u8, @tagName(case), "context_")) try checkDeviceContexts(target, table, @tagName(case));
            if (target.phase == .ready and std.mem.startsWith(u8, @tagName(case), "display_root_")) try checkDeviceDisplayEngine(target, @tagName(case));
            if (target.phase == .ready and std.mem.startsWith(u8, @tagName(case), "display_dma_")) try checkDeviceDisplayChannels(target, table, words, @tagName(case));
            if (target.phase == .ready and !target.stopped) try checkDeviceOutputs(target, words, held.plan.?.frts.offset, case);
            if (exercise_runtime) try checkDeviceRuntime(target, words, held.plan.?.frts.offset, case);
        } else {
            try t.expect(target.phase == .failed and target.failure != null);
            if (case == .stolen_display) try t.expect(target.recovery_failure != null) else
                try t.expect(target.recovery.report != null and target.port.phase == .recovery and !reader.enabled);
        }
        if (case == .outputs_hpd) {
            // Generic kernel stop has already revoked the metadata source.
            CatalogModel.active = false; CatalogModel.count = 0;
            try t.expect(target.catalog.close() and target.catalog.last_status == a.gfx_output_error_stale and lease.retained);
        }
        try t.expect(!target.closeBeforeSubmission() and !capture.close() and !lease.releaseBeforeSubmission());
        try t.expect(!CatalogModel.active and CatalogModel.count == 0 and lease.retained);
        // Remove injected routing/retirement failures only for host disposal.
        // Production retains the entire mapping graph on these failures.
        IrqModel.unregister_result = 0;
        target.interrupts.routing_uncertain = false;
        try t.expect(target.interrupts.close());
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
    try t.expect(target.running.nativeMemory() == null);
    const memory_logs = DeviceModel.memory_logs;
    const region_logs = DeviceModel.region_logs;
    const aperture_logs = DeviceModel.aperture_logs;
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
    std.mem.writeInt(u64, response[1640..1648], target.vram.?.plan.?.non_wpr_heap.offset, .little);
    std.mem.writeInt(u64, response[1648..1656], target.vram.?.plan.?.frts.offset, .little);
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
        const memory = target.running.nativeMemory() orelse return error.MissingMemoryInventory;
        try t.expect(memory.epoch == session.epoch and memory.boot_epoch == target.vram.?.epoch);
        try t.expect(memory.reported_bytes == physical and memory.physical_bytes == physical and memory.region_bytes == physical and memory.region_holes == 0);
        try t.expect(memory.speculative_reserved == 4096 and memory.firmware_layout_matches and !memory.rebar_present);
        try t.expect(memory.surface_extents == 1 and memory.table_pages == 0 and memory.instance_active and memory.payload_extents == 0);
        try t.expect(memory.retained_count == 4 and memory.retained_bytes == target.vram.?.plan.?.reserved.bytes + 131072 + 65536 + 4096);
        try t.expect(memory.screened_bytes == physical / 2 - 131072 - 65536 - 4096);
        try t.expect(memory.windows[1].base == 0xd0000000 and memory.windows[1].bytes == 0x10000000 and memory.windows[1].status == .measured);
        try t.expect(memory.windows[2].pci_index == 3 and memory.windows[2].bytes == 0x2000000);
        try t.expect(DeviceModel.memory_logs == memory_logs + 2 and DeviceModel.region_logs == region_logs + 2 and DeviceModel.aperture_logs == aperture_logs + 3);
        if (scenario == .success) try checkMemoryInventory(target, &info);
        // Snapshot survives reuse of the borrowed DMA receive buffer.
        @memset(&target.rx, 0xa5);
        try t.expect(target.running.static_info.?.client == info.client);
        try t.expect(target.running.nativeMemory() == memory and memory.reported_bytes == physical);
        return;
    }
    try t.expect(target.running.static_info == null and target.running.failure != null);
    try t.expect(target.running.nativeMemory() == null and target.running.memory_inventory.snapshot() == null);
    try t.expect(DeviceModel.memory_logs == memory_logs and DeviceModel.region_logs == region_logs and DeviceModel.aperture_logs == aperture_logs);
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

fn checkMemoryInventory(target: *@import("gsp_device.zig").Device, info: *const @import("gsp_static.zig").Info) !void {
    const inventory = @import("gsp_memory_inventory.zig");
    const live = &target.running.memory_inventory;
    const lease = target.vram.?;
    const physical = info.fb_bytes;
    try t.expectEqual(inventory.Placement.requires_rm_allocation, try live.placement(.{ .base = 0x20000, .bytes = 4096 }));
    try t.expectEqual(inventory.Placement.boot_retained, try live.placement(.{ .base = 0x10000, .bytes = 4096 }));
    try t.expectEqual(inventory.Placement.boot_retained, try live.placement(.{ .base = lease.plan.?.reserved.offset, .bytes = 1 }));
    try t.expectEqual(inventory.Placement.protected, try live.placement(.{ .base = physical / 2, .bytes = 4096 }));
    try t.expectEqual(inventory.Placement.region_gap, try live.placement(.{ .base = physical / 2 - 4096, .bytes = 8192 }));
    try t.expectEqual(inventory.Placement.invalid, try live.placement(.{ .base = std.math.maxInt(u64), .bytes = 4096 }));
    try t.expectEqual(inventory.Placement.invalid, try live.placement(.{ .base = 0, .bytes = 0 }));
    lease.serial += 1;
    try t.expect(target.running.nativeMemory() == null);
    try t.expectError(error.MemoryStale, live.placement(.{ .base = 0x20000, .bytes = 4096 }));
    lease.serial -= 1;
    try t.expect(target.running.nativeMemory() != null);

    // Same real retained lease, varied firmware metadata. These observations
    // never allocate memory or extend the device port's allowed operations.
    const model = try t.allocator.create(inventory.Owner);
    defer t.allocator.destroy(model);
    var sample = info.*;
    sample.regions[0].reserved = 1;
    model.* = .{};
    try model.prepare(lease, &sample, target.epoch);
    try t.expect(model.snapshot() == null);
    try model.publish();
    try t.expect(model.snapshot().?.screened_bytes == 0);
    try t.expectEqual(inventory.Placement.rm_reserved, try model.placement(.{ .base = 0x20000, .bytes = 4096 }));
    try t.expectEqual(inventory.Placement.rm_reserved, try model.placement(.{ .base = physical / 2 - 1, .bytes = 1 }));
    model.invalidate();
    try t.expect(model.snapshot() == null);

    // A reported layout change is visible but authorizes no screened region.
    sample = info.*;
    sample.non_wpr_heap += 4096;
    model.* = .{};
    try model.prepare(lease, &sample, target.epoch);
    try model.publish();
    try t.expect(!model.snapshot().?.firmware_layout_matches and model.snapshot().?.screened_bytes == 0);
    try t.expectEqual(inventory.Placement.firmware_layout_changed, try model.placement(.{ .base = 0x20000, .bytes = 4096 }));

    // Holes are not free, region order does not imply address order, aliases
    // are counted once, and partial batch failure never publishes a catalog.
    sample = info.*;
    sample.regions[0].base = 0x40000;
    sample.regions[0].bytes -= 0x40000;
    std.mem.swap(@import("gsp_static.zig").Region, &sample.regions[0], &sample.regions[1]);
    const boot_map = lease.boot_mapping.?;
    const original = boot_map.ranges[0];
    boot_map.ranges[0] = .{ .address = 0x100000, .bytes = 4096 }; // Alias inside instance backup.
    defer boot_map.ranges[0] = original;
    model.* = .{};
    try model.prepare(lease, &sample, target.epoch);
    try model.publish();
    try t.expect(model.snapshot().?.region_holes == 0x40000 and model.snapshot().?.retained_count == 3);
    try t.expect(model.snapshot().?.retained_bytes == live.data.retained_bytes - 4096);
    try t.expectEqual(inventory.Placement.region_gap, try model.placement(.{ .base = 0x20000, .bytes = 4096 }));
    try t.expectEqual(inventory.Placement.requires_rm_allocation, try model.placement(.{ .base = 0x40000, .bytes = 4096 }));
    sample.regions[1].base = physical - 1;
    model.* = .{};
    try t.expectError(error.MemoryBounds, model.prepare(lease, &sample, target.epoch));
    try t.expect(model.snapshot() == null);
}

fn checkDevicePostInit(target: *@import("gsp_device.zig").Device, words: []u32, frts: u64, scenario: anytype) !void {
    const postinit = @import("gsp_postinit.zig");
    const post = &target.running.post;
    const channel = &target.running.channel.?;
    const session = &target.session.?;
    const command = init.queues_offset + init.command_offset;
    const status = init.queues_offset + init.status_offset;
    const queue_head = @import("gsp_sequencer_port.zig").command_queue_head;
    const initial_sequence = session.tx_sequence;
    var replies: usize = 0;
    var steps: usize = 0;
    while (target.phase == .ready and post.snapshot() == null and steps < 40) : (steps += 1) {
        _ = target.step();
        if (channel.phase != .waiting) continue;
        try t.expect(post.snapshot() == null and post.armed);
        const deadline = channel.deadline.?;
        const size: usize = if (replies == 0) 4 else if (replies < 3) 8 else postinit.table_bytes;
        const expected: u32 = if (replies == 0) 0x20800137 else if (replies < 3) 0x20800138 else 0x20800a5c;
        const cursor = (session.tx_write + 62) % 63;
        const request = try transport.message.decode(session.profile,
            backing.?[command + 4096 + @as(usize, cursor) * 4096 ..][0..4096], session.tx_sequence - 1);
        const wire = request.payload;
        try t.expect(request.rpc.function == 76 and request.rpc.sequence == session.tx_sequence - 1);
        try t.expect(wire.len == 24 + size and std.mem.readInt(u32, wire[0..4], .little) == 0xcaf00001);
        try t.expect(std.mem.readInt(u32, wire[4..8], .little) == 0xcaf00003);
        try t.expect(std.mem.readInt(u32, wire[8..12], .little) == expected);
        try t.expect(std.mem.readInt(u32, wire[16..20], .little) == size and std.mem.readInt(u32, wire[20..24], .little) == 0);
        if (replies == 1 or replies == 2) {
            try t.expect(std.mem.readInt(u32, wire[24..28], .little) == @as(u32, if (replies == 1) 0 else 31));
            try t.expect(std.mem.allEqual(u8, wire[28..], 0));
        } else try t.expect(std.mem.allEqual(u8, wire[24..], 0));
        std.mem.writeInt(u32, backing.?[status + 64 ..][0..4], session.tx_write, .little);
        words[queue_head / 4] = 0x56565656;
        if (replies == 0) {
            // Run the actual native CPU sequencer while this control waits.
            // Its ACK cannot steal the request, ring queue0 or renew its bound.
            try deviceSequence(target, &.{ 3, 1 });
            try t.expect(target.step() == .progress);
            var sequence_steps: usize = 0;
            while (target.running.sequence.self_address != 0 and sequence_steps < 10) : (sequence_steps += 1) {
                clock += 1000;
                try t.expect(target.step() == .progress);
            }
            try t.expect(sequence_steps < 10 and channel.phase == .waiting and channel.deadline == deadline);
            try t.expect(session.tx_sequence == initial_sequence + 1 and words[queue_head / 4] == 0x56565656);
        }
        var response: [24 + postinit.table_bytes]u8 = @splat(0);
        @memcpy(response[0..wire.len], wire);
        if (replies == 0) {
            std.mem.writeInt(u32, response[24..28], 0x80000001, .little);
        } else if (replies < 3) {
            std.mem.writeInt(u32, response[28..32], if (replies == 1) 0x80000001 else 0x35, .little);
        } else {
            std.mem.writeInt(u32, response[24..28], 3, .little);
            for ([_]u16{50, 2, 60000}, 0..) |engine, index| {
                const at = 28 + index * 16;
                std.mem.writeInt(u16, response[at..][0..2], engine, .little);
                std.mem.writeInt(u32, response[at + 4 ..][0..4], @as(u32, 1) << @intCast(index), .little);
                std.mem.writeInt(u32, response[at + 8 ..][0..4], if (index == 0) 201 else if (index == 1) 150 else 0xffffffff, .little);
                std.mem.writeInt(u32, response[at + 12 ..][0..4], if (index == 1) 42 else 0xffffffff, .little);
            }
            @memset(response[24 + 2052 ..][0..14], 255);
            response[24 + 2054] = 2; response[24 + 2055] = 3;
        }
        if (scenario == .post_control_error and replies == 0) std.mem.writeInt(u32, response[12..16], 0x55, .little);
        if (scenario == .post_wrong_gpc and replies == 1) std.mem.writeInt(u32, response[24..28], 1, .little);
        if (scenario == .post_bad_vector and replies == 3) std.mem.writeInt(u32, response[36..40], 256, .little);
        if (scenario == .post_timeout and replies == 0) {
            clock = deadline;
        } else {
            try nativeEvent(session, 76, response[0..wire.len]);
            if (scenario == .post_ack_failure and replies == 3) range_failure_call = range_calls + 4;
        }
        _ = target.step();
        range_failure_call = 0;
        try t.expect(words[queue_head / 4] == 0x56565656);
        replies += 1;
    }
    try t.expect(steps < 40);
    const failed = scenario == .post_control_error or scenario == .post_wrong_gpc or scenario == .post_bad_vector or
        scenario == .post_ack_failure or scenario == .post_timeout;
    if (!failed) {
        const info = post.snapshot() orelse return error.MissingPostInit;
        try t.expect(replies == 4 and post.replies == 4 and channel.phase == .idle and !post.armed);
        try t.expect(info.gpc_mask == 0x80000001 and info.tpc_masks[0] == 0x80000001 and info.tpc_masks[31] == 0x35 and info.tpc_count == 6);
        try t.expect(info.entry_count == 3 and info.gsp_index.? == 0 and info.entries[0].stall == 201 and info.entries[0].nonstall == 0xffffffff);
        try t.expect(info.display_index.? == 1 and info.entries[1].nonstall == 42 and info.entries[2].engine == 60000);
        try t.expect(info.subtrees[0].first == 255 and info.subtrees[1].first == 2 and info.subtrees[1].last == 3);
        try t.expect(session.tx_sequence == initial_sequence + 4);
        @memset(&target.rx, 0xa5);
        try t.expect(post.snapshot().?.entries[0].stall == 201);
        return;
    }
    const failure = target.running.failure orelse return error.MissingPostFailure;
    try t.expectEqual(if (scenario == .post_control_error) error.Control else if (scenario == .post_wrong_gpc) error.Unexpected else
        if (scenario == .post_bad_vector) error.Vector else if (scenario == .post_ack_failure) error.Io else error.Deadline, failure);
    if (scenario == .post_control_error) try t.expect(post.last_status.? == 0x55);
    const receipt = session.pending;
    try t.expect(post.snapshot() == null and (receipt != null) == (scenario != .post_timeout));
    var recovery_steps: usize = 0;
    while (target.phase != .failed and recovery_steps < 12000) : (recovery_steps += 1) {
        clock += 1000;
        DeviceModel.tick(words, frts, false);
        _ = target.step();
    }
    try t.expect(recovery_steps < 12000 and target.phase == .failed and target.recovery.report != null and target.memory.?.retained);
    try t.expect(std.meta.eql(receipt, session.pending) and post.snapshot() == null and !target.reader.?.enabled);
}

const IrqModel = struct {
    var handler: ?a.IrqHandler = null;
    var context: usize = 0;
    var irq: u8 = 0;
    var flags: u32 = 0;
    var msi_result: i32 = 24;
    var register_result: i32 = 0;
    var unregister_result: i32 = 0;
    var wake_result: i32 = 0;
    var msi_enabled: bool = false;
    var in_irq: bool = false;
    var close_during_irq: bool = false;
    var close_blocked: bool = false;
    var wakes: usize = 0;
    fn reset() void {
        std.debug.assert(handler == null and !msi_enabled and !in_irq);
        msi_result = 24; register_result = 0; unregister_result = 0;
        wake_result = 0; close_during_irq = false; close_blocked = false; wakes = 0;
    }
    fn enableMsi(_: u8, _: u8, _: u8, _: u8) callconv(.c) i32 {
        std.debug.assert(!in_irq and !msi_enabled);
        if (msi_result >= 0) msi_enabled = true;
        return msi_result;
    }
    fn disableMsi(_: u8, _: u8, _: u8, _: u8) callconv(.c) i32 {
        std.debug.assert(!in_irq and handler == null and msi_enabled);
        msi_enabled = false;
        return 0;
    }
    fn register(line: u8, callback: a.IrqHandler, raw: usize, options: u32) callconv(.c) i32 {
        std.debug.assert(!in_irq and handler == null);
        if (register_result != 0) return register_result;
        irq = line; handler = callback; context = raw; flags = options;
        return 0;
    }
    fn unregister(line: u8, callback: a.IrqHandler, raw: usize) callconv(.c) i32 {
        std.debug.assert(!in_irq and handler == callback and irq == line and context == raw);
        const owner: *@import("gsp_irq.zig").Owner = @ptrFromInt(raw);
        std.debug.assert(@atomicLoad(u32, &owner.gate, .acquire) == 0 and owner.lease.valid());
        if (unregister_result != 0) return unregister_result;
        handler = null;
        return 0;
    }
    fn wake(raw: usize) i32 {
        std.debug.assert(in_irq);
        wakes += 1;
        const target: *@import("gsp_device.zig").Device = @ptrFromInt(raw);
        if (close_during_irq) {
            // Deterministically stop while the actual callback is pinned.
            // It must retain its lease/registration and defer unarm to close.
            close_blocked = !target.interrupts.close();
            std.debug.assert(target.interrupts.registered and target.interrupts.lease.valid());
        }
        return wake_result;
    }
    fn dispatch(line: u8) u32 {
        in_irq = true;
        defer in_irq = false;
        return handler.?(line, context);
    }
};

fn checkDeviceIrq(target: *@import("gsp_device.zig").Device, words: []u32, frts: u64, scenario: anytype) !void {
    const irqs = @import("gsp_irq.zig");
    const endpoint = &target.interrupts;
    var checkpoint: u8 = 0;
    errdefer |err| std.debug.print("GSP IRQ model checkpoint={d} error={s} phase={s} device={?} irq={d}/{d} gate={d} registered={} calls={d} events={d}\n",
        .{ checkpoint, @errorName(err), @tagName(target.phase), target.failure, endpoint.irq, endpoint.last_status,
            endpoint.gate, endpoint.registered, range_calls, target.running.snapshot.events });
    const before_open = range_calls;
    if (scenario == .irq_register_error) IrqModel.register_result = -5;
    if (scenario == .irq_msi_uncertain) IrqModel.msi_result = -4;
    try t.expect(target.step() == .progress);
    try t.expect(range_calls == before_open);
    const install_failed = scenario == .irq_register_error or scenario == .irq_msi_uncertain;
    if (!install_failed) {
        checkpoint = 1;
        try t.expect(endpoint.registered and endpoint.lease.valid() and endpoint.bit == 512 and endpoint.leaf == 6 and endpoint.subtree == 8);
        try t.expect(IrqModel.flags == @as(u32, if (scenario == .irq_intx) a.irq_flag_shared | a.irq_flag_level_low else a.irq_flag_msi));
        try t.expect(IrqModel.irq == @as(u8, if (scenario == .irq_intx) 11 else 24));
        try t.expect(words[irqs.reg.rearm / 4] == 8 and words[(irqs.reg.allow + 24) / 4] == 512);
        for (0..8) |leaf| try t.expect(words[irqs.reg.block / 4 + leaf] == 0xffffffff);
        checkpoint = 2;
        // A foreign/shared interrupt cannot consume the GSP queue.
        const sequence = target.session.?.tx_sequence;
        const events = target.running.snapshot.events;
        try t.expect(IrqModel.dispatch(IrqModel.irq + 1) == 0);
        words[irqs.reg.top / 4] = 0;
        try t.expect(IrqModel.dispatch(IrqModel.irq) == 0 and IrqModel.wakes == 0);
        var print: [11]u8 = @splat(0);
        std.mem.writeInt(u32, print[4..8], 3, .little);
        @memcpy(print[8..], "IRQ");
        try nativeEvent(&target.session.?, 0x100c, &print);
        const calls = range_calls;
        const pending = target.session.?.pending;
        checkpoint = 3;
        words[irqs.reg.top / 4] = 8;
        words[(irqs.reg.leaf + 24) / 4] = 512;
        words[irqs.reg.mask / 4] = 0xff;
        words[irqs.reg.status / 4] = if (scenario == .irq_cause or scenario == .irq_unregister_failure) 0x42 else 0x40;
        words[irqs.reg.rearm / 4] = 0;
        if (scenario == .irq_wake_failure) IrqModel.wake_result = -1;
        IrqModel.close_during_irq = scenario == .irq_close_busy;
        try t.expect(IrqModel.dispatch(IrqModel.irq) == a.irq_result_handled);
        checkpoint = 4;
        try t.expect(IrqModel.wakes == 1 and endpoint.interrupts == 1 and endpoint.messages == 1);
        try t.expect(range_calls == calls and target.session.?.tx_sequence == sequence and target.running.snapshot.events == events);
        try t.expect(std.meta.eql(pending, target.session.?.pending));
        try t.expect(words[irqs.reg.retrigger / 4] == 1 and words[(irqs.reg.leaf + 24) / 4] == 512);
        if (scenario == .irq_close_busy) {
            checkpoint = 5;
            try t.expect(IrqModel.close_blocked and endpoint.gate == 0 and words[irqs.reg.rearm / 4] == 0);
            try t.expect(endpoint.registered and endpoint.lease.valid());
            try t.expect(target.stop() and endpoint.closed and IrqModel.handler == null and !IrqModel.msi_enabled);
            const closed_writes = words[irqs.reg.block / 4 + 6];
            try t.expect(target.stop() and words[irqs.reg.block / 4 + 6] == closed_writes);
            return;
        }
        const fatal = scenario == .irq_cause or scenario == .irq_unregister_failure or scenario == .irq_wake_failure;
        if (fatal) {
            checkpoint = 6;
            try t.expect(endpoint.failed() and endpoint.gate == 0 and words[irqs.reg.rearm / 4] == 0);
            if (scenario != .irq_wake_failure) try t.expect(endpoint.last_raw == 0x42 and words[irqs.reg.mask_clear / 4] == 2 and words[irqs.reg.clear / 4] == 2);
            if (scenario == .irq_unregister_failure) IrqModel.unregister_result = -5;
            try t.expect(target.step() == .progress and target.failure.? == error.Interrupt);
        } else {
            checkpoint = 7;
            try t.expect(!endpoint.failed() and words[irqs.reg.clear / 4] == 0x40 and words[irqs.reg.rearm / 4] == 8);
            try t.expect(target.step() == .progress and target.running.snapshot.events == events + 1);
            try t.expect(target.session.?.pending == null and target.phase == .ready);
            return;
        }
    }
    checkpoint = 8;
    try t.expect(target.phase == .recovering and !target.recovery_started);
    _ = target.step();
    const retained_irq = scenario == .irq_msi_uncertain or scenario == .irq_unregister_failure;
    if (retained_irq) {
        try t.expect(!target.recovery_started and endpoint.lease.valid() and target.memory.?.retained);
        try t.expect(target.port.phase == .runtime); // No reset before retirement.
        clock = target.recovery_deadline;
        _ = target.step();
        try t.expect(target.phase == .failed and target.recovery_failure.? == error.IrqRetirement and target.recovery.report == null);
    } else {
        var steps: usize = 0;
        while (target.phase != .failed and steps < 12000) : (steps += 1) {
            clock += 1000;
            DeviceModel.tick(words, frts, false);
            _ = target.step();
        }
        try t.expect(steps < 12000 and target.recovery.report != null and endpoint.closed and !endpoint.registered and !endpoint.msi);
    }
    try t.expect(target.memory.?.retained and target.display.?.firmware_owner == @intFromPtr(target));
}

fn devicePost(target: *@import("gsp_device.zig").Device, dp: bool, foreign: bool) !void {
    const graph = &target.running.graph.?;
    const owner = &graph.subscriptions.?;
    var bytes: [40]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], graph.reservation.client + @as(u32, @intFromBool(foreign)), .little);
    std.mem.writeInt(u32, bytes[4..8], if (dp) owner.plan.handles.dp_irq else owner.plan.handles.hotplug, .little);
    std.mem.writeInt(u32, bytes[8..12], if (dp) 7 else 1, .little);
    std.mem.writeInt(u32, bytes[12..16], 0x79, .little);
    std.mem.writeInt(u32, bytes[24..28], if (dp) 4 else 8, .little);
    bytes[28] = @intFromBool(!dp); // Exercise notify-list and addressed forms.
    // POST_EVENT's flexible payload starts at29; sizeof(header) is32.
    std.mem.writeInt(u32, bytes[29..33], if (dp) 0x82 else 0x80000005, .little);
    std.mem.writeInt(u32, bytes[33..37], 0x80000004, .little);
    try nativeEvent(&target.session.?, 0x1003, bytes[0..if (dp) @as(usize, 36) else 40]);
}

fn checkDeviceRm(target: *@import("gsp_device.zig").Device, words: []u32, frts: u64, scenario: anytype) !void {
    const objects = @import("gsp_objects.zig");
    const rm_names = @import("gsp_rm_names.zig");
    const running = &target.running;
    const session = &target.session.?;
    const command = init.queues_offset + init.command_offset;
    const status = init.queues_offset + init.status_offset;
    const original_sequence = session.tx_sequence;
    const vaspace_logs = DeviceModel.vaspace_logs;
    try t.expect(running.nativeAddressSpace() == null);
    var requests: usize = 0;
    var creates: usize = 0;
    var cleanups: usize = 0;
    var buffer_requests: usize = 0;
    var buffer_frees: usize = 0;
    var caps_requests: usize = 0;
    var steps: usize = 0;
    errdefer if (running.graph) |*value| if (value.control_buffer) |*control| {
        std.debug.print("control BO failure: host={?} failure={?} ready={} active={} cpu={} dma={} gpu={} synced={} releases={d} requests={d} frees={d} adapter={x}/{x} epoch={d}/{d}\n", .{
            control.host_rejected, control.failure, control.backing.prepared, ControlModel.active, ControlModel.cpu_mapped,
            ControlModel.mapped, ControlModel.gpu_mapped, ControlModel.synced, ControlModel.releases, buffer_requests, buffer_frees,
            control.backing.adapter, running.adapter_id, control.backing.epoch, running.epoch });
    };
    errdefer |err| std.debug.print("actual RM graph scenario={s} error={s} phase={s} failure={?} graph={s} requests={d} creates={d} frees={d}\n",
        .{@tagName(scenario), @errorName(err), @tagName(target.phase), target.failure,
            if (running.graph) |*graph| @tagName(graph.state) else "none", requests, creates, cleanups});
    try t.expect(running.rm_enabled and running.graph == null and running.nativeObject() == null and target.interrupts.registered);
    while (target.phase == .ready and running.nativeObject() == null and steps < 90) : (steps += 1) {
        _ = target.step();
        if (target.phase != .ready) break;
        const channel = running.activeChannel().?;
        if (channel.phase != .waiting) continue;
        const graph = &running.graph.?;
        try t.expect(channel != &running.channel.? and running.channel.?.phase == .handed_off);
        try t.expect(graph.base.plan.process_id == 0xffffffff and std.mem.allEqual(u8, &graph.base.plan.process_name, 0));
        try t.expect(graph.reservation.client == rm_names.client_base and graph.reservation.client != running.static_info.?.client);
        const deadline = channel.deadline.?;
        const cursor = (session.tx_write + 62) % 63;
        const request = try transport.message.decode(session.profile,
            backing.?[command + 4096 + @as(usize, cursor) * 4096 ..][0..4096], session.tx_sequence - 1);
        var response: [@max(objects.max_request_bytes, @import("gsp_buffer_wire.zig").max_request_bytes)]u8 = @splat(0);
        @memcpy(response[0..request.payload.len], request.payload);
        const function = request.rpc.function;
        const payload = request.payload;
        std.mem.writeInt(u32, backing.?[status + 64 ..][0..4], session.tx_write, .little);
        try t.expect(std.mem.readInt(u32, payload[0..4], .little) == graph.reservation.client);
        if (graph.state == .control_creating or graph.state == .control_destroying) {
            const control = &graph.control_buffer.?;
            if (control.caps_active) {
                const caps_wire = @import("gsp_memory_caps.zig");
                try t.expect(function == caps_wire.function and payload.len == caps_wire.bytes and caps_requests == 0);
                try t.expect(std.mem.readInt(u32, payload[4..8], .little) == graph.base.plan.handles.device and
                    std.mem.readInt(u32, payload[8..12], .little) == caps_wire.command and std.mem.allEqual(u8, payload[24..], 0));
                try t.expect(!ControlModel.active and !control.caps_checked and control.caps == null and !control.backing.retained);
                try t.expect(running.nativeControlBuffer() == null and running.nativeMemoryCapabilities() == null);
                const phase = channel.phase;
                channel.phase = .prepared;
                try target.port.owner.?.admit_command.?(target.port.owner.?.context, &target.port, deadline);
                var copy = control.*;
                try t.expect(!copy.matches(channel, deadline));
                try t.expectError(error.Stale, copy.poll());
                channel.phase = phase;
                caps_requests += 1;
                response[24..27].* = if (scenario == .memory_caps_none) .{0,0,0} else .{0x0f,0x81,0x12};
                if (scenario == .memory_caps_reject) std.mem.writeInt(u32, response[12..16], 0x51, .little);
                if (scenario == .memory_caps_wrong) response[4] ^= 1;
                if (scenario == .memory_caps_timeout) clock = deadline else {
                    try nativeReply(session, function, if (scenario == .memory_caps_rpc) 0x52 else 0,
                        response[0..if (scenario == .memory_caps_short) @as(usize, 26) else caps_wire.bytes]);
                    if (scenario == .memory_caps_ack) range_failure_call = range_calls + 4;
                }
                _ = target.step();range_failure_call = 0;
                continue;
            }
            const operation = control.operation.?;
            try t.expect(control.backing.retained and !control.backing.close());
            try t.expect(ControlModel.active and !ControlModel.cpu_mapped and ControlModel.mapped and ControlModel.synced);
            try t.expect(running.nativeControlBuffer() == null);
            const phase = channel.phase;
            channel.phase = .prepared;
            try target.port.owner.?.admit_command.?(target.port.owner.?.context, &target.port, deadline);
            var copy = control.*;
            try t.expect(!copy.matches(channel, deadline));
            try t.expectError(error.Stale, copy.poll());
            try t.expect(!copy.backing.close());
            channel.phase = phase;
            if (operation == .register or operation == .allocate or operation == .map) buffer_requests += 1 else buffer_frees += 1;
            var rpc_result: u32 = 0;
            var result_size = payload.len;
            switch (operation) {
                .register => {
                    try t.expect(function == 4 and payload.len == 80 and std.mem.readInt(u32, payload[12..16], .little) == 0x81);
                    for (ControlModel.pages, 0..) |page, i| try t.expect(std.mem.readInt(u64, payload[56 + 8 * i ..][0..8], .little) == page >> 12);
                    if (scenario == .control_register_reject) rpc_result = 0x51;
                    if (scenario == .control_register_reject or scenario == .outputs_empty) result_size = 0;
                },
                .allocate => {
                    try t.expect(function == 103 and payload.len == 160 and std.mem.readInt(u32, payload[12..16], .little) == 0x50a0);
                    std.mem.writeInt(u64, response[112..120], if (scenario == .control_bounds) 0x10000000000 else 0x600000, .little);
                    std.mem.writeInt(u64, response[120..128], 12287, .little);
                    if (scenario == .control_virtual_reject) std.mem.writeInt(u32, response[16..20], 0x52, .little);
                    if (scenario == .control_short) result_size = 32;
                },
                .map => {
                    try t.expect(function == 14 and payload.len == 56 and control.address == 0x600000);
                    std.mem.writeInt(u64, response[40..48], if (scenario == .control_map_address) 0x700000 else control.address, .little);
                    if (scenario == .control_map_reject) std.mem.writeInt(u32, response[48..52], 0x53, .little);
                },
                .unmap => {
                    try t.expect(function == 15 and payload.len == 40 and std.mem.readInt(u32, payload[16..20], .little) == 0);
                    if (scenario == .control_unmap) std.mem.writeInt(u32, response[32..36], 0x54, .little);
                },
                .free_virtual, .free_memory => {
                    try t.expect(function == 10 and payload.len == 16);
                    if (scenario == .control_free) std.mem.writeInt(u32, response[12..16], 0x55, .little);
                },
            }
            if (scenario == .control_timeout and operation == .map) clock = deadline else {
                try nativeReply(session, function, rpc_result, response[0..result_size]);
                if (scenario == .control_ack and operation == .map) range_failure_call = range_calls + 4;
            }
            _ = target.step();range_failure_call = 0;
            continue;
        }
        const destroying = graph.state == .events_destroying or graph.state == .vaspace_destroying or graph.state == .i2c_destroying or graph.state == .base_destroying;
        const allocating_vaspace = graph.state == .vaspace_creating;
        var length = payload.len;
        var result: u32 = 0;
        if (destroying) {
            if (scenario == .rm_base_reject) {
                try t.expect(cleanups == 0 and function == 10 and std.mem.readInt(u32, payload[8..12], .little) == graph.reservation.client);
            } else {
                const expected = [_]u32{ graph.subscriptions.?.plan.handles.hotplug,
                    graph.subscriptions.?.plan.handles.hotplug, graph.base.plan.handles.vaspace, graph.base.plan.handles.i2c, graph.base.plan.handles.display,
                    graph.base.plan.handles.subdevice, graph.base.plan.handles.device, graph.reservation.client };
                try t.expect(cleanups < expected.len);
                if (cleanups == 0) {
                    try t.expect(function == 76 and std.mem.readInt(u32, payload[24..28], .little) == 1 and
                        std.mem.readInt(u32, payload[28..32], .little) == 0);
                } else try t.expect(function == 10 and std.mem.readInt(u32, payload[8..12], .little) == expected[cleanups]);
            }
            if (scenario == .rm_free_error) result = 0x66;
            if (scenario == .rm_vaspace_free and graph.state == .vaspace_destroying) result = 0x66;
            cleanups += 1;
        } else {
            const expected_functions = [_]u32{ 103, 103, 103, 103, 103, 103, 103, 76, 103, 76 };
            const expected_classes = [_]u32{ 0, 0x80, 0x2080, 0x73, 0x402c, 0x90f1, 0x7e, 0, 0x7e, 0 };
            try t.expect(creates < expected_functions.len and function == expected_functions[creates]);
            if (function == 103) try t.expect(std.mem.readInt(u32, payload[12..16], .little) == expected_classes[creates]);
            if (creates == 0) {
                try t.expect(payload.len == 152 and std.mem.readInt(u32, payload[36..40], .little) == 0xffffffff);
                try t.expect(std.mem.allEqual(u8, payload[40..], 0));
                // Inject only host metadata to challenge the real notifier's
                // identity checks; neither rejection may issue queue/MMIO I/O.
                const io = target.port.owner.?;
                const saved_request = channel.request;
                const original_function = channel.function;
                const before_binding = range_calls;
                var foreign_request: [objects.max_request_bytes]u8 = @splat(0);
                @memcpy(foreign_request[0..saved_request.len], saved_request);
                channel.phase = .prepared;
                channel.request = foreign_request[0..saved_request.len];
                try t.expectError(error.Binding, io.admit_command.?(io.context, &target.port, deadline));
                channel.request = saved_request;
                channel.function = 76;
                try t.expectError(error.Binding, io.admit_command.?(io.context, &target.port, deadline));
                channel.function = original_function;
                try io.admit_command.?(io.context, &target.port, deadline);
                var copied_graph = graph.*;
                try t.expect(!copied_graph.matches(channel, deadline));
                channel.phase = .waiting;
                try t.expect(range_calls == before_binding and session.state == .active);
                // The old runtime cannot re-use the transferred queue token.
                try t.expectError(error.State, running.channel.?.poll(deadline));
                try t.expect(session.state == .active and channel.phase == .waiting);
                try deviceSequence(target, &.{ 3, 1 });
                try t.expect(target.step() == .progress and running.sequence.self_address != 0);
                for (0..10) |_| {
                    if (running.sequence.self_address == 0) break;
                    clock += 1000;
                    _ = target.step();
                }
                try t.expect(running.sequence.self_address == 0 and channel.deadline == deadline and channel.phase == .waiting);
                try nativeEvent(session, 0x101c, &.{1});
                try t.expect(target.step() == .progress and channel.in_lockdown and !running.channel.?.in_lockdown);
                try t.expectError(error.Lockdown, io.access(io.context, .read, @import("gsp_core.zig").reg.mailbox0));
                try nativeEvent(session, 0x101c, &.{0});
                try t.expect(target.step() == .progress and !channel.in_lockdown and channel.deadline == deadline);
            }
            if (allocating_vaspace) {
                try t.expect(creates == 5 and payload.len == 80 and graph.address_space.?.info == null and running.nativeAddressSpace() == null);
                try t.expect(std.mem.readInt(u32, payload[8..12], .little) == graph.base.plan.handles.vaspace);
                try t.expect(std.mem.readInt(u32, payload[64..68], .little) == 65536);
                try t.expect(std.mem.allEqual(u8, payload[32..64], 0) and std.mem.allEqual(u8, payload[68..80], 0));
                // Exact admission also protects the new allocation; an old
                // runtime token cannot submit the same bytes on its behalf.
                const phase = channel.phase;
                channel.phase = .prepared;
                try target.port.owner.?.admit_command.?(target.port.owner.?.context, &target.port, deadline);
                var copy = graph.address_space.?;
                try t.expect(!copy.matches(channel, deadline));
                channel.phase = phase;
            }
            if (creates == 9) {
                try devicePost(target, false, scenario == .rm_foreign_event);
                _ = target.step();
                if (scenario == .rm_foreign_event) break;
                try t.expect(channel.phase == .waiting and channel.deadline == deadline and graph.subscriptions.?.changes.serial == 1);
            }
            if (scenario == .rm_base_reject and creates == 1) result = 0x55;
            if (scenario == .rm_i2c_reject and creates == 4) result = 0x56;
            if ((scenario == .rm_event_reject or scenario == .rm_free_error or scenario == .rm_vaspace_free or
                scenario == .control_unmap or scenario == .control_free or scenario == .control_dma_unmap or scenario == .control_release or scenario == .control_gpu_release) and creates == 7) result = 0x55;
            if (scenario == .rm_vaspace_reject and allocating_vaspace) result = 0x51;
            creates += 1;
        }
        // Responses may be the original fixed allocation result only.
        if (function == 103) length = 32;
        if (allocating_vaspace and result == 0) {
            length = if (scenario == .rm_vaspace_short) 32 else 80;
            std.mem.writeInt(u64, response[40..48], 0x100000000, .little); // Actual byte length, not limit.
            std.mem.writeInt(u64, response[72..80], if (scenario == .rm_vaspace_bounds) (@as(u64, 1) << 49) - 4096 else 0x200000, .little);
        }
        std.mem.writeInt(u32, response[if (function == 103) @as(usize, 16) else 12 ..][0..4], result, .little);
        if (function == 76 and result == 0) {
            response[32] = 1;
            std.mem.writeInt(u32, response[36..40], 0xdeadbeef, .little);
        }
        if ((scenario == .rm_timeout and requests == 0) or (scenario == .rm_vaspace_timeout and allocating_vaspace)) {
            clock = deadline;
        } else {
            try nativeEvent(session, function, response[0..length]);
            if ((scenario == .rm_ack_failure and creates == 10) or (scenario == .rm_vaspace_ack and allocating_vaspace)) range_failure_call = range_calls + 4;
        }
        _ = target.step();
        range_failure_call = 0;
        requests += 1;
    }
    try t.expect(steps < 90);
    if (target.phase == .ready) {
        const graph = &running.graph.?;
        const object = running.nativeObject() orelse return error.MissingRmObjects;
        try t.expect(creates == 10 and requests == 10 and cleanups == 0 and graph.state == .loaned);
        try t.expect(object.client == graph.reservation.client and object.display == graph.base.plan.handles.display);
        try t.expect(session.tx_sequence == original_sequence + 10 + caps_requests + buffer_requests + buffer_frees and running.activeChannel() == &running.channel.?);
        try t.expect(DeviceModel.vaspace_logs == vaspace_logs + 1);
        if (scenario == .rm_vaspace_reject) {
            try t.expect(running.nativeAddressSpace() == null and graph.address_space.?.rejected.? == 0x51);
            try t.expect(running.nativeMemoryCapabilities() == null and caps_requests == 0);
        } else {
            const address_space = running.nativeAddressSpace() orelse return error.MissingAddressSpace;
            try t.expect(address_space.epoch == session.epoch and address_space.client == graph.reservation.client);
            try t.expect(address_space.handle == graph.base.plan.handles.vaspace and address_space.base == 0x200000);
            try t.expect(address_space.bytes == 0x100000000 and address_space.big_page_bytes == 65536);
            if (running.nativeControlBuffer()) |info| {
                try t.expect(info.address == 0x600000 and info.bytes == 12288 and info.epoch == session.epoch and buffer_requests == 3);
                const caps = running.nativeMemoryCapabilities() orelse return error.MissingCapabilities;
                try t.expect(caps_requests == 1 and caps.binding.epoch == session.epoch and caps.binding.device == graph.base.plan.handles.device);
                const present = scenario != .memory_caps_none;
                try t.expect(caps.renderSystem() == present and caps.scanoutSystem() == present and caps.gpuCachedSystem() == present and caps.blocklinear() == present);
                try t.expect(caps.gobBytes() == @as(u16, if (present) 512 else 0) and caps.genericPageKind() == @as(u8, if (present) 6 else 0xfe));
                graph.control_buffer.?.caps.?.binding.epoch += 1;
                try t.expect(running.nativeMemoryCapabilities() == null and running.nativeControlBuffer() == null);
                graph.control_buffer.?.caps.?.binding.epoch -= 1;
                try t.expect(ControlModel.active and ControlModel.synced and ControlModel.releases == 0);
                try t.expect(!graph.control_buffer.?.backing.close());
                const backing_owner = &graph.control_buffer.?.backing;
                const original_page = backing_owner.pages[0];
                backing_owner.pages[0] += 4096;
                try t.expect(running.nativeControlBuffer() == null);
                backing_owner.pages[0] = original_page;
                try t.expect(running.nativeControlBuffer() != null);
                graph.address_space.?.info.?.handle += 1;
                try t.expect(running.nativeControlBuffer() == null);
                graph.address_space.?.info.?.handle -= 1;
                try t.expect(running.nativeControlBuffer() != null);
            } else {
                try t.expect(ControlModel.releases == @as(usize, if (scenario == .memory_caps_reject) 0 else 1) and !ControlModel.active and !ControlModel.cpu_mapped and !ControlModel.mapped);
                try t.expect(graph.control_buffer.?.rejected != null or graph.control_buffer.?.host_rejected != null);
                if (scenario == .memory_caps_reject) try t.expect(caps_requests == 1 and buffer_requests == 0 and buffer_frees == 0 and running.nativeMemoryCapabilities() == null);
            }
        }
        if (scenario == .rm_i2c_reject) try t.expect(object.i2c == 0 and !graph.i2c.?.live and graph.i2c.?.rejected.? == 0x56)
        else try t.expect(object.i2c == graph.base.plan.handles.i2c and graph.i2c.?.live);
        try t.expect(session.pending == null and graph.base.exchange.phase == .handed_off and graph.subscriptions.?.exchange.phase == .handed_off);
        const first = try running.takeDisplayChanges();
        try t.expect(first.serial == 1 and first.plug == 0x80000005 and first.unplug == 0x80000004 and first.dp_irq == 0);
        try devicePost(target, true, false);
        if (scenario == .rm_event_ack) range_failure_call = range_calls + 4;
        _ = target.step();
        range_failure_call = 0;
        if (scenario != .rm_event_ack) {
            const changes = try running.takeDisplayChanges();
            try t.expect(changes.serial == 2 and changes.plug == 0 and changes.unplug == 0 and changes.dp_irq == 0x82);
            const cleared = try running.takeDisplayChanges();
            try t.expect(cleared.serial == 2 and cleared.dp_irq == 0);
            try t.expect(running.snapshot.hotplug_events == 1 and running.snapshot.dp_irq_events == 1 and running.nativeObject() != null);
            return;
        }
    }
    const graph = &running.graph.?;
    try t.expect(running.nativeObject() == null and running.failure != null and target.phase == .recovering);
    try t.expect(running.nativeAddressSpace() == null);
    try t.expect(running.nativeControlBuffer() == null);
    try t.expect(running.nativeMemoryCapabilities() == null);
    if (std.mem.startsWith(u8, @tagName(scenario), "memory_caps_")) {
        const control = &graph.control_buffer.?;
        try t.expect(!ControlModel.active and !control.caps_checked and control.caps == null and !control.backing.retained);
        try t.expect(caps_requests == 1 and buffer_requests == 0 and buffer_frees == 0);
    }
    if (std.mem.startsWith(u8, @tagName(scenario), "control_")) {
        const control = &graph.control_buffer.?;
        try t.expect(ControlModel.active and control.info() == null);
        try t.expectError(error.Retained, session.rm_names.retire(graph.reservation));
        if (scenario == .control_dma_unmap or scenario == .control_release or scenario == .control_gpu_release) {
            try t.expect(buffer_frees == 3 and !control.mapped and !control.allocated and !control.registered);
        } else {
            try t.expect(control.backing.retained and !control.backing.close());
            try t.expect(!ControlModel.cpu_mapped and ControlModel.mapped);
        }
    }
    if (scenario == .rm_base_reject or scenario == .rm_event_reject) {
        try t.expect(running.failure.? == error.RmRejected and running.rm_rejection.? == 0x55 and graph.state == .finished);
        try t.expect(cleanups == @as(usize, if (scenario == .rm_base_reject) 1 else 8));
        try t.expectError(error.Stale, session.rm_names.validate(graph.reservation));
    } else {
        try t.expectError(error.Retained, session.rm_names.retire(graph.reservation));
        if (scenario == .rm_free_error) try t.expect(cleanups == 1 and running.rm_rejection.? == 0x55);
        if (scenario == .rm_vaspace_free) try t.expect(cleanups == 3 and graph.address_space.?.info != null and graph.address_space.?.state == .failed);
        if (scenario == .rm_vaspace_short or scenario == .rm_vaspace_bounds or scenario == .rm_vaspace_ack or scenario == .rm_vaspace_timeout) {
            // The parent graph can detect its shared deadline before the
            // child polls. Retention and failed session are authoritative;
            // a child-local phase is not a separate teardown guarantee.
            try t.expect(cleanups == 0 and graph.address_space.?.info == null and
                graph.address_space.?.exchange.session.state == .failed and DeviceModel.vaspace_logs == vaspace_logs);
            try t.expect((session.pending == null) == (scenario == .rm_vaspace_timeout));
        }
    }
    const receipt = session.pending;
    const sent = session.tx_sequence;
    var recovery_steps: usize = 0;
    while (target.phase != .failed and recovery_steps < 12000) : (recovery_steps += 1) {
        clock += 1000;
        DeviceModel.tick(words, frts, false);
        _ = target.step();
    }
    try t.expect(recovery_steps < 12000 and target.recovery.report != null and target.memory.?.retained);
    try t.expect(target.interrupts.closed and std.meta.eql(receipt, session.pending) and session.tx_sequence == sent);
}

fn outputWord(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn outputEdid(bytes: []u8, incomplete: bool, corrupt: bool) void {
    @memset(bytes, 0);
    @memcpy(bytes[0..8], &[_]u8{ 0, 255, 255, 255, 255, 255, 255, 0 });
    bytes[8] = 0x48;
    bytes[9] = 0xcf; // Synthetic RFO monitor, never a Hisense measurement.
    bytes[18] = 1;
    bytes[19] = 4;
    bytes[20] = 0x80;
    @memset(bytes[38..54], 1);
    for (0..4) |i| bytes[54 + i * 18 + 3] = 0x10;
    bytes[126] = if (incomplete) 2 else 1;
    @memcpy(bytes[128..144], &[_]u8{ 2, 3, 16, 0x40, 0x41, 16, 0x23, 0x09, 7, 7, 0x65, 3, 12, 0, 0x10, 0 });
    for (0..2) |i| {
        var sum: u8 = 0;
        const block = bytes[i * 128 ..][0..128];
        for (block) |value| sum +%= value;
        block[127] = 0 -% sum;
    }
    if (corrupt) bytes[0] = 1;
}
fn outputEdidFull(bytes: *[4096]u8) void {
    @memset(bytes, 0);
    outputEdid(bytes[0..256], false, false);
    bytes[126] = 31;
    bytes[127] -%= 30;
    for (2..32) |index| { bytes[index * 128] = 0x99; bytes[index * 128 + 127] = 0 -% @as(u8, 0x99); }
}
fn allocateContextStorage(target: *@import("gsp_device.zig").Device, bytes: u64, deadline: u64) !@import("gsp_runtime.zig").BufferHandle {
    return allocateContextBuffer(target, bytes, deadline, true);
}
fn allocateContextBuffer(target: *@import("gsp_device.zig").Device, bytes: u64, deadline: u64, private: bool) !@import("gsp_runtime.zig").BufferHandle {
    const handle = if (private) try target.running.allocateNativeStorage(bytes, deadline) else try target.running.allocateNativeBuffer(bytes, deadline);
    return finishContextBuffer(target, handle, deadline);
}
fn finishContextBuffer(target: *@import("gsp_device.zig").Device, handle: @import("gsp_runtime.zig").BufferHandle, deadline: u64) !@import("gsp_runtime.zig").BufferHandle {
    _ = deadline;
    const model = @import("gsp_vram_test_model.zig").Model;
    const running = &target.running; const session = &target.session.?;
    const command = init.queues_offset + init.command_offset; const status = init.queues_offset + init.status_offset;
    var steps: usize = 0;
    while (target.phase == .ready and running.native_active != null and steps < 80) : (steps += 1) {
        _ = target.step();
        if (target.phase != .ready or running.native_active == null) break;
        const owner = running.native_buffers[running.native_active.?].owner.?;
        const private = owner.storage_policy != null;
        const channel = running.activeChannel().?;
        if (channel.phase != .waiting) continue;
        const cursor = (session.tx_write + 62) % 63;
        const record = try transport.message.decode(session.profile, backing.?[command + 4096 + cursor * 4096..][0..4096], session.tx_sequence - 1);
        try t.expectEqualSlices(u8, channel.request, record.payload);
        try t.expect(owner.info() == null);
        var response: [160]u8 = @splat(0); @memcpy(response[0..channel.request.len], record.payload);
        const slot_index = owner.reservation.buffer.id - 801;
        switch (owner.operation.?) {
            .allocate_memory, .allocate_virtual => {
                const physical = owner.operation.? == .allocate_memory;
                std.mem.writeInt(u64, response[112..120], if (physical) (if (private) owner.storage_policy.?.physical_bytes / 2 else @as(u64, 0x20000000)) + slot_index * 65536 else model.address(slot_index), .little);
                std.mem.writeInt(u64, response[120..128], owner.bytes - 1, .little);
                if (physical) try t.expect(((std.mem.readInt(u32, response[56..60], .little) >> 27) & 3) == if (private) @as(u32, 2) else 1);
            },
            .map => std.mem.writeInt(u64, response[40..48], model.address(slot_index), .little),
            else => return error.Unexpected,
        }
        std.mem.writeInt(u32, backing.?[status + 64..][0..4], session.tx_write, .little);
        try nativeReply(session, channel.function, 0, response[0..channel.request.len]); _ = target.step();
    }
    try t.expect(steps < 80 and target.phase == .ready and (try running.nativeBufferStatus(handle)).info != null);
    return handle;
}
fn checkDeviceDisplayEngine(target: *@import("gsp_device.zig").Device, scenario: []const u8) !void {
    const runtime = @import("gsp_runtime.zig");
    const vectors = @import("gsp_display_engine_test.zig");
    const wire = runtime.display_engine.wire;
    const running = &target.running; const session = &target.session.?;
    const deadline = clock + 5 * std.time.ns_per_s;
    const command = init.queues_offset + init.command_offset; const status = init.queues_offset + init.status_offset;
    const success = std.mem.eql(u8, scenario, "display_root_success");
    const unsupported = std.mem.eql(u8, scenario, "display_root_classes");
    const rejected = std.mem.eql(u8, scenario, "display_root_reject");
    const static_bad = std.mem.eql(u8, scenario, "display_root_static");
    const preserve_bad = std.mem.eql(u8, scenario, "display_root_preserve");
    const free_bad = std.mem.eql(u8, scenario, "display_root_free");
    const ack_bad = std.mem.eql(u8, scenario, "display_root_ack");
    const expired = std.mem.eql(u8, scenario, "display_root_timeout");
    const wrong = std.mem.eql(u8, scenario, "display_root_wrong");
    const hold = try running.reservation.?.binding(.metadata);
    var prior: ?runtime.DisplayEngineHandle = null;
    errdefer |err| std.debug.print("display engine {s}: {s} phase={s} failure={?} active={} state={s}\n",
        .{scenario,@errorName(err),@tagName(target.phase),target.failure,running.display_engine_active,
            if (running.display_engine_owner) |*value| @tagName(value.state) else "none"});
    for (0..@as(usize, if (success) 2 else 1)) |_| {
        const handle = try running.createDisplayEngine(deadline);
        if (prior) |old| { try t.expect(old.root != handle.root); try t.expectError(error.Stale, running.displayEngineStatus(old)); }
        var forged = handle; forged.epoch += 1; try t.expectError(error.Stale, running.displayEngineStatus(forged));
        try t.expectError(error.Busy, running.createDisplayEngine(deadline));
        try t.expectError(error.State, running.allocateNativeBuffer(4096, deadline));
        var retiring = false; var requests: [5]u32 = @splat(0); var interleaved = false;
        var steps: usize = 0;
        while (target.phase == .ready and steps < 80) : (steps += 1) {
            _ = target.step();
            if (target.phase != .ready) break;
            if (!running.display_engine_active) {
                if (retiring) break;
                const current = try running.displayEngineStatus(handle);
                try t.expect(current.state == .handed_off);
                if (unsupported or rejected) {
                    try t.expect(current.info == null and current.unavailable == unsupported and (current.rejected != null) == rejected);
                    try t.expect(!running.display_engine_owner.?.namespace_live and !running.display_engine_owner.?.allocation_possible);
                } else {
                    const value = current.info orelse return error.Unexpected;
                    try t.expect(value.binding.root == handle.root and value.hardware.heads == 4 and value.hardware.windows == 255 and value.hardware.channels == 81);
                    try t.expect(value.binding.internal_client == running.static_info.?.client and value.binding.internal_subdevice == running.static_info.?.subdevice);
                }
                try t.expectError(error.Busy, running.beginDestroyGraph(deadline, true));
                try running.retireDisplayEngine(handle, deadline); retiring = true; continue;
            }
            const owner = &running.display_engine_owner.?; const rpc = running.activeChannel().?;
            if (rpc.phase != .waiting) continue;
            const op = owner.operation.?; requests[@intFromEnum(op)] += 1;
            try t.expect(requests[@intFromEnum(op)] == 1 and owner.info() == null);
            const cursor = (session.tx_write + 62) % 63;
            const record = try transport.message.decode(session.profile, backing.?[command + 4096 + cursor * 4096..][0..4096], session.tx_sequence - 1);
            try t.expectEqualSlices(u8, rpc.request, record.payload);
            if (op == .static_info) try t.expect(wire.word(record.payload, 0) == running.static_info.?.client and wire.word(record.payload, 4) == running.static_info.?.subdevice);
            if (op == .allocate) try t.expect(record.payload.len == 32 and wire.word(record.payload, 12) == 0xc670 and wire.word(record.payload, 20) == 0);
            if (op == .preserve) try t.expect(owner.live and !owner.preserve and wire.word(record.payload, 28) == 1);
            if (op == .free) try t.expect(owner.live and owner.preserve and requests[@intFromEnum(wire.Operation.preserve)] == 1);
            // Device admission binds the actual owner, pointer, function and
            // fixed deadline, not merely a valid-looking copy of the bytes.
            if (op == .classes) {
                const io = target.port.owner.?; const saved = rpc.request; const old_function = rpc.function;
                var copy = owner.*; try t.expect(!copy.matches(rpc, deadline));
                var foreign: [wire.max_bytes]u8 = undefined; @memcpy(foreign[0..saved.len], saved);
                const before = range_calls; rpc.phase = .prepared; rpc.request = foreign[0..saved.len];
                try t.expectError(error.Binding, io.admit_command.?(io.context, &target.port, deadline));
                rpc.request = saved; rpc.function = 103;
                try t.expectError(error.Binding, io.admit_command.?(io.context, &target.port, deadline));
                rpc.function = old_function;
                try t.expectError(error.Binding, io.admit_command.?(io.context, &target.port, deadline + 1));
                try io.admit_command.?(io.context, &target.port, deadline);
                rpc.phase = .waiting; try t.expect(range_calls == before);
                try t.expectError(error.State, running.channel.?.poll(deadline));
            }
            if (op == .allocate and success and !interleaved) {
                try devicePost(target, false, false); _ = target.step();
                try t.expect(rpc.phase == .waiting and rpc.pending == null and owner.info() == null and rpc.deadline == deadline);
                interleaved = true;
            }
            var response: [wire.max_bytes]u8 = undefined;
            @memcpy(response[0..rpc.request.len], vectors.response(op));
            const header: usize = if (op == .allocate) 32 else if (op == .free) 16 else 24;
            @memcpy(response[0..header], record.payload[0..header]);
            if (op == .classes and unsupported) outputWord(&response, 24, 0);
            if (op == .static_info and static_bad) outputWord(&response, 36, 9);
            if (op == .static_info and wrong) response[4] ^= 1;
            if ((op == .allocate and rejected) or (op == .preserve and preserve_bad) or (op == .free and free_bad))
                outputWord(&response, if (op == .allocate) 16 else 12, 0x57);
            std.mem.writeInt(u32, backing.?[status + 64..][0..4], session.tx_write, .little);
            if (op == .allocate and expired) clock = deadline else {
                try nativeReply(session, rpc.function, 0, response[0..rpc.request.len]);
                if (op == .allocate and ack_bad) range_failure_call = range_calls + 4;
            }
            _ = target.step(); range_failure_call = 0;
        }
        try t.expect(steps < 80 and running.reservation.?.validates(hold) and target.memory.?.retained);
        if (success or unsupported or rejected) {
            try t.expect(target.phase == .ready and running.display_engine_owner == null and !running.display_engine_active);
            try t.expectError(error.Stale, running.displayEngineStatus(handle));
            try t.expect(requests[@intFromEnum(wire.Operation.allocate)] == @as(u32, if (unsupported) 0 else 1));
            try t.expect(requests[@intFromEnum(wire.Operation.free)] == @as(u32, if (success) 1 else 0));
            try t.expect(session.state == .active and session.pending == null and running.nativeObject() != null);
        } else {
            try t.expect(target.phase != .ready and running.failure != null and session.state == .failed);
            const owner = &running.display_engine_owner.?;
            try t.expect(owner.state == .failed and owner.namespace_live and owner.info() == null);
            try t.expect(owner.allocation_possible == (preserve_bad or free_bad or ack_bad or expired));
            if (preserve_bad) try t.expect(requests[@intFromEnum(wire.Operation.free)] == 0);
            if (free_bad) try t.expect(!owner.preserve and owner.live);
            if (ack_bad) try t.expect(owner.exchange.pending != null and session.pending != null and !owner.live);
            if (wrong or static_bad) try t.expect(requests[@intFromEnum(wire.Operation.allocate)] == 0);
            const before = range_calls;
            try t.expectError(error.State, running.retireDisplayEngine(handle, deadline + 1));
            try t.expect(range_calls == before and owner.namespace_live);
        }
        prior = handle;
    }
}
fn createTestDisplayRoot(target: *@import("gsp_device.zig").Device, deadline: u64, immediate: bool) !@import("gsp_runtime.zig").DisplayEngineHandle {
    const root_vectors = @import("gsp_display_engine_test.zig");
    const running = &target.running; const session = &target.session.?;
    const root_handle = try running.createDisplayEngine(deadline);
    var steps: usize = 0;
    while (running.display_engine_active and steps < 60) : (steps += 1) {
        _ = target.step(); try t.expect(target.phase == .ready);
        if (!running.display_engine_active) break;
        const root_owner = &running.display_engine_owner.?; const rpc = &root_owner.exchange;
        if (rpc.phase != .waiting) continue;
        const op = root_owner.operation.?;
        var response: [428]u8 = undefined; @memcpy(response[0..rpc.request.len], root_vectors.response(op));
        const header: usize = if (op == .allocate) 32 else 24; @memcpy(response[0..header], rpc.request[0..header]);
        if (op == .classes) { outputWord(&response, 24, if (immediate) 4 else 3); outputWord(&response, 32, 0xc67d); outputWord(&response, 36, 0xc67e); outputWord(&response, 40, if (immediate) 0xc67b else 0); }
        if (op == .static_info) outputWord(&response, 28, 9); // Windows 0 and 3 only.
        std.mem.writeInt(u32, backing.?[init.queues_offset + init.status_offset + 64..][0..4], session.tx_write, .little);
        try nativeReply(session, rpc.function, 0, response[0..rpc.request.len]); _ = target.step();
    }
    try t.expect(steps < 60 and !running.display_engine_active);
    return root_handle;
}
fn checkDeviceDisplayChannels(target: *@import("gsp_device.zig").Device, table: *a.DriverApi, words: []u32, scenario: []const u8) !void {
    const runtime = @import("gsp_runtime.zig");
    const native_model = @import("gsp_vram_test_model.zig").Model;
    const model = @import("gsp_display_test_model.zig").Model;
    const running = &target.running; const session = &target.session.?;
    const deadline = clock + 5 * std.time.ns_per_s;
    native_model.install(table, scenario); defer native_model.dispose(table);
    model.install(table, scenario, words);
    errdefer |err| std.debug.print("display DMA {s}: {s} phase={s} failure={?} root-active={} channel-active={?}\n",
        .{scenario,@errorName(err),@tagName(target.phase),target.failure,running.display_engine_active,running.display_channel_active});
    const root_handle = try createTestDisplayRoot(target, deadline, false);
    try t.expectError(error.State, running.createDisplayChannel(root_handle, .core, 0, deadline));
    const instance = try allocateContextStorage(target, 65536, deadline);
    try running.attachDisplayInstance(root_handle, instance, deadline);
    var steps: usize = 0;
    while (running.display_engine_active and target.phase == .ready and steps < 60) : (steps += 1) {
        _ = target.step(); if (!running.display_engine_active or target.phase != .ready) break;
        const root_owner = &running.display_engine_owner.?; const rpc = &root_owner.exchange;
        if (rpc.phase != .waiting) continue;
        try t.expect(root_owner.operation.? == .instance and rpc.request.len == 48 and root_owner.instance_possible and !root_owner.instance_bound);
        try t.expect(std.mem.readInt(u64, rpc.request[24..32], .little) == root_owner.instance_storage.info().?.physical.base);
        try t.expect(native_model.slots[0].imported and native_model.slots[0].gpu.lease.id != 0);
        var response: [48]u8 = undefined; @memcpy(&response, rpc.request);
        if (model.is("display_dma_instance_reject")) outputWord(&response, 12, 0x57);
        std.mem.writeInt(u32, backing.?[init.queues_offset + init.status_offset + 64..][0..4], session.tx_write, .little);
        try nativeReply(session, rpc.function, 0, &response);
        if (model.is("display_dma_instance_ack")) range_failure_call = range_calls + 4;
        _ = target.step(); range_failure_call = 0;
    }
    try t.expect(steps < 60);
    if (target.phase != .ready) {
        try t.expect((model.is("display_dma_instance_ack") or model.is("display_dma_instance_reject")) and target.failure != null);
        try t.expect(!running.display_engine_owner.?.instance_bound and running.display_engine_owner.?.instance_possible and native_model.charged == 65536 and native_model.slots[0].imported);
        if (model.is("display_dma_instance_ack")) try t.expect(session.pending != null);
        return;
    }
    try t.expect((try running.displayEngineStatus(root_handle)).info.?.instance_bound);
    try t.expectError(error.Retained, running.retireDisplayEngine(root_handle, deadline));
    try t.expectError(error.State, running.createDisplayChannel(root_handle, .window, 3, deadline));
    try t.expectError(error.Bounds, running.createDisplayChannel(root_handle, .core, 1, deadline));
    try running.releaseNativeBuffer(instance); // The device-owned instance stays reachable.
    try t.expect(!native_model.slots[0].reference and native_model.slots[0].imported and native_model.charged == 65536);
    const core_handle = try running.createDisplayChannel(root_handle, .core, 0, deadline);
    try pumpDisplayChannel(target, core_handle, deadline);
    if (target.phase == .ready) {
        const current = try running.displayChannelStatus(core_handle);
        const rejected = model.is("display_dma_oom") or model.is("display_dma_pushbuffer") or model.is("display_dma_allocate");
        try t.expect(current.state == .handed_off and (current.info == null) == rejected);
        if (rejected) {
            try t.expect((current.host_rejected != null) == model.is("display_dma_oom"));
            try t.expect(!running.display_channels[0].?.namespace_live and !model.slots[0].active);
        } else {
            try t.expectError(error.Busy, running.createDisplayChannel(root_handle, .core, 0, deadline));
            try t.expectError(error.Unsupported, running.createDisplayChannel(root_handle, .window, 2, deadline));
            try t.expectError(error.Bounds, running.createDisplayChannel(root_handle, .window, 8, deadline));
            var forged = core_handle; forged.epoch += 1; try t.expectError(error.Stale, running.displayChannelStatus(forged));
            if (model.is("display_dma_success")) {
                const window_handle = try running.createDisplayChannel(root_handle, .window, 3, deadline);
                try pumpDisplayChannel(target, window_handle, deadline);
                try t.expect((try running.displayChannelStatus(window_handle)).info != null);
                const sequence = session.tx_sequence;
                try t.expect(!(try running.displayEngineStatus(root_handle)).info.?.immediate);
                try t.expectError(error.Unsupported, running.createDisplayChannel(root_handle, .immediate, 3, deadline));
                try t.expect(running.display_channels[12] == null and running.display_engine_owner.?.children[12] == 0 and session.tx_sequence == sequence);
                try t.expectError(error.Retained, running.retireDisplayChannel(core_handle, deadline));
                try t.expect(running.display_channel_active == null and model.slots[0].active and model.slots[1].active);
                try running.retireDisplayChannel(window_handle, deadline);
                try pumpDisplayChannel(target, window_handle, deadline);
                try t.expectError(error.Stale, running.displayChannelStatus(window_handle));
                try t.expect(model.released == 1 and model.slots[0].active and !model.slots[1].active);
            }
        }
        try running.retireDisplayChannel(core_handle, deadline);
        try pumpDisplayChannel(target, core_handle, deadline);
    }
    try t.expect(native_model.charged == 65536 and native_model.slots[0].imported and native_model.slots[0].gpu.lease.id != 0 and native_model.released == 0);
    if (target.phase == .ready) {
        try t.expectError(error.Stale, running.displayChannelStatus(core_handle));
        try t.expect(running.display_engine_owner.?.instance_storage.info() != null);
        try t.expectError(error.Retained, running.retireDisplayEngine(root_handle, deadline));
        try t.expectError(error.Busy, running.beginDestroyGraph(deadline, true));
        if (model.is("display_dma_success")) try t.expect(model.released == 2);
        try t.expect(target.stop());
    } else {
        try t.expect(target.failure != null and session.state == .failed and model.slots[0].active and model.released == 0);
        const dma_owner = &running.display_channels[0].?;
        try t.expect(dma_owner.namespace_live and !dma_owner.backing.close());
        if (model.is("display_dma_ack")) try t.expect(session.pending != null and !dma_owner.live and dma_owner.allocation_possible);
        if (model.is("display_dma_busy")) try t.expect(dma_owner.retirement_reads >= 3 and !dma_owner.hardware_retired);
        if (model.is("display_dma_release")) try t.expect(dma_owner.hardware_retired and !dma_owner.live);
        if (model.is("display_dma_fault")) try t.expect(dma_owner.retirement_reads == 0 and !dma_owner.hardware_retired);
    }
    _ = runtime;
}
fn pumpDisplayChannel(target: *@import("gsp_device.zig").Device, handle: @import("gsp_runtime.zig").DisplayChannelHandle, deadline: u64) !void {
    const model = @import("gsp_display_test_model.zig").Model;
    const wire = @import("gsp_display_channel_wire.zig");
    const vectors = @import("gsp_display_channel_test.zig");
    const running = &target.running; const session = &target.session.?;
    var steps: usize = 0; var observed = false; var interleaved = false;
    var checkpoint: []const u8 = "poll";
    errdefer |err| if (running.display_channels[handle.slot]) |*value| std.debug.print("display channel {s}: {s} step={d} check={s} state={s} rpc={s} op={?} reads={d} admit={} backing={?}\n",
        .{@tagName(value.config.kind),@errorName(err),steps,checkpoint,@tagName(value.state),@tagName(value.exchange.phase),value.operation,value.retirement_reads,value.admitsRetirement(deadline),value.backing.physical()});
    while (target.phase == .ready and running.display_channel_active != null and steps < 100) : (steps += 1) {
        const owner = &running.display_channels[handle.slot].?;
        if (owner.retirementPending()) {
            const ctl = try wire.controlRegister(owner.config.kind, owner.config.index);
            const stat = try wire.statusRegister(owner.config.kind, owner.config.index);
            // Hardware retirement uses the channel's fixed deadline after
            // the acknowledged RPC has returned to an empty idle Exchange.
            if (!observed) {
                const io = target.port.owner.?;
                var copied = owner.*;
                try t.expectError(error.Binding, io.admit_display_retirement.?(io.context, &target.port, &copied, deadline));
                try t.expectError(error.Binding, io.admit_display_retirement.?(io.context, &target.port, owner, deadline + 1));
                const saved = owner.config; owner.config.index += 1;
                try t.expectError(error.Binding, io.admit_display_retirement.?(io.context, &target.port, owner, deadline));
                owner.config = saved; checkpoint = "admit retirement";
                try io.admit_display_retirement.?(io.context, &target.port, owner, deadline);
                observed = true;
            }
            if (owner.retirement_reads == 1) { model.words[ctl / 4] = 0; model.words[stat / 4] = 1 << 26; }
            if (owner.retirement_reads == 2) model.words[stat / 4] = 1 << 31;
            if (owner.retirement_reads >= 3) {
                if (model.is("display_dma_busy")) clock = deadline else { model.words[ctl / 4] = 0; model.words[stat / 4] = 0; }
            }
            const slot_index = (owner.config.physical - model.address(0)) / 0x100000;
            try t.expect(model.slots[slot_index].active and model.slots[slot_index].dma.lease.id != 0 and !owner.backing.close());
            if (model.is("display_dma_fault") and !interleaved) {
                try nativeEvent(session, 0x10ff, &.{}); interleaved = true;
            }
        }
        _ = target.step();
        if (target.phase != .ready or running.display_channel_active == null) break;
        const rpc = &owner.exchange;
        if (rpc.phase != .waiting) continue;
        const op = owner.operation.?;
        try t.expect(owner.info() == null and owner.backing.physical() != null and owner.backing.retained);
        const cursor = (session.tx_write + 62) % 63;
        const record = try transport.message.decode(session.profile, backing.?[init.queues_offset + init.command_offset + 4096 + cursor * 4096..][0..4096], session.tx_sequence - 1);
        try t.expectEqualSlices(u8, rpc.request, record.payload);
        if (op == .pushbuffer) {
            const io = target.port.owner.?; const saved = rpc.request;
            var copied = owner.*; try t.expect(!copied.matches(rpc, deadline));
            var foreign: [80]u8 = undefined; @memcpy(foreign[0..saved.len], saved);
            rpc.phase = .prepared; rpc.request = foreign[0..saved.len];
            try t.expectError(error.Binding, io.admit_command.?(io.context, &target.port, deadline));
            rpc.request = saved; owner.request[32] ^= 1;
            try t.expectError(error.Binding, io.admit_command.?(io.context, &target.port, deadline));
            owner.request[32] ^= 1; checkpoint = "admit pushbuffer";
            try io.admit_command.?(io.context, &target.port, deadline);
            rpc.phase = .waiting;
        }
        if (op == .allocate and model.is("display_dma_success") and !interleaved) {
            try devicePost(target, false, false); _ = target.step();
            try t.expect(rpc.phase == .waiting and rpc.pending == null and !owner.live); interleaved = true;
        }
        var response: [80]u8 = undefined; @memcpy(response[0..rpc.request.len], rpc.request);
        if (op == .allocate) {
            @memcpy(response[48..56], vectors.response(owner.config.kind, op)[48..56]);
            const slot_index = (owner.config.physical - model.address(0)) / 0x100000;
            const slot = &model.slots[slot_index]; slot.hardware = true;
            slot.control = try wire.controlRegister(owner.config.kind, owner.config.index); slot.state = try wire.statusRegister(owner.config.kind, owner.config.index);
            if (!model.is("display_dma_allocate")) {
                model.words[slot.control / 4] = 0x13; model.words[slot.state / 4] = if (owner.config.kind == .core) 11 << 16 else 4 << 16;
            }
        }
        if ((op == .pushbuffer and model.is("display_dma_pushbuffer")) or (op == .allocate and model.is("display_dma_allocate")) or (op == .free and model.is("display_dma_free")))
            outputWord(&response, if (op == .allocate) 16 else 12, 0x57);
        std.mem.writeInt(u32, backing.?[init.queues_offset + init.status_offset + 64..][0..4], session.tx_write, .little);
        try nativeReply(session, rpc.function, 0, response[0..rpc.request.len]);
        if (op == .allocate and model.is("display_dma_ack")) range_failure_call = range_calls + 4;
        _ = target.step(); range_failure_call = 0;
    }
    try t.expect(steps < 100);
}
fn checkDeviceContexts(target: *@import("gsp_device.zig").Device, table: *a.DriverApi, scenario: []const u8) !void {
    const model = @import("gsp_vram_test_model.zig").Model;
    const runtime = @import("gsp_runtime.zig");
    const vectors = @import("gsp_context_test.zig");
    const wire = runtime.execution_context.wire;
    const running = &target.running;
    const session = &target.session.?;
    const deadline = clock + 5 * std.time.ns_per_s;
    const command = init.queues_offset + init.command_offset;
    const status = init.queues_offset + init.status_offset;
    model.install(table, scenario); defer model.dispose(table);
    const copy_case = std.mem.startsWith(u8, scenario, "context_copy") or std.mem.startsWith(u8, scenario, "context_upload") or std.mem.startsWith(u8, scenario, "context_display");
    const fifo = std.mem.startsWith(u8, scenario, "context_fifo") or copy_case;
    const methods = std.mem.startsWith(u8, scenario, "context_methods") or fifo;
    const success = model.is("context_success") or model.is("context_methods");
    var handles: [2]runtime.ContextHandle = undefined;
    var held: ?runtime.execution_context.Child = null;
    var allocations: usize = 0;
    var frees: usize = 0;
    var interleaved = false;
    errdefer |err| std.debug.print("context {s}: {s} phase={s} failure={?} active={?} alloc={d} free={d}\n",
        .{scenario,@errorName(err),@tagName(target.phase),target.failure,running.context_active,allocations,frees});
    for (0..@as(usize, if (success) 2 else 1)) |index| {
        handles[index] = try running.createExecutionContext(19, deadline);
        var forged = handles[index]; forged.serial += 1;
        try t.expectError(error.Stale, running.executionContextStatus(forged));
        try t.expectError(error.State, running.allocateNativeBuffer(4096, deadline));
        var steps: usize = 0;
        while (target.phase == .ready and running.context_active != null and steps < 100) : (steps += 1) {
            _ = target.step();
            if (target.phase != .ready or running.context_active == null) break;
            const owner = running.contexts[running.context_active.?].owner.?;
            const channel = running.activeChannel().?;
            if (channel.phase != .waiting) continue;
            const op = owner.operation.?;
            const vector_index: usize = switch (op) { .classes => 0, .engines => if (owner.base == 0) 1 else 2, .method_size => 3, .group => 4, .share => 5, .free_share => 6, .free_group => 7 };
            const cursor = (session.tx_write + 62) % 63;
            const record = try transport.message.decode(session.profile, backing.?[command + 4096 + cursor * 4096..][0..4096], session.tx_sequence - 1);
            try t.expectEqualSlices(u8, channel.request, record.payload);
            try t.expect(owner.info() == null);
            channel.phase = .prepared;
            try target.port.owner.?.admit_command.?(target.port.owner.?.context, &target.port, deadline);
            var moved = owner.*; try t.expect(!moved.matches(channel, deadline)); try t.expectError(error.Stale, moved.poll());
            const original = channel.request; channel.request = record.payload;
            try t.expectError(error.Binding, target.port.owner.?.admit_command.?(target.port.owner.?.context, &target.port, deadline));
            channel.request = original; channel.phase = .waiting;
            std.mem.writeInt(u32, backing.?[status + 64..][0..4], session.tx_write, .little);
            var response: [wire.max_bytes]u8 = @splat(0);
            @memcpy(response[0..channel.request.len], channel.request);
            const header: usize = if (wire.function(op) == 76) 24 else if (wire.function(op) == 103) 32 else 16;
            @memcpy(response[header..channel.request.len], vectors.response(vector_index)[header..]);
            if (wire.function(op) == 103) allocations += 1;
            if (wire.function(op) == 10) frees += 1;
            if (op == .classes and model.is("context_classes")) outputWord(&response, 24, 0);
            if (op == .engines) {
                if (model.is("context_page")) outputWord(&response, 24, owner.base + 1);
                if (owner.base == 0 and model.is("context_duplicate")) outputWord(&response, 44, 19);
                if (owner.base == 32 and model.is("context_engine")) outputWord(&response, 44, 20);
                if (!interleaved) {
                    var print: [9]u8 = @splat(0); print[4] = 1; print[8] = 'C';
                    try nativeEvent(session, 0x100c, &print); _ = target.step();
                    try t.expect(channel.phase == .waiting and channel.deadline == deadline and owner.info() == null);
                    interleaved = true;
                }
            }
            if (op == .method_size and model.is("context_query_reject")) outputWord(&response, 12, 0x57);
            if ((op == .group and model.is("context_group_reject")) or (op == .share and model.is("context_share_reject"))) outputWord(&response, 16, 0x57);
            if (op == .share and model.is("context_share_changed")) response[36] ^= 1;
            if (op == .share and model.is("context_timeout")) clock = deadline else {
                try nativeReply(session, channel.function, 0, response[0..channel.request.len]);
                if (op == .share and model.is("context_ack")) range_failure_call = range_calls + 4;
            }
            _ = target.step(); range_failure_call = 0;
        }
        try t.expect(steps < 100);
        if (target.phase != .ready) break;
        const result = try running.executionContextStatus(handles[index]);
        try t.expect(result.state == .handed_off);
        if (result.info) |info| {
            try t.expect(info.binding.client == running.graph.?.reservation.client and info.rm_engine == 19 and info.nv_engine == 0x34);
            try t.expect(info.engine.data[3] == 7 and info.method_bytes == 0x6000 and info.subcontext == 0);
            if (methods and index == 0) {
                const buffer = try allocateContextStorage(target, info.method_bytes, deadline);
                const context = running.contexts[handles[0].slot].owner.?;
                try t.expectError(error.Bounds, running.attachContextMethods(handles[0], 2, buffer));
                if (model.is("context_methods_acquire")) {
                    try t.expectError(error.Memory, running.attachContextMethods(handles[0], 0, buffer));
                    try t.expect(context.methodStorage(0) == null and context.methods[0].self_address == 0 and !model.slots[0].imported);
                } else {
                    try running.attachContextMethods(handles[0], 0, buffer);
                    try t.expect(context.methodStorage(0).?.bytes == info.method_bytes and model.slots[0].gpu.lease.id != 0);
                    try t.expectError(error.Busy, running.attachContextMethods(handles[0], 0, buffer));
                }
                try running.releaseNativeBuffer(buffer);
                try t.expect(!model.slots[0].reference and model.slots[0].live);
                if (!model.is("context_methods_acquire")) {
                    try t.expect(context.methodStorage(0) != null);
                    try t.expect(std.meta.eql(context.methodStorage(0).?.reference, context.methods[0].reference));
                }
            }
            if (copy_case) { try checkDeviceCopies(target, table, scenario, handles[0], deadline); return; }
            if (fifo) { try checkDeviceFifos(target, table, scenario, handles[0], deadline); return; }
            var token = try running.channel.?.handoff(deadline); try running.graph.?.reclaim(&token, deadline);
            const sent = session.tx_sequence; try t.expectError(error.Retained, running.graph.?.beginDestroy(deadline)); try t.expect(sent == session.tx_sequence);
            var loan = try running.graph.?.loan(deadline); running.channel = try @import("gsp_exchange.zig").Exchange.init(&loan.runtime, deadline);
            if (success and index == 0) {
                held = try running.retainExecutionContext(handles[0]);
                try t.expectError(error.Retained, running.retireExecutionContext(handles[0], deadline));
                var wrong = held.?; wrong.serial += 1;
                try t.expectError(error.Stale, running.releaseExecutionContextChild(handles[0], wrong, true));
            }
        } else {
            try t.expect(result.unavailable != null or result.rejected != null);
            try t.expect(!running.contexts[handles[index].slot].owner.?.namespace_live);
            try t.expect(allocations == @as(usize, if (model.is("context_group_reject")) 1 else if (model.is("context_share_reject")) 2 else 0));
            try t.expect(frees == @as(usize, if (model.is("context_share_reject")) 1 else 0));
        }
    }
    if (target.phase == .ready) {
        if (success or methods) @import("gsp_buffer_test_model.zig").Model.closeHeapAdmission(table);
        try running.beginDestroyGraph(deadline, true);
        try t.expectError(error.Busy, running.retainExecutionContext(handles[0]));
        var steps: usize = 0;
        while (target.phase == .ready and steps < 180) : (steps += 1) {
            _ = target.step();
            if (target.phase != .ready) break;
            if (success and frees == 2 and running.context_active == null and held != null) {
                try t.expect(running.contexts[1].owner == null and running.contexts[0].owner.?.held());
                try t.expectError(error.Retained, running.releaseExecutionContextChild(handles[0], held.?, false));
                try running.releaseExecutionContextChild(handles[0], held.?, true);
                try t.expectError(error.Stale, running.releaseExecutionContextChild(handles[0], held.?, true)); held = null;
            }
            const channel = running.activeChannel().?;
            if (channel.phase != .waiting) continue;
            var response: [wire.max_bytes]u8 = @splat(0); @memcpy(response[0..channel.request.len], channel.request);
            if (running.context_active) |index| {
                const owner = running.contexts[index].owner.?;
                try t.expect(owner.state == .destroying and !owner.held());
                try t.expect(owner.operation.? == .free_share or owner.operation.? == .free_group); frees += 1;
                if (methods and index == handles[0].slot and !model.is("context_methods_acquire"))
                    try t.expect(model.slots[0].imported and model.slots[0].gpu.lease.id != 0 and model.charged == 65536);
                if (model.is("context_free") or (model.is("context_methods_free") and owner.operation.? == .free_group)) outputWord(&response, 12, 0x57);
            } else if (running.native_active != null) {
                try t.expect(methods and !model.slots[0].imported and model.slots[0].gpu.lease.id == 0 and model.slots[0].claimed);
                if (!model.is("context_methods_acquire")) for (&running.contexts) |*slot| try t.expect(slot.owner == null);
            } else {
                for (&running.contexts) |*slot| try t.expect(slot.owner == null);
                try t.expect(model.charged == 0);
            }
            std.mem.writeInt(u32, backing.?[status + 64..][0..4], session.tx_write, .little);
            try nativeReply(session, channel.function, 0, response[0..channel.request.len]); _ = target.step();
        }
        try t.expect(steps < 180);
    }
    const uncertain = model.is("context_page") or model.is("context_duplicate") or model.is("context_share_changed") or model.is("context_ack") or model.is("context_timeout") or model.is("context_free") or
        model.is("context_methods_free") or model.is("context_methods_release");
    try t.expect(target.phase == .recovering and target.failure != null);
    if (uncertain) try t.expect(running.contexts[0].owner.?.namespace_live and running.contexts[0].owner.?.failure != null) else {
        try t.expect(target.failure.? == error.RmClosed);
        for (&running.contexts) |*slot| try t.expect(slot.owner == null);
        if (success) try t.expect(allocations == 4 and frees == 4);
    }
    if (methods) {
        if (uncertain) {
            try t.expect(model.slots[0].live and model.slots[0].imported and model.slots[0].gpu.lease.id != 0 and model.charged == 65536);
            if (model.is("context_methods_release")) try t.expect(!running.contexts[0].owner.?.group_live);
        } else try t.expect(model.released == 1 and model.charged == 0 and !model.slots[0].live);
    }
}
fn checkDeviceDisplayUpload(target: *@import("gsp_device.zig").Device, table: *a.DriverApi, handle: @import("gsp_runtime.zig").ChannelHandle, deadline: u64, scenario: []const u8) !void {
    const runtime = @import("gsp_runtime.zig");
    const model = @import("gsp_vram_test_model.zig").Model;
    const wire = @import("gsp_copy_wire.zig");
    const running = &target.running; const session = &target.session.?;
    const fifo = running.fifos[handle.slot].owner.?;
    errdefer |err| std.debug.print("display upload {s}: {s} phase={s} failure={?} held={} issued={d} completed={d} reading={} cpu={}\n",
        .{scenario,@errorName(err),@tagName(target.phase),target.failure,running.display_upload_job != null,fifo.ring.issued,fifo.ring.completed,ControlModel.reading,ControlModel.cpu_mapped});
    const root = try createTestDisplayRoot(target, deadline, true);
    const instance = try allocateContextStorage(target, 65536, deadline);
    try running.attachDisplayInstance(root, instance, deadline);
    var steps: usize = 0;
    while (running.display_engine_active and steps < 30) : (steps += 1) {
        _ = target.step(); try t.expect(target.phase == .ready);
        if (!running.display_engine_active) break;
        const rpc = &running.display_engine_owner.?.exchange;
        if (rpc.phase != .waiting) continue;
        try t.expect(running.display_engine_owner.?.operation.? == .instance);
        var response: [48]u8 = undefined; @memcpy(&response, rpc.request);
        std.mem.writeInt(u32, backing.?[init.queues_offset + init.status_offset + 64..][0..4], session.tx_write, .little);
        try nativeReply(session, rpc.function, 0, &response); _ = target.step();
    }
    try t.expect(steps < 30 and running.display_engine_owner.?.instance_bound);
    try running.releaseNativeBuffer(instance);
    const display_case = std.mem.startsWith(u8, scenario, "context_display");
    const present_case = std.mem.startsWith(u8, scenario, "context_display_present");
    const image_case = present_case or std.mem.startsWith(u8, scenario, "context_display_image");
    if (display_case) {
        const words: [*]u32 = @ptrFromInt(target.port.window.cpu_address);
        @import("gsp_display_test_model.zig").Model.install(table, scenario, words[0..@intCast(target.port.window.byte_length / 4)]);
        if (model.is("context_display_map")) {
            try t.expectError(error.Retained, running.createDisplayNotifier(root, .core, 0)); _ = target.step();
            try t.expect(target.phase == .recovering and running.display_resources_slot.owner.?.notifiers[0].failed); return;
        }
        _ = try running.createDisplayNotifier(root, .core, 0);
        try t.expectError(error.Busy, running.createDisplayNotifier(root, .core, 0));
        if (image_case) _ = try running.createDisplayNotifier(root, .window, 3);
    }
    const data = if (image_case) try finishContextBuffer(target,
        try running.allocateDisplaySurface(.{ .width = if (present_case) 65 else 641, .height = if (present_case) 20 else 480, .usage = 40 }, deadline), deadline)
        else try allocateContextStorage(target, 65536, deadline);
    const data_index = (try running.nativeBufferStatus(data)).info.?.reference.buffer.id - 801;
    try t.expectError(error.Unsupported, running.bindDisplayStorage(root, .window, 2, data));
    const dma = try running.bindDisplayStorage(root, .window, 3, data);
    try running.releaseNativeBuffer(data);
    const table_owner = running.display_resources_slot.owner.?;
    const entries: u32 = if (image_case) 3 else if (display_case) 2 else 1;
    try t.expect(table_owner.valid() and table_owner.table.count == entries and !table_owner.table.published(4, dma) and
        model.slots[data_index].imported and model.slots[data_index].gpu.lease.id != 0 and !model.slots[data_index].reference);
    var forged = root; forged.epoch += 1; try t.expectError(error.Stale, running.displayTableStatus(forged));
    const first_deadline = if (model.is("context_upload_retry")) clock + 1 else deadline;
    if (model.is("context_upload_sync")) {
        try t.expectError(error.Retained, running.uploadDisplayTable(root, handle, first_deadline)); _ = target.step();
        try t.expect(target.phase == .recovering and table_owner.failed and ControlModel.cpu_mapped and !ControlModel.reading and fifo.ring.issued == 0);
        return;
    }
    if (model.is("context_upload_acquire")) {
        try t.expectError(error.Memory, running.uploadDisplayTable(root, handle, first_deadline));
        try t.expect(running.failure == null and running.display_upload_job == null and !table_owner.table.uploading and
            !ControlModel.reading and !ControlModel.cpu_mapped and fifo.ring.issued == 0);
        ControlModel.scenario = "context_upload_recovered";
    }
    try running.uploadDisplayTable(root, handle, first_deadline);
    if (model.is("context_upload_retry")) {
        clock = first_deadline; _ = target.step();
        try t.expect(target.phase == .ready and running.display_upload_job == null and !ControlModel.reading and fifo.ring.issued == 0 and !table_owner.table.uploading);
        try running.uploadDisplayTable(root, handle, deadline);
    }
    try t.expect(ControlModel.reading and !ControlModel.cpu_mapped and running.copy_job == null and
        (try running.displayTableStatus(root)).published_revision == 0);
    try t.expectEqualSlices(u8, &table_owner.table.image, ControlModel.data[0..runtime.display_resources.layout.image_bytes]);
    try t.expectError(error.Busy, running.bindDisplayStorage(root, .core, 0, data));
    try t.expectError(error.Busy, running.createDisplayChannel(root, .core, 0, deadline));
    try t.expectError(error.Busy, running.retireExecutionChannel(handle, deadline, true));
    try t.expectError(error.Busy, running.beginCopyWork(handle, .{}, deadline));
    const gate = target.port.owner.?.admit_copy.?;
    const work = &running.display_upload_job.?.operation;
    // A private, unsubmitted preparation lets the real Device gate reject
    // mutated owners/leases/bytes without touching hardware or a queue job.
    work.ticket = try fifo.prepareCopy(try work.transfer());
    try gate(target.port.owner.?.context, &target.port, fifo, work.ticket.?, deadline);
    try t.expectError(error.Binding, gate(target.port.owner.?.context, &target.port, fifo, work.ticket.?, deadline + 1));
    work.gpu.byte_length -= 1;
    try t.expectError(error.Binding, gate(target.port.owner.?.context, &target.port, fifo, work.ticket.?, deadline)); work.gpu.byte_length += 1;
    table_owner.table.image[0] ^= 1;
    try t.expectError(error.Binding, gate(target.port.owner.?.context, &target.port, fifo, work.ticket.?, deadline)); table_owner.table.image[0] ^= 1;
    const original_source = work.source; work.source = &fifo.commands.?;
    try t.expectError(error.Binding, gate(target.port.owner.?.context, &target.port, fifo, work.ticket.?, deadline)); work.source = original_source;
    const operand: *u32 = @ptrFromInt(fifo.ring.cpu.cpu_address + wire.push_offset + 8);
    operand.* ^= 1;
    try t.expectError(error.Binding, gate(target.port.owner.?.context, &target.port, fifo, work.ticket.?, deadline)); operand.* ^= 1;
    var moved = work.*; try t.expect(!moved.valid());
    try t.expect(fifo.ring.issued == 0 and !fifo.ring.published);
    fifo.ring.pending = null; work.ticket = null; // Test-only rollback of CPU-only preparation, before PUT.
    const completion: *u32 = @ptrFromInt(fifo.ring.cpu.cpu_address + wire.completion_offset);
    const get: *u32 = @ptrFromInt(fifo.ring.cpu.cpu_address + wire.userd_offset + 0x88);
    _ = target.step();
    try t.expect(target.phase == .ready and work.phase == .submitted and fifo.ring.issued == 1 and ControlModel.reading);
    get.* = fifo.ring.put; _ = target.step();
    try t.expect(work.phase == .submitted and table_owner.table.uploaded_revision == 0 and fifo.ring.completed == 0 and ControlModel.reading);
    if (model.is("context_upload_timeout")) clock = deadline else {
        // Synthetic hardware completion only after checking the actual CE
        // commands and source bytes. This is not a physical GPU claim.
        completion.* = fifo.ring.issued;
        if (model.is("context_upload_fault")) try nativeEvent(session, 0x10ff, &.{});
    }
    _ = target.step();
    if (model.is("context_upload_timeout") or model.is("context_upload_fault") or model.is("context_upload_release")) {
        try t.expect(target.phase == .recovering and table_owner.failed and table_owner.table.uploaded_revision == 0 and
            ControlModel.reading and running.display_upload_job != null and model.slots[data_index].imported);
        if (model.is("context_upload_fault")) try t.expect(fifo.ring.completed == 0);
        return;
    }
    try t.expect(target.phase == .ready and running.display_upload_job == null and !ControlModel.reading and !ControlModel.cpu_mapped and
        table_owner.table.published(4, dma) and (try running.displayTableStatus(root)).published_revision == entries and running.copy_completed == 0);
    try t.expectError(error.Busy, running.uploadDisplayTable(root, handle, deadline));
    try t.expectError(error.Busy, running.beginDestroyGraph(deadline, true));
    try t.expectError(error.Retained, running.retireDisplayEngine(root, deadline));
    // Creation seals the initial table, even before a later channel ACK.
    const core_handle = try running.createDisplayChannel(root, .core, 0, deadline);
    try t.expect(running.display_engine_owner.?.channels_started);
    try t.expectError(error.Busy, running.bindDisplayStorage(root, .core, 0, data));
    if (image_case) { try checkDeviceDisplayImage(target, table, handle, root, core_handle, dma, deadline, scenario); return; }
    if (display_case) { try checkDeviceDisplaySubmissions(target, core_handle, deadline, scenario); return; }
    _ = target.stop();
    try t.expect(table_owner.failed and model.slots[data_index].imported and ControlModel.active and ControlModel.releases == 0);
}
fn pumpDisplayLink(target: *@import("gsp_device.zig").Device, deadline: u64, phase: @import("gsp_hdmi_link.zig").Phase) !bool {
    const link_api = @import("gsp_hdmi_link.zig");
    const model = @import("gsp_display_test_model.zig").Model;
    const running = &target.running;
    const session = &target.session.?;
    var steps: usize = 0;
    while (target.phase == .ready and running.display_work.?.link.?.phase == phase and steps < 60) : (steps += 1) {
        const link = &running.display_work.?.link.?;
        const rpc = &running.channel.?;
        const prior = link.acknowledged;
        _ = target.step();
        if (target.phase != .ready or rpc.phase != .waiting) continue;
        var response: [link_api.max_bytes]u8 = undefined;
        const reference = try @import("gsp_hdmi_link_test.zig").reference(link.operation, link.plan);
        @memcpy(response[0..reference.len], reference);
        outputWord(&response, 0, link.plan.object.client); outputWord(&response, 4, link.plan.object.display);
        try t.expectEqualSlices(u8, response[0..reference.len], rpc.request);
        try t.expect(link.acknowledged == prior and running.display_images[3] == null);
        const io = target.port.owner.?;
        rpc.phase = .prepared;
        const saved = rpc.request;
        rpc.request = response[0..reference.len];
        try t.expectError(error.Binding, io.admit_command.?(io.context, &target.port, deadline)); rpc.request = saved;
        link.request[32] ^= 1;
        try t.expectError(error.Binding, io.admit_command.?(io.context, &target.port, deadline)); link.request[32] ^= 1;
        running.outputs.data.generation += 1;
        try t.expectError(error.Binding, io.admit_command.?(io.context, &target.port, deadline)); running.outputs.data.generation -= 1;
        try t.expectError(error.Binding, io.admit_command.?(io.context, &target.port, deadline + 1));
        try io.admit_command.?(io.context, &target.port, deadline);
        rpc.phase = .waiting;
        if (phase == .before_scanout and model.is("context_display_image_link_timeout")) { clock = deadline; _ = target.step(); break; }
        if (phase == .before_scanout and model.is("context_display_image_link_stale")) {
            running.outputs.data.generation += 1; _ = target.step(); break;
        }
        if ((link.operation == .enable and model.is("context_display_image_link_reject")) or
            (link.operation == .gcp and model.is("context_display_image_link_late_reject"))) outputWord(&response, 12, 0x57);
        std.mem.writeInt(u32, backing.?[init.queues_offset + init.status_offset + 64..][0..4], session.tx_write, .little);
        try nativeReply(session, link_api.function, 0, response[0..reference.len]);
        if (link.operation == .gcp and model.is("context_display_image_link_ack")) range_failure_call = range_calls + 4;
        _ = target.step();
        if (target.phase == .ready) try t.expect(link.acknowledged == prior + 1 and link.last_receipt != 0 and !link.pending);
        if (target.phase == .ready and link.phase == .complete and model.is("context_display_image_link_fault")) {
            // A fatal event after every successful ACK still wins over final
            // image publication on the next bounded worker invocation.
            try nativeEvent(session, 0x10ff, &.{}); _ = target.step(); break;
        }
    }
    try t.expect(steps < 60);
    if (target.phase != .ready) {
        try t.expect(target.phase == .recovering and running.display_work != null and running.display_images[3] == null and
            running.display_resources_slot.owner.?.failed and model.released == 0);
        for (&model.slots) |*slot| try t.expect(slot.active and slot.cpu and slot.dma.lease.id != 0);
        if (phase == .before_scanout) try t.expect(running.display_channels[0].?.ring.issued == 0 and running.display_channels[4].?.ring.issued == 0 and running.display_channels[12].?.ring.issued == 0)
        else try t.expect(running.display_channels[0].?.ring.completed == 1 and running.display_channels[4].?.ring.completed == 1 and running.display_channels[12].?.ring.completed == 1);
        if (model.is("context_display_image_link_ack")) try t.expect(session.pending != null and running.display_work.?.link.?.acknowledged == 6);
        return false;
    }
    try t.expect(running.display_work.?.link.?.phase == if (phase == .before_scanout) link_api.Phase.scanout else .complete);
    return true;
}
fn checkDeviceDisplayImage(target: *@import("gsp_device.zig").Device, table: *a.DriverApi, fifo_handle: @import("gsp_runtime.zig").ChannelHandle,
    root: @import("gsp_runtime.zig").DisplayEngineHandle,
    core_handle: @import("gsp_runtime.zig").DisplayChannelHandle, dma: u32, deadline: u64, scenario: []const u8) !void
{
    const model = @import("gsp_display_test_model.zig").Model;
    const native_model = @import("gsp_vram_test_model.zig").Model;
    const push = @import("gsp_display_push.zig");
    const running = &target.running;
    const present_case = std.mem.startsWith(u8, scenario, "context_display_present");
    const position_failure = model.is("context_display_image_position_timeout") or model.is("context_display_image_position_fault");
    const link_case = std.mem.startsWith(u8, scenario, "context_display_image_link_");
    const dvi_case = model.is("context_display_image_link_dvi");
    errdefer |err| std.debug.print("display image {s}: {s} phase={s} failure={?} core={?} window={?}\n", .{
        scenario, @errorName(err), @tagName(target.phase), target.failure,
        if (running.display_work) |work| work.core.phase else null,
        if (running.display_work) |work| if (work.window) |window| window.phase else null else null });
    try pumpDisplayChannel(target, core_handle, deadline);
    const window_handle = try running.createDisplayChannel(root, .window, 3, deadline);
    try pumpDisplayChannel(target, window_handle, deadline);
    const position_handle = try running.createDisplayChannel(root, .immediate, 3, deadline);
    try pumpDisplayChannel(target, position_handle, deadline);
    const core_owner = &running.display_channels[0].?;
    const window_owner = &running.display_channels[4].?;
    const position_owner = &running.display_channels[12].?;
    const table_owner = running.display_resources_slot.owner.?;
    const core_note = table_owner.publishedNotifier(0).?;
    const window_note = table_owner.publishedNotifier(4).?;
    const core_words: [*]u32 = @ptrFromInt(core_note.cpu.cpu_address);
    const window_words: [*]u32 = @ptrFromInt(window_note.cpu.cpu_address);
    const core_user = try push.userBase(.core, 0);
    const window_user = try push.userBase(.window, 3);
    const position_user = try push.userBase(.immediate, 3);
    const image = table_owner.publishedImage(4, dma).?;
    const mode_case = !present_case or native_model.is("context_display_present");
    const saved_boot_info = DeviceModel.boot_info;
    const saved_original_boot = target.display.?.original_boot;
    const saved_scanout = target.display.?.scanout_original;
    defer {
        DeviceModel.boot_info = saved_boot_info;
        target.display.?.original_boot = saved_original_boot;
        target.display.?.scanout_original = saved_scanout;
    }
    if (mode_case) {
        const vectors = @import("gsp_display_commands_test.zig");
        var observed = vectors.bootFixture(image.width, image.height);
        if (dvi_case) observed.heads[1].hdmi = 0;
        // This fixture's original instance was inactive; keep its actual
        // captured dependency contract while supplying a modeled signal.
        observed.instance_control = saved_scanout.?.instance_control;
        observed.instance_address = saved_scanout.?.instance_address;
        for (&observed.windows) |*entry| entry.core[0] = 15;
        target.display.?.scanout_original = observed;
        DeviceModel.boot_info.width = image.width; DeviceModel.boot_info.height = image.height;
        DeviceModel.boot_info.pitch = image.width * 4; DeviceModel.boot_info.byte_length = @as(u64, image.width) * 4 * image.height;
        DeviceModel.boot_info.format = a.gfx_buffer_format_xrgb8888;
        target.display.?.original_boot = DeviceModel.boot_info;
        running.outputs.self_address = @intFromPtr(&running.outputs); running.outputs.state = .returned;
        running.outputs.graph = &running.graph.?;
        vectors.outputFixture(&running.outputs.data, running.epoch, running.graph.?.reservation.client);
        target.display.?.scanout_original.?.heads[1].words[1] = 8;
        try t.expectError(error.Unsupported, running.commitBootDisplayImage(core_handle, window_handle, dma, deadline));
        try t.expect(running.display_work == null and core_owner.ring.issued == 0 and window_owner.ring.issued == 0);
        target.display.?.scanout_original.?.heads[1].words[1] = 0;
    }
    if (present_case) try t.expect(image.width == 65 and image.height == 20 and image.pitch == 512 and image.bytes >= 512 * 20)
    else try t.expect(image.width == 641 and image.height == 480 and image.pitch == 2816 and image.bytes >= 2816 * 480);
    try t.expect(table_owner.publishedImage(1, dma) == null and try running.displayImageStatus(root, 3) == null);
    try t.expectError(error.Bounds, running.commitDisplayImage(core_handle, window_handle, dma, 8, deadline));
    try t.expectError(error.State, running.commitDisplayImage(core_handle, window_handle, dma + 1, 1, deadline));
    table_owner.surfaces[2].?.descriptor.width += 1;
    try t.expect(table_owner.publishedImage(4, dma) == null); table_owner.surfaces[2].?.descriptor.width -= 1;
    const source_index = table_owner.storage[2].info().?.reference.buffer.id - 801;
    try t.expect(native_model.slots[source_index].live and native_model.slots[source_index].imported and
        !native_model.slots[source_index].reference and native_model.slots[source_index].gpu.lease.id != 0);
    if (present_case and !try checkInitialPresentation(target, table, fifo_handle, root, core_handle, window_handle, dma, deadline, scenario)) return;
    const endpoint = target.port.owner.?;
    const admit = endpoint.admit_display_push.?;
    for (1..4) |point| {
        if (point == 3) {
            // A prior image's BEGUN record cannot be reused before the GPU
            // reports FINISHED, even though the newer image has begun.
            try t.expect(window_words[0] >> 30 == 1 and window_words[4] >> 30 == 1);
            try t.expectError(error.Busy, running.commitDisplayImage(core_handle, window_handle, dma, 1, deadline));
            try t.expect(running.display_work == null and window_owner.ring.issued == 2);
            window_words[0] = 2 << 30;
        }
        if (mode_case and point == 1) try running.commitBootDisplayImage(core_handle, window_handle, dma, deadline)
        else if (point < 3) try running.commitPositionedDisplayImage(core_handle, window_handle, position_handle, dma, 1,
            if (point == 1) .{} else .{ .x = -17, .y = 23 }, deadline)
        else try running.commitDisplayImage(core_handle, window_handle, dma, 1, deadline);
        if (mode_case and point == 1) {
            try t.expectError(error.Binding, admit(endpoint.context, &target.port, position_owner, deadline, .read));
            if (!try pumpDisplayLink(target, deadline, .before_scanout)) return;
        }
        const window_part = &running.display_work.?.window.?;
        try t.expect(window_part.config.notifier_offset == if (point == 2) @as(u16, 16) else 0);
        try t.expectError(error.Busy, running.commitDisplayCore(core_handle, deadline));
        try t.expectError(error.Busy, running.retireDisplayChannel(window_handle, deadline));
        try t.expectError(error.Binding, admit(endpoint.context, &target.port, core_owner, deadline, .read));
        if (point < 3) {
            try t.expectError(error.Binding, admit(endpoint.context, &target.port, window_owner, deadline, .read));
            try admit(endpoint.context, &target.port, position_owner, deadline, .read);
            const position = &running.display_work.?.position.?;
            position.handle.slot = 11;
            try t.expectError(error.Binding, admit(endpoint.context, &target.port, position_owner, deadline, .read)); position.handle.slot = 12;
            window_part.config.with_position = false;
            try t.expectError(error.Binding, admit(endpoint.context, &target.port, position_owner, deadline, .read)); window_part.config.with_position = true;
            _ = target.step();
            try t.expect(target.phase == .ready and position.phase == .submitted and window_part.phase == .prepare and
                position_owner.ring.issued == point and position_owner.ring.completed == point - 1);
            try t.expect(model.words[position_user / 4] == position_owner.ring.put * 4);
            // A fetched WIMM UPDATE cannot prove the coupled display change.
            if (point == 1 and !position_failure) model.words[(position_user + 4) / 4] = model.words[position_user / 4];
            try t.expectError(error.Binding, admit(endpoint.context, &target.port, position_owner, deadline, .read));
            try t.expect(position_owner.ring.completed == point - 1);
            position.config.position.?.x +%= 1;
            try t.expectError(error.Binding, admit(endpoint.context, &target.port, window_owner, deadline, .read)); position.config.position.?.x -%= 1;
        }
        try admit(endpoint.context, &target.port, window_owner, deadline, .read);
        if (point == 1) {
            if (mode_case) {
                const planned = &running.display_work.?.boot_mode.?;
                try t.expect(planned.epoch == target.epoch and planned.held_generation == target.display_epoch and planned.head == 1 and planned.window == 3);
                running.display_work.?.core.config.signal.?.clock ^= 1;
                try t.expectError(error.Binding, admit(endpoint.context, &target.port, window_owner, deadline, .read));
                running.display_work.?.core.config.signal.?.clock ^= 1;
                planned.output_generation += 1;
                try t.expectError(error.Binding, admit(endpoint.context, &target.port, window_owner, deadline, .read)); planned.output_generation -= 1;
                running.outputs.data.generation += 1;
                try t.expectError(error.Binding, admit(endpoint.context, &target.port, window_owner, deadline, .read)); running.outputs.data.generation -= 1;
                try admit(endpoint.context, &target.port, window_owner, deadline, .read);
            }
            window_part.config.scanout.?.pitch += 64;
            try t.expectError(error.Binding, admit(endpoint.context, &target.port, window_owner, deadline, .read));
            window_part.config.scanout.?.pitch -= 64;
            window_part.ticket = try window_owner.ring.prepare(0, window_part.config);
            try window_note.armWindow(window_part.ticket.?.point, deadline, window_part.config.notifier_offset);
            try admit(endpoint.context, &target.port, window_owner, deadline, .publish);
            const command: *u32 = @ptrFromInt(window_owner.ring.cpu.cpu_address + 4);
            command.* ^= 1;
            try t.expectError(error.Binding, admit(endpoint.context, &target.port, window_owner, deadline, .publish)); command.* ^= 1;
            window_note.offset = 16;
            try t.expectError(error.Binding, admit(endpoint.context, &target.port, window_owner, deadline, .publish)); window_note.offset = 0;
            // CPU-only test preparation: no PUT was published.
            window_owner.ring.pending = null; window_owner.ring.program = null; window_part.ticket = null;
            window_note.phase = .ready; window_note.point = 0; window_note.deadline = 0; window_note.window_used = 0;
        }
        _ = target.step();
        try t.expect(target.phase == .ready and window_part.phase == .submitted and running.display_work.?.core.phase == .prepare and
            window_owner.ring.issued == point and core_owner.ring.issued == point - 1);
        try t.expect(model.words[window_user / 4] == window_owner.ring.put * 4);
        _ = target.step();
        try t.expect(target.phase == .ready and running.display_work.?.core.phase == .submitted and core_owner.ring.issued == point);
        model.words[(window_user + 4) / 4] = model.words[window_user / 4];
        model.words[(core_user + 4) / 4] = model.words[core_user / 4];
        core_words[0] = 2 << 30; _ = target.step();
        try t.expect(target.phase == .ready and running.display_work != null and core_owner.ring.completed == point and window_owner.ring.completed == point - 1);
        if (point == 1) try t.expect(try running.displayImageStatus(root, 3) == null);
        const at = window_note.offset / 4;
        if (model.is("context_display_image_timeout")) clock = deadline else {
            window_words[at + 2] = @intCast(100 + point); window_words[at + 3] = 7;
            window_words[at] = if (model.is("context_display_image_lost")) 2 << 30 else 1 << 30;
            if (model.is("context_display_image_fault")) try nativeEvent(&target.session.?, 0x10ff, &.{});
        }
        _ = target.step();
        if (position_failure) {
            try t.expect(target.phase == .ready and running.display_work != null and running.display_images[3] == null and
                window_owner.ring.completed == point and core_owner.ring.completed == point and position_owner.ring.completed == 0);
            if (model.is("context_display_image_position_timeout")) clock = deadline
            else {
                // A fatal event wins even if GET becomes drainable at once.
                model.words[(position_user + 4) / 4] = model.words[position_user / 4];
                try nativeEvent(&target.session.?, 0x10ff, &.{});
            }
            _ = target.step();
        }
        if (!model.is("context_display_image") and !present_case and !link_case) {
            try t.expect(target.phase == .recovering and running.display_work != null and running.display_images[3] == null and
                table_owner.failed and window_note.failed and window_owner.ring.completed == @as(u64, if (position_failure) 1 else 0) and
                position_owner.ring.completed == 0 and model.released == 0 and
                native_model.slots[source_index].imported and native_model.slots[source_index].gpu.lease.id != 0);
            for (&model.slots) |*slot| try t.expect(slot.active and slot.cpu and slot.dma.lease.id != 0);
            return;
        }
        if (point == 2) {
            try t.expect(target.phase == .ready and running.display_work != null and window_owner.ring.completed == 2 and core_owner.ring.completed == 2 and
                position_owner.ring.completed == 1 and (try running.displayImageStatus(root, 3)).?.window_point == 1);
            model.words[(position_user + 4) / 4] = model.words[position_user / 4];
            _ = target.step();
        }
        if (mode_case and point == 1) {
            try t.expect(running.display_images[3] == null and running.display_work.?.link.?.phase == if (dvi_case) @import("gsp_hdmi_link.zig").Phase.complete else .after_scanout);
            if (!dvi_case and !try pumpDisplayLink(target, deadline, .after_scanout)) return;
            try t.expect(running.display_images[3] == null and running.display_work.?.link.?.acknowledged == @as(u8, if (dvi_case) 2 else 7));
            _ = target.step();
        }
        const active_image = (try running.displayImageStatus(root, 3)).?;
        try t.expect(active_image.position != null and std.meta.eql(active_image.position.?.handle, position_handle) and
            active_image.position.?.sequence == @min(point, 2) and position_owner.ring.completed == @min(point, 2));
        try t.expect(std.meta.eql(active_image.position.?.point, if (point == 1) push.commands.Point{} else push.commands.Point{ .x = -17, .y = 23 }));
        if (mode_case) try t.expect(active_image.boot_mode != null and active_image.boot_mode.?.signal.clock == (0x80000000 | 148500000) and
            active_image.boot_mode.?.output_generation == 7 and active_image.boot_mode.?.held_generation == target.display_epoch);
        if (mode_case) try t.expect(active_image.link != null and active_image.link.?.acknowledged == @as(u8, if (dvi_case) 2 else 7) and active_image.link.?.receipt != 0 and
            active_image.link.?.plan.mode.transport_hdmi == !dvi_case);
        try t.expect(target.phase == .ready and running.display_work == null and window_owner.ring.completed == point and
            core_owner.ring.completed == point and std.meta.eql(active_image.image, image) and active_image.head == 1 and
            active_image.core_point == point and active_image.window_point == point and window_note.result.?.timestamp == (@as(u64, 7) << 32) + 100 + point);
    }
    if (std.mem.startsWith(u8, scenario, "context_display_present_initial_")) { _ = target.stop(); return; }
    if (present_case) { try checkDevicePresentation(target, fifo_handle, window_handle, dma, scenario); return; }
    try t.expectError(error.Retained, running.retireDisplayChannel(window_handle, deadline));
    try running.retireDisplayChannel(position_handle, deadline); try pumpDisplayChannel(target, position_handle, deadline);
    try running.retireDisplayChannel(window_handle, deadline); try pumpDisplayChannel(target, window_handle, deadline);
    try running.retireDisplayChannel(core_handle, deadline); try pumpDisplayChannel(target, core_handle, deadline);
    try t.expect(model.released == 3 and model.slots[0].active and model.slots[1].active and
        !model.slots[2].active and !model.slots[3].active and !model.slots[4].active and native_model.slots[source_index].imported and table_owner.valid());
    _ = target.stop();
    try t.expect(table_owner.failed and model.released == 3 and native_model.slots[source_index].live);
}
fn checkInitialPresentation(target: *@import("gsp_device.zig").Device, table: *a.DriverApi,
    handle: @import("gsp_runtime.zig").ChannelHandle, root: @import("gsp_runtime.zig").DisplayEngineHandle,
    core_handle: @import("gsp_runtime.zig").DisplayChannelHandle, window_handle: @import("gsp_runtime.zig").DisplayChannelHandle,
    dma: u32, deadline: u64, scenario: []const u8) !bool
{
    const model = @import("gsp_copy_test_model.zig").Model;
    const native_model = @import("gsp_vram_test_model.zig").Model;
    const running = &target.running;
    const native_source = running.display_resources_slot.owner.?.publishedStorage(window_handle.slot, dma).?.info().?;
    const source_index = native_source.reference.buffer.id - 801;
    const fifo = running.fifos[handle.slot].owner.?;
    errdefer |err| std.debug.print("initial {s}: {s} phase={s} failure={?} pending={} submitted={} read={} point={d}\n", .{
        scenario,@errorName(err),@tagName(target.phase),target.failure,running.initial_image != null,
        if(running.initial_image)|work|work.operation.submitted else false,model.initial_read.lease.id != 0,running.presentation.?.initial_point });
    model.installPresentation(table, source_index, 65, 20);
    target.irq_wake = .{ .context = @intFromPtr(target), .signal = model.wakePresentation };
    const binding = try running.registerDisplayPresentation(handle, root, window_handle, dma, model.shadowReference(), deadline);
    try t.expect(std.meta.eql(binding, model.binding) and running.presentation.?.surface.valid());
    try t.expectError(error.Busy, running.registerDisplayPresentation(handle, root, window_handle, dma, model.shadowReference(), deadline));
    model.closeShadow(); // The driver must import its own alias, not the closed creator.
    for (&model.host[0], 0..) |*byte, i| byte.* = @truncate(i * 17 + 23);
    try t.expectError(error.Busy, running.commitDisplayImage(core_handle, window_handle, dma, 1, deadline));
    const first_point = fifo.ring.issued;
    if (native_model.is("context_display_present_initial_retry")) {
        try running.uploadInitialImage(clock + 1); clock += 1; _ = target.step();
        const status = try running.initialImageStatus();
        try t.expect(!status.pending and status.completed == 0 and status.failure != null and status.failure.? == error.Timeout and model.initial_read.lease.id == 0 and fifo.ring.issued == first_point);
    }
    model.reject_initial_read = native_model.is("context_display_present_initial_acquire");
    const before_put_timeout = native_model.is("context_display_present_initial_retry");
    try running.uploadInitialImage(if (before_put_timeout) clock + 1 else deadline);
    try t.expectError(error.Busy, running.uploadInitialImage(deadline));
    var steps: usize = 0;
    while (target.phase == .ready and running.initial_image != null and model.initial_read.lease.id == 0 and steps < 100) : (steps += 1) {
        _ = target.step();
        if (target.phase == .ready and running.buffer_active != null) try replyCopyMapping(target);
    }
    try t.expect(target.phase == .ready and steps < 100 and fifo.ring.issued == first_point);
    if (before_put_timeout) {
        try t.expect(model.initial_read.lease.id != 0);
        clock += 1; _ = target.step();
        const cancelled = try running.initialImageStatus();
        try t.expect(!cancelled.pending and cancelled.completed == 0 and cancelled.failure != null and cancelled.failure.? == error.Timeout and
            model.initial_read.lease.id == 0 and model.dma[0].lease.id != 0 and fifo.ring.issued == first_point);
        const prior_tx = target.session.?.tx_sequence;
        try running.uploadInitialImage(deadline); _ = target.step();
        try t.expect(model.initial_read.lease.id != 0 and target.session.?.tx_sequence == prior_tx);
    }
    if (model.reject_initial_read) {
        const status = try running.initialImageStatus();
        try t.expect(!status.pending and status.completed == 0 and status.failure != null and status.failure.? == error.Memory and model.initial_read.lease.id == 0 and model.dma[0].lease.id != 0);
        model.reject_initial_read = false;
        const prior_tx = target.session.?.tx_sequence;
        try running.uploadInitialImage(deadline); _ = target.step();
        try t.expect(model.initial_read.lease.id != 0 and target.session.?.tx_sequence == prior_tx);
    }
    try t.expect(model.initial_read.lease.id != 0 and !model.active and !model.queued and model.completed == 0);
    const operation = &running.initial_image.?.operation;
    const transfer = try running.initialImageTransfer();
    try t.expect(transfer.source == model.address(0) and transfer.target == native_source.address and transfer.bytes == 260 and
        transfer.rows.?.count == 20 and transfer.rows.?.source_pitch == 260 and transfer.rows.?.target_pitch == 512);
    try t.expectError(error.State, operation.complete(std.math.maxInt(u32)));
    try t.expectError(error.Busy, running.commitDisplayImage(core_handle, window_handle, dma, 1, deadline));
    try t.expectError(error.Busy, running.retireBuffer(running.initial_image.?.mapping.?, deadline, true));
    const endpoint = target.port.owner.?; const gate = endpoint.admit_copy.?;
    operation.ticket = try fifo.prepareCopy(transfer);
    try gate(endpoint.context, &target.port, fifo, operation.ticket.?, deadline);
    operation.gpu.byte_length -= 1;
    try t.expectError(error.Binding, gate(endpoint.context, &target.port, fifo, operation.ticket.?, deadline)); operation.gpu.byte_length += 1;
    try t.expectError(error.Binding, gate(endpoint.context, &target.port, fifo, operation.ticket.?, deadline + 1));
    const saved_source = operation.source_stamp.?;
    operation.source_stamp.?.buffer.id += 1;
    try t.expectError(error.Binding, gate(endpoint.context, &target.port, fifo, operation.ticket.?, deadline)); operation.source_stamp = saved_source;
    const wire = @import("gsp_copy_wire.zig");
    const pitch: *u32 = @ptrFromInt(fifo.ring.cpu.cpu_address + wire.push_offset + (fifo.ring.issued % wire.capacity) * wire.slot_bytes + 7 * 4);
    pitch.* ^= 4;
    try t.expectError(error.Binding, gate(endpoint.context, &target.port, fifo, operation.ticket.?, deadline)); pitch.* ^= 4;
    var moved = operation.*; try t.expect(!moved.valid());
    fifo.ring.pending = null; operation.ticket = null; // CPU-only test preparation; no PUT.
    _ = target.step();
    try t.expect(target.phase == .ready and operation.submitted and fifo.ring.issued == first_point + 1);
    const raw: [*]const u8 = @ptrFromInt(target.port.window.cpu_address);
    try model.fetch(fifo, raw[0..@intCast(target.port.window.byte_length)]); _ = target.step();
    try t.expect((try running.initialImageStatus()).completed == 0 and model.initial_read.lease.id != 0);
    try model.execute(); _ = target.step();
    try t.expect((try running.initialImageStatus()).completed == 0 and model.initial_read.lease.id != 0);
    for (model.vram_data, 0..) |byte, i| {
        const row = i / 512; const column = i % 512;
        try t.expectEqual(if (row < 20 and column < 260) model.host[0][row * 260 + column] else @as(u8, 0xcc), byte);
    }
    if (native_model.is("context_display_present_initial_timeout")) clock = deadline else {
        try model.signal();
        if (native_model.is("context_display_present_initial_fault")) {
            var rc_payload = @embedFile("fixtures/fault-570.144.bin")[32..80].*;
            outputWord(&rc_payload, 0, try @import("gsp_context.zig").wire.nvEngine(fifo.config.rm_engine));
            std.mem.writeInt(u64, rc_payload[28..36], transfer.target + 19 * 512 + 259, .little);
            try nativeEvent(&target.session.?, 0x1004, &rc_payload);
        }
    }
    model.reject_initial_release = native_model.is("context_display_present_initial_release");
    _ = target.step();
    if (native_model.is("context_display_present_initial_timeout") or native_model.is("context_display_present_initial_fault") or model.reject_initial_release) {
        try t.expect(target.phase == .recovering and running.initial_image != null and model.initial_read.lease.id != 0 and
            running.presentation.?.initial_point == 0 and model.completed == 0 and !model.active and model.lost and
            running.display_work == null and running.display_images[3] == null and native_model.slots[source_index].gpu.lease.id != 0);
        if (native_model.is("context_display_present_initial_fault")) {
            const record = running.faults.first_fatal.?;
            try t.expect(record.source == .rc and record.acknowledged and record.target_address_match and
                record.active_fence.timeline == 0 and record.copy_point == first_point + 1 and fifo.ring.completed == first_point);
        }
        return false;
    }
    const status = try running.initialImageStatus();
    try t.expect(target.phase == .ready and !status.pending and status.completed == first_point + 1 and status.failure == null and
        model.initial_read.lease.id == 0 and model.gpu[0].lease.id == 0 and model.dma[0].byte_length == 5200 and model.completed == 0 and
        running.copy_completed == 0 and running.display_work == null and running.display_images[3] == null);
    try t.expectError(error.Busy, running.uploadInitialImage(deadline));
    return true;
}
fn checkDevicePresentation(target: *@import("gsp_device.zig").Device, handle: @import("gsp_runtime.zig").ChannelHandle,
    window_handle: @import("gsp_runtime.zig").DisplayChannelHandle, dma: u32, scenario: []const u8) !void
{
    const model = @import("gsp_copy_test_model.zig").Model;
    const native_model = @import("gsp_vram_test_model.zig").Model;
    const running = &target.running;
    const table_owner = running.display_resources_slot.owner.?;
    const native_source = table_owner.publishedStorage(window_handle.slot, dma).?.info().?;
    const source_index = native_source.reference.buffer.id - 801;
    const fifo = running.fifos[handle.slot].owner.?;
    var checkpoint: []const u8 = "register";
    errdefer |err| std.debug.print("present {s}/{s}: {s} phase={s} fail={?} pending={} job={} submitted={} completed={d}\n", .{
        scenario,checkpoint,@errorName(err),@tagName(target.phase),target.failure,if(running.presentation)|p|p.pending else false,
        running.copy_job != null,if(running.copy_job)|j|j.submitted else false,model.completed});
    try t.expect(running.presentation.?.initial_point != 0 and model.initial_read.lease.id == 0);
    const raw: [*]const u8 = @ptrFromInt(target.port.window.cpu_address);
    for (&model.host[0], 0..) |*byte, i| byte.* = @truncate(i * 37 + 11);
    for (0..2) |frame| {
        // Second frame uses the full width and last row; the mapping is reused.
        const x: u32 = if (frame == 0) 3 else 0;
        const y: u32 = if (frame == 0) 2 else 19;
        const w: u32 = if (frame == 0) 11 else 65;
        const h: u32 = if (frame == 0) 4 else 1;
        const prior_tx = target.session.?.tx_sequence;
        var output_replies: usize = 0;
        var admission_checked = false;
        @memset(&model.vram_data, 0xcc);
        checkpoint = "enqueue";
        try model.enqueuePresent(x, y, w, h);
        try t.expect(running.presentation.?.pending and running.copy_job == null and model.presentation_wakes == frame + 1);
        var steps: usize = 0;
        checkpoint = "submit";
        while (target.phase == .ready and (running.copy_job == null or !running.copy_job.?.submitted) and steps < 100) : (steps += 1) {
            if (frame == 0 and !admission_checked and running.copy_job != null and running.buffer_active == null) {
                const job = &running.copy_job.?;
                for (&running.buffers) |*slot| if (slot.owner) |mapping| if (mapping.info()) |source| {
                    if (!std.meta.eql(source.buffer, job.job.source_buffer)) continue;
                    job.addresses[0] = .{ .address = source.address, .bytes = source.logical_bytes };
                    job.transfer = try running.copyTransfer();
                    job.ticket = try fifo.prepareCopy(job.transfer.?);
                    const io = target.port.owner.?; const gate = io.admit_copy.?;
                    try gate(io.context, &target.port, fifo, job.ticket.?, job.deadline);
                    job.transfer.?.rows.?.target_pitch += 64;
                    try t.expectError(error.Binding, gate(io.context, &target.port, fifo, job.ticket.?, job.deadline));
                    job.transfer.?.rows.?.target_pitch -= 64;
                    job.references[0].buffer.id += 1;
                    try t.expectError(error.Binding, gate(io.context, &target.port, fifo, job.ticket.?, job.deadline));
                    job.references[0].buffer.id -= 1;
                    const at = @import("gsp_copy_wire.zig").push_offset + (fifo.ring.issued % @import("gsp_copy_wire.zig").capacity) * @import("gsp_copy_wire.zig").slot_bytes;
                    const pitch: *u32 = @ptrFromInt(fifo.ring.cpu.cpu_address + at + 7 * 4);
                    pitch.* ^= 4;
                    try t.expectError(error.Binding, gate(io.context, &target.port, fifo, job.ticket.?, job.deadline));
                    pitch.* ^= 4;
                    try gate(io.context, &target.port, fifo, job.ticket.?, job.deadline);
                    fifo.ring.pending = null; job.ticket = null; job.transfer = null; // CPU-only preparation, before PUT.
                    admission_checked = true;
                    break;
                };
            }
            _ = target.step();
            if (target.phase == .ready and running.buffer_active != null) try replyCopyMapping(target);
            if (target.phase == .ready and running.outputs.active()) {
                // A normal output query starts between frames. Its response
                // must drain while Present is pending, without a new mapping.
                if (running.outputs.channel()) |owner| if (owner.exchange.phase == .waiting) {
                    const rpc = &owner.exchange;
                    var response: [@import("gsp_display_rpc.zig").max_request_bytes]u8 = undefined;
                    @memcpy(response[0..rpc.request.len], rpc.request);
                    outputWord(&response, 12, 0x56);
                    outputWord(backing.?, init.queues_offset + init.status_offset + 64, target.session.?.tx_write);
                    try nativeReply(&target.session.?, rpc.function, 0, response[0..rpc.request.len]);
                    _ = target.step(); output_replies += 1;
                };
            }
        }
        try t.expect(steps < 100 and target.phase == .ready and running.copy_job.?.presentation and running.copy_job.?.submitted);
        if (frame == 0) try t.expect(admission_checked and target.session.?.tx_sequence == prior_tx) else
            try t.expect(output_replies == 1 and target.session.?.tx_sequence == prior_tx + output_replies);
        const transfer = running.copy_job.?.transfer.?;
        checkpoint = "transfer";
        try t.expect(transfer.bytes == w * 4 and transfer.rows.?.count == h and transfer.rows.?.source_pitch == 260 and
            transfer.rows.?.target_pitch == 512 and transfer.target == native_source.address + y * 512 + x * 4 and
            running.copy_job.?.references[1].reference.id == 0);
        checkpoint = "execute";
        try model.fetch(fifo, raw[0..@intCast(target.port.window.byte_length)]); _ = target.step();
        try t.expect(running.copy_job != null and model.completed == frame and model.active); // Fetch is not completion.
        try model.execute(); _ = target.step();
        try t.expect(running.copy_job != null and model.completed == frame and model.active); // No semaphore yet.
        for (0..model.vram_data.len) |i| {
            const row = i / 512; const column = i % 512;
            const changed = row >= y and row < y + h and column >= x * 4 and column < (x + w) * 4;
            try t.expectEqual(if (changed) model.host[0][row * 260 + column] else @as(u8, 0xcc), model.vram_data[i]);
        }
        if (native_model.is("context_display_present_timeout")) clock = running.copy_job.?.deadline else {
            try model.signal();
            if (native_model.is("context_display_present_fault")) {
                var rc_payload = @embedFile("fixtures/fault-570.144.bin")[32..80].*;
                outputWord(&rc_payload, 0, try @import("gsp_context.zig").wire.nvEngine(fifo.config.rm_engine));
                // The last changed byte is beyond the tight source span.
                const last_target_byte = transfer.target + (h - 1) * 512 + w * 4 - 1;
                std.mem.writeInt(u64, rc_payload[28..36], last_target_byte, .little);
                try nativeEvent(&target.session.?, 0x1004, &rc_payload);
            }
        }
        checkpoint = "complete";
        _ = target.step();
        if (!native_model.is("context_display_present")) {
            try t.expect(target.phase == .recovering and model.lost and model.active and model.completed == 0 and
                running.copy_job != null and model.dma[0].lease.id != 0 and
                native_model.slots[source_index].gpu.lease.id != 0 and native_model.slots[source_index].imported and
                running.presentation.?.surface.shadow.reference.id != 0);
            if (native_model.is("context_display_present_fault")) {
                const failure_record = running.faults.first_fatal.?;
                try t.expect(failure_record.source == .rc and failure_record.acknowledged and failure_record.target_address_match and !failure_record.source_address_match and
                    failure_record.active_fence.point == model.job.fence.point and failure_record.copy_point == running.copy_job.?.ticket.?.point);
            }
            return;
        }
        try t.expect(target.phase == .ready and running.copy_job == null and model.completed == frame + 1 and
            model.result == a.gfx_queue_result_complete and !model.active and running.presentation.?.surface.valid());
        checkpoint = "queue-empty";
        _ = target.step(); try t.expect(!running.presentation.?.pending);
    }
    const issued = fifo.ring.issued;
    // The common span can describe an invalid row crossing; reject before PUT.
    try model.enqueuePresent(64, 0, 2, 1);
    _ = target.step(); _ = target.step();
    try t.expect(target.phase == .ready and running.copy_job == null and !model.active and model.completed == 3 and
        model.result == a.gfx_queue_result_failed and fifo.ring.issued == issued);
    _ = target.step();
    _ = target.stop();
    try t.expect(model.lost and model.unregisters == 1 and native_model.slots[source_index].imported and
        model.dma[0].lease.id != 0 and running.presentation.?.surface.shadow.reference.id != 0);
}
fn checkDeviceDisplaySubmissions(target: *@import("gsp_device.zig").Device, handle: @import("gsp_runtime.zig").DisplayChannelHandle, deadline: u64, scenario: []const u8) !void {
    const model = @import("gsp_display_test_model.zig").Model;
    const push = @import("gsp_display_push.zig");
    const running = &target.running;
    errdefer |err| std.debug.print("display submission {s}: {s} phase={s} failure={?} work={?}\n", .{scenario,@errorName(err),@tagName(target.phase),target.failure,if(running.display_work)|work|work.core.phase else null});
    try pumpDisplayChannel(target, handle, deadline);
    try t.expect(target.phase == .ready and (try running.displayChannelStatus(handle)).info != null);
    const channel_owner = &running.display_channels[0].?;
    const table_owner = running.display_resources_slot.owner.?;
    const note = table_owner.publishedNotifier(0).?;
    const user = try push.userBase(.core, 0);
    const note_words: [*]u32 = @ptrFromInt(note.cpu.cpu_address);
    try t.expect(note.valid() and note.phase == .ready and model.slots[0].active and model.slots[1].active);
    try running.commitDisplayCore(handle, deadline);
    try t.expectError(error.Busy, running.commitDisplayCore(handle, deadline));
    try t.expectError(error.Busy, running.retireDisplayChannel(handle, deadline));
    const endpoint = target.port.owner.?;
    const admit = endpoint.admit_display_push.?;
    try admit(endpoint.context, &target.port, channel_owner, deadline, .read);
    try t.expectError(error.Binding, admit(endpoint.context, &target.port, channel_owner, deadline + 1, .read));
    var copied = channel_owner.*;
    try t.expectError(error.Binding, admit(endpoint.context, &target.port, &copied, deadline, .read));
    // Exercise the actual write admission before the worker publishes PUT.
    // Roll back only this test's CPU-only preparation, never submitted work.
    const first = &running.display_work.?.core;
    first.ticket = try channel_owner.ring.prepare(0, first.config);
    try note.arm(first.ticket.?.point, deadline);
    try admit(endpoint.context, &target.port, channel_owner, deadline, .publish);
    const first_word: *u32 = @ptrFromInt(channel_owner.ring.cpu.cpu_address);
    first_word.* ^= 1;
    try t.expectError(error.Binding, admit(endpoint.context, &target.port, channel_owner, deadline, .publish)); first_word.* ^= 1;
    note.handle ^= 1;
    try t.expectError(error.Binding, admit(endpoint.context, &target.port, channel_owner, deadline, .publish)); note.handle ^= 1;
    try t.expect(model.words[user / 4] == 0 and channel_owner.ring.issued == 0);
    channel_owner.ring.pending = null; channel_owner.ring.program = null; first.ticket = null;
    note.phase = .ready; note.point = 0; note.deadline = 0;
    if (model.is("context_display_cursor")) model.words[(user + 4) / 4] = 0xffffffff;
    _ = target.step();
    if (!model.is("context_display_cursor")) {
        try t.expect(target.phase == .ready and running.display_work.?.core.phase == .submitted and channel_owner.ring.issued == 1 and
            model.words[user / 4] == channel_owner.ring.put * 4 and note.phase == .submitted);
        model.words[(user + 4) / 4] = model.words[user / 4];
        note_words[0] = 1 << 30; _ = target.step(); // GET and BEGUN are not completion.
        try t.expect(target.phase == .ready and channel_owner.ring.completed == 0 and running.display_work != null);
        if (model.is("context_display_timeout")) clock = deadline else {
            note_words[2] = 0x12345678; note_words[3] = 9;
            note_words[0] = if (model.is("context_display_notifier")) 3 << 30 else 2 << 30;
            if (model.is("context_display_fault")) try nativeEvent(&target.session.?, 0x10ff, &.{});
        }
        _ = target.step();
    }
    if (!model.is("context_display_success")) {
        try t.expect(target.phase == .recovering and running.display_work != null and channel_owner.ring.completed == 0 and
            table_owner.failed and note.failed and note.backing.retained and channel_owner.backing.retained and
            model.slots[0].active and model.slots[0].cpu and model.slots[1].active and model.slots[1].cpu and model.released == 0);
        return;
    }
    try t.expect(target.phase == .ready and running.display_work == null and channel_owner.ring.completed == 1 and
        channel_owner.ring.initialized and note.result.?.timestamp == 0x912345678);
    var wraps: u32 = 0;
    // One bounded 128-update host sequence crosses the real 4-KB ring end.
    // Synthetic GPU GET/notifier writes happen only after actual submission.
    for (2..129) |point| {
        try running.commitDisplayCore(handle, deadline);
        const prior_first = first_word.*;
        _ = target.step(); try t.expect(target.phase == .ready);
        if (running.display_work.?.core.phase == .rewind) {
            wraps += 1;
            try t.expect(model.words[user / 4] == 0 and model.words[(user + 4) / 4] != 0 and first_word.* == prior_first);
            _ = target.step();
            try t.expect(running.display_work.?.core.phase == .rewind and first_word.* == prior_first and channel_owner.ring.issued == point - 1);
            model.words[(user + 4) / 4] = 0; _ = target.step();
            try t.expect(running.display_work.?.core.phase == .prepare and first_word.* == prior_first);
            _ = target.step();
        }
        try t.expect(target.phase == .ready and running.display_work.?.core.phase == .submitted and note_words[0] == 0 and
            channel_owner.ring.issued == point and model.words[user / 4] == channel_owner.ring.put * 4);
        model.words[(user + 4) / 4] = model.words[user / 4];
        note_words[0] = (2 << 30) | @as(u32, @intCast(point));
        _ = target.step();
        try t.expect(target.phase == .ready and running.display_work == null and channel_owner.ring.completed == point);
    }
    try t.expect(wraps == 1 and model.released == 0 and note.valid());
    try running.retireDisplayChannel(handle, deadline);
    try pumpDisplayChannel(target, handle, deadline);
    try t.expect(target.phase == .ready and model.released == 1 and !model.slots[1].active and !model.slots[1].cpu and
        model.slots[0].active and model.slots[0].cpu and note.valid());
    try t.expectError(error.Stale, running.displayChannelStatus(handle));
    _ = target.stop();
    try t.expect(table_owner.failed and note.failed and model.slots[0].active and model.slots[0].cpu);
}
const FifoCounts = struct { allocations: usize = 0, frees: usize = 0, enables: usize = 0, disables: usize = 0, event: bool = false };
fn replyCopyMapping(target: *@import("gsp_device.zig").Device) !void {
    const running = &target.running; const session = &target.session.?;
    const owner = running.buffers[running.buffer_active.?].owner.?;
    const rpc = &owner.exchange;
    if (rpc.phase != .waiting) return;
    var response: [1024]u8 = @splat(0); @memcpy(response[0..rpc.request.len], rpc.request);
    const index = owner.source.buffer.id - 1101;
    const mapped_address = @import("gsp_copy_test_model.zig").Model.address(index);
    switch (owner.operation.?) {
        .allocate => { std.mem.writeInt(u64, response[112..120], mapped_address, .little); std.mem.writeInt(u64, response[120..128], owner.mapped_bytes - 1, .little); },
        .map => std.mem.writeInt(u64, response[40..48], mapped_address, .little),
        else => {},
    }
    const status = init.queues_offset + init.status_offset;
    std.mem.writeInt(u32, backing.?[status + 64..][0..4], session.tx_write, .little);
    try nativeReply(session, rpc.function, 0, response[0..rpc.request.len]); _ = target.step();
}
fn checkDeviceCopies(target: *@import("gsp_device.zig").Device, table: *a.DriverApi, scenario: []const u8,
    context_handle: @import("gsp_runtime.zig").ContextHandle, deadline: u64) !void
{
    const model = @import("gsp_copy_test_model.zig").Model;
    const vram_model = @import("gsp_vram_test_model.zig").Model;
    const fifo_model = @import("gsp_fifo_test_model.zig").Model;
    const running = &target.running; const session = &target.session.?;
    var counts: FifoCounts = .{};
    errdefer |err| std.debug.print("copy {s}: {s} phase={s} failure={?} job={} fifo={?} buffer={?} native={?} done={d} outputs={} rpc={s}\n",
        .{scenario,@errorName(err),@tagName(target.phase),target.failure,running.copy_job != null,running.fifo_active,running.buffer_active,running.native_active,
          running.copy_completed,running.outputs.active(),if(running.activeChannel())|rpc|@tagName(rpc.phase) else "none"});
    const instance = try allocateContextStorage(target, 4096, deadline);
    fifo_model.install(table, scenario);
    const handle = try running.createCopyChannel(context_handle, 0, instance, deadline);
    try running.releaseNativeBuffer(instance);
    try driveDeviceFifo(target, &counts, scenario);
    const fifo_owner = running.fifos[handle.slot].owner.?;
    if (target.phase != .ready) {
        try t.expect(vram_model.is("context_copy_changed") and fifo_owner.failure != null and fifo_owner.namespace_live and
            fifo_model.slots[0].active and fifo_model.slots[0].cpu and fifo_owner.live);
        return;
    }
    if (fifo_owner.info()) |value| {
        try t.expect(value.config.copy_class == 0xc7b5 and value.config.system_userd and value.config.userd == fifo_owner.commands.?.backing.pages[2]);
        if (std.mem.startsWith(u8, scenario, "context_upload") or std.mem.startsWith(u8, scenario, "context_display")) { try checkDeviceDisplayUpload(target, table, handle, deadline, scenario); return; }
        const data_handle = try allocateContextBuffer(target, 8191, deadline, false);
        const data_info = (try running.nativeBufferStatus(data_handle)).info.?;
        model.install(table, data_info.reference.buffer.id - 801);
        for (&model.host[0], 0..) |*v, i| v.* = @truncate(i * 37 + 11);
        const raw: [*]const u8 = @ptrFromInt(target.port.window.cpu_address);
        const mmio = raw[0..@intCast(target.port.window.byte_length)];
        const capacity = vram_model.is("context_copy_capacity");
        if (capacity) {
            model.reject_resource = true; model.enqueue(false);
            const prior = session.tx_sequence;
            try t.expect(try running.beginCopyWork(handle, model.binding, deadline));
            try t.expect(running.copy_job == null and !model.active and !model.lost and model.result == a.gfx_queue_result_failed and
                model.heldReferences() == 0 and fifo_owner.ring.issued == 0 and session.tx_sequence == prior);
            const record = &running.faults.records[(running.faults.serial - 1) % 16];
            try t.expect(record.kind == .resource and !record.fatal and running.failure == null);
            model.reject_resource = false; model.enqueue(false);
            var changed = model.binding; changed.reset_generation += 1;
            try t.expectError(error.Stale, running.beginCopyWork(handle, changed, deadline));
            try t.expect(model.queued and !model.active); // The stale owner never takes the queued successor.
            try t.expect(try running.beginCopyWork(handle, model.binding, clock + 1));
            clock += 1; _ = target.step();
            try t.expect(running.copy_job == null and running.failure == null and !model.lost and model.result == a.gfx_queue_result_failed and
                model.heldReferences() == 0 and fifo_owner.ring.issued == 0 and session.tx_sequence == prior);
            try running.releaseNativeBuffer(data_handle);
        }
        const repeats: usize = if (capacity) 0 else if (vram_model.is("context_copy_success")) 514 else 1;
        for (0..repeats) |iteration| {
            const readback = iteration % 2 == 1;
            model.enqueue(readback);
            const prior_tx = session.tx_sequence;
            try t.expect(try running.beginCopyWork(handle, model.binding, deadline));
            if (iteration == 0) try running.releaseNativeBuffer(data_handle);
            var steps: usize = 0;
            while (target.phase == .ready and running.copy_job != null and !running.copy_job.?.submitted and steps < 100) : (steps += 1) {
                _ = target.step();
                if (target.phase == .ready and running.buffer_active != null) try replyCopyMapping(target);
            }
            try t.expect(steps < 100 and target.phase == .ready and running.copy_job.?.submitted);
            if (iteration >= 2) try t.expect(session.tx_sequence == prior_tx); // Repeated transfers reuse actual mappings.
            try t.expectError(error.Busy, running.retireExecutionChannel(handle, deadline, true));
            try t.expectError(error.Busy, running.beginDestroyGraph(deadline, true));
            if (running.copy_job.?.mappings[if (readback) 1 else 0]) |mapped|
                try t.expectError(error.Busy, running.retireBuffer(mapped, deadline, true));
            const held = model.heldReferences();
            try t.expect(held >= 3 and vram_model.slots[model.native_index].imported);
            try model.fetch(fifo_owner, mmio);
            _ = target.step(); // GPGet advances; semaphore and completion remain unchanged.
            try t.expect(model.completed == iteration and running.copy_job != null and model.heldReferences() == held);
            try model.execute();
            _ = target.step();
            try t.expect(model.completed == iteration and model.heldReferences() == held);
            if (iteration == 1) try t.expect(std.mem.allEqual(u8, model.host[1][71..][0..4091], 0xa5));
            if (try checkCopyFault(target, fifo_owner, handle, deadline, scenario, held)) return;
            if (vram_model.is("context_copy_timeout") or vram_model.is("context_copy_completion")) {
                if (vram_model.is("context_copy_timeout")) clock = deadline
                else std.mem.writeInt(u32, fifo_model.slots[0].data[8704..8708], fifo_owner.ring.issued + 1, .little);
                _ = target.step();
                try t.expect(target.phase == .recovering and running.copy_job != null and model.active and model.heldReferences() == held and
                    fifo_model.slots[0].active and fifo_model.slots[0].cpu and vram_model.slots[model.native_index].live);
                try t.expect(target.failure.? == if (vram_model.is("context_copy_timeout")) error.Timeout else error.Completion);
                try t.expect(model.lost and model.result == a.gfx_queue_result_device_lost and model.unregisters == 1 and
                    running.quarantine_result.? == a.gfx_queue_error_busy);
                return;
            }
            try model.signal(); _ = target.step();
            try t.expect(running.copy_job == null and model.completed == iteration + 1 and model.result == a.gfx_queue_result_complete and fifo_owner.ring.idle());
            if (vram_model.is("context_copy_lost_idle")) {
                var xid: [272]u8 = @splat(0); outputWord(&xid, 0, 79);
                try nativeEvent(session, 0x1006, &xid); _ = target.step();
                try t.expect(target.phase == .recovering and model.lost and model.unregisters == 1 and running.quarantine_result.? == a.gfx_queue_ok and
                    running.copy_job == null and model.completed == 1 and fifo_model.slots[0].active);
                return;
            }
            if (readback) try t.expectEqualSlices(u8, model.host[0][33..][0..4091], model.host[1][71..][0..4091])
            else try t.expectEqualSlices(u8, model.host[0][33..][0..4091], model.vram_data[129..][0..4091]);
        }
        if (!capacity) try t.expect(fifo_owner.ring.put == 2 and fifo_owner.ring.issued == 514 and running.copy_completed == 514);
        // Bounds are rejected before a GPU put or doorbell can advance.
        if (!capacity) {
            model.enqueue(false); model.job.byte_length = 9000;
            const old_put = fifo_owner.ring.put;
            try t.expect(try running.beginCopyWork(handle, model.binding, deadline)); _ = target.step();
            try t.expect(running.copy_job == null and model.result == a.gfx_queue_result_failed and fifo_owner.ring.put == old_put);
        }
        model.closeApp();
    } else {
        try t.expect((vram_model.is("context_copy_class") or vram_model.is("context_copy_allocate") or vram_model.is("context_copy_oom") or
            vram_model.is("context_copy_invalid")) and fifo_owner.ring.self_address == 0);
        const record = &running.faults.records[(running.faults.serial - 1) % 16];
        if (vram_model.is("context_copy_oom") or vram_model.is("context_copy_invalid"))
            try t.expect(record.source == .rm and !record.fatal and record.operation == .channel and record.rm_handle == fifo_owner.config.handle and
                record.kind == if (vram_model.is("context_copy_oom")) @as(@import("gsp_faults.zig").Kind, .resource) else .invalid_channel);
    }
    @import("gsp_buffer_test_model.zig").Model.closeHeapAdmission(table);
    try running.beginDestroyGraph(deadline, true);
    var steps: usize = 0;
    while (target.phase == .ready and steps < 300) : (steps += 1) {
        _ = target.step();
        if (target.phase != .ready) break;
        if (running.fifo_active != null) { try replyDeviceFifo(target, &counts, scenario); continue; }
        const rpc = running.activeChannel().?;
        if (rpc.phase != .waiting) continue;
        var response: [4096]u8 = @splat(0); @memcpy(response[0..rpc.request.len], rpc.request);
        const status = init.queues_offset + init.status_offset;
        std.mem.writeInt(u32, backing.?[status + 64..][0..4], session.tx_write, .little);
        try nativeReply(session, rpc.function, 0, response[0..rpc.request.len]); _ = target.step();
    }
    try t.expect(steps < 300 and target.phase == .recovering and target.failure.? == error.RmClosed and vram_model.charged == 0 and fifo_model.released == 1);
    for (&running.fifos) |*slot| try t.expect(slot.owner == null);
    for (&running.buffers) |*slot| try t.expect(slot.owner == null);
    if (vram_model.is("context_copy_success")) try t.expect(model.heldReferences() == 0);
}
fn checkCopyFault(target: *@import("gsp_device.zig").Device, fifo_owner: *@import("gsp_fifo.zig").Owner,
    handle: @import("gsp_runtime.zig").ChannelHandle, deadline: u64, scenario: []const u8, held: usize) !bool
{
    const cases = [_][]const u8{ "context_copy_rc", "context_copy_rc_unmatched", "context_copy_mmu", "context_copy_xid",
        "context_copy_fault_ack", "context_copy_irq", "context_copy_fastpath" };
    var matched = false; for (cases) |name| if (std.mem.eql(u8, scenario, name)) { matched = true; };
    if (!matched) return false;
    const model = @import("gsp_copy_test_model.zig").Model;
    const native_model = @import("gsp_vram_test_model.zig").Model;
    const fifo_model = @import("gsp_fifo_test_model.zig").Model;
    const running = &target.running; const session = &target.session.?;
    const rc = native_model.is("context_copy_rc");
    const irq = native_model.is("context_copy_irq");
    const mmu = native_model.is("context_copy_mmu");
    const xid = native_model.is("context_copy_xid");
    const ack_failure = native_model.is("context_copy_fault_ack");
    const unmatched = native_model.is("context_copy_rc_unmatched");
    const fastpath = native_model.is("context_copy_fastpath");
    const golden = @embedFile("fixtures/fault-570.144.bin");
    const prior_tx = session.tx_sequence;
    const prior_irqs = target.interrupts.interrupts;
    if (rc) try model.signal(); // Error and valid semaphore are simultaneously observable.
    if (irq) {
        const irqs = @import("gsp_irq.zig"); const words: [*]u32 = @ptrFromInt(target.port.window.cpu_address);
        words[irqs.reg.top / 4] = 8; words[(irqs.reg.leaf + 24) / 4] = 512;
        words[irqs.reg.mask / 4] = 0xff; words[irqs.reg.status / 4] = 0x42;
        const before = range_calls;
        try t.expect(IrqModel.dispatch(IrqModel.irq) == a.irq_result_handled and range_calls == before and running.faults.first_fatal == null);
    } else if (mmu) try nativeEvent(session, 0x1005, &.{}) else if (xid) {
        const payload = golden[80..352].*;
        try nativeEvent(session, 0x1006, &payload);
    } else {
        var payload = golden[32..80].*;
        outputWord(&payload, 0, if (unmatched) 0x777 else try @import("gsp_context.zig").wire.nvEngine(fifo_owner.config.rm_engine));
        if (fastpath) outputWord(&payload, 16, 141);
        try nativeEvent(session, 0x1004, &payload);
        if (ack_failure) range_failure_call = range_calls + 4;
    }
    _ = target.step(); range_failure_call = 0;
    try t.expect(target.phase == .recovering and running.copy_job != null and model.active and model.lost and model.completed == 0 and
        model.heldReferences() == held and fifo_model.slots[0].active and fifo_model.slots[0].cpu and native_model.slots[model.native_index].live);
    try t.expect(model.result == a.gfx_queue_result_device_lost and model.unregisters == 1 and running.quarantine_result.? == a.gfx_queue_error_busy);
    const record = &running.faults.first_fatal.?;
    try t.expect(record.epoch == running.epoch and record.active_fence.point == model.job.fence.point and record.copy_point == 1 and
        record.acknowledged == (!irq and !ack_failure) and (session.pending != null) == ack_failure and session.tx_sequence == prior_tx);
    if (irq) try t.expect(record.source == .irq and record.irq_raw == 0x42 and record.irq_mask == 0xff and record.irq_received == prior_irqs + 1)
    else if (mmu) try t.expect(record.source == .mmu_queue and record.kind == .mmu and record.fault_address == null)
    else if (xid) try t.expect(record.source == .xid and record.kind == .device and record.hardware_channel == null)
    else try t.expect(record.source == .rc and record.hardware_channel.? == 0xabc and record.source_address_match and !record.target_address_match and
        record.candidate_channels == @as(u16, if (unmatched) 0 else 1) and record.candidate_rm_handle == @as(u32, if (unmatched) 0 else fifo_owner.config.handle));
    // Late semaphore writes and a caller's quiesced=true cannot revive/free
    // this epoch or let a successor binding consume the retained job.
    if (!rc) try model.signal();
    var successor = model.binding; successor.reset_generation += 1;
    try t.expectError(error.State, running.beginCopyWork(handle, successor, deadline));
    try t.expectError(error.State, running.retireExecutionChannel(handle, deadline, true));
    try t.expectError(error.State, running.beginDestroyGraph(deadline, true));
    try t.expectError(error.State, running.step()); running.stop(error.Stopped);
    try t.expect(model.unregisters == 1 and model.heldReferences() == held and model.active and fifo_owner.ring.completed == 0);
    return true;
}
fn replyDeviceFifo(target: *@import("gsp_device.zig").Device, counts: *FifoCounts, scenario: []const u8) !void {
    const model = @import("gsp_vram_test_model.zig").Model;
    const fifo_model = @import("gsp_fifo_test_model.zig").Model;
    const running = &target.running; const session = &target.session.?;
    const owner = running.fifos[running.fifo_active.?].owner.?;
    const channel = owner.channel().?;
    if (channel.phase != .waiting) return;
    const deadline = owner.deadline;
    const command = init.queues_offset + init.command_offset; const status = init.queues_offset + init.status_offset;
    const cursor = (session.tx_write + 62) % 63;
    const record = try transport.message.decode(session.profile, backing.?[command + 4096 + cursor * 4096..][0..4096], session.tx_sequence - 1);
    try t.expectEqualSlices(u8, channel.request, record.payload);
    try t.expect(owner.info() == null and owner.parent.?.held());
    try t.expect(owner.instance.info() != null and (owner.config.system_userd or owner.userd.info() != null) and model.slots[0].imported);
    channel.phase = .prepared;
    try target.port.owner.?.admit_command.?(target.port.owner.?.context, &target.port, deadline);
    var moved = owner.*; try t.expect(!moved.matches(channel, deadline)); try t.expectError(error.Stale, moved.poll());
    const original = channel.request; channel.request = record.payload;
    try t.expectError(error.Binding, target.port.owner.?.admit_command.?(target.port.owner.?.context, &target.port, deadline));
    channel.request = original; channel.phase = .waiting;
    var response: [428]u8 = @splat(0); @memcpy(response[0..channel.request.len], channel.request);
    var fifo_operation: ?@import("gsp_fifo_wire.zig").Operation = null;
    if (owner.state == .command_creating or owner.state == .command_destroying) {
        const commands = &owner.commands.?;
        if (commands.caps_active) @memcpy(response[24..27], &running.graph.?.control_buffer.?.caps.?.raw) else switch (commands.operation.?) {
            .allocate => {
                const index = commands.backing.reference.reference.id - 901;
                std.mem.writeInt(u64, response[112..120], fifo_model.address(index), .little);
                std.mem.writeInt(u64, response[120..128], 12287, .little);
            },
            .map => std.mem.writeInt(u64, response[40..48], commands.address, .little),
            .unmap, .free_virtual, .free_memory => try t.expect(!owner.live and !owner.enabled),
            .register => try t.expect(!owner.live),
        }
    } else {
        const op = owner.operation.?;
        fifo_operation = op;
        switch (op) {
            .classes => { outputWord(&response, 24, if (model.is("context_copy_class")) 0 else 2); outputWord(&response, 28, 0xc6b5); outputWord(&response, 32, 0xc7b5); },
            .allocate => {
                counts.allocations += 1; outputWord(&response, 164, @intCast(37 + counts.allocations));
                try t.expect(@import("gsp_fifo_wire.zig").word(response[0..], 4) == owner.config.context.group);
                try t.expect(@import("gsp_fifo_wire.zig").word(response[0..], 56) == owner.config.context.share);
                try t.expect(@import("gsp_fifo_wire.zig").word(response[0..], 60) == 0);
            },
            .bind => try t.expect(owner.live and !owner.bound and !owner.enabled),
            .token => { try t.expect(owner.bound and !owner.enabled); outputWord(&response, 24, 0x13572468); },
            .allocate_copy => try t.expect(owner.bound and !owner.copy_live and !owner.enabled),
            .enable => { counts.enables += 1; try t.expect(owner.work_submit_token != null and !owner.enabled); },
            .disable => { counts.disables += 1; try t.expect(owner.enabled); },
            .free_copy => try t.expect(owner.copy_live and !owner.enabled and owner.ring.idle()),
            .free => { counts.frees += 1; try t.expect(owner.live and !owner.enabled); },
        }
        if ((op == .allocate and model.is("context_fifo_allocate")) or (op == .bind and model.is("context_fifo_bind")) or
            (op == .token and model.is("context_fifo_token")) or (op == .enable and model.is("context_fifo_enable")) or
            (op == .disable and model.is("context_fifo_disable")) or (op == .free and model.is("context_fifo_free")))
            outputWord(&response, if (op == .allocate) 16 else 12, 0x57);
        if (op == .allocate and model.is("context_fifo_changed")) response[56] ^= 1;
        if (op == .allocate_copy and model.is("context_copy_allocate")) outputWord(&response, 16, 0x57);
        if (op == .allocate_copy and model.is("context_copy_oom")) outputWord(&response, 16, 0x51);
        if (op == .allocate_copy and model.is("context_copy_invalid")) outputWord(&response, 16, 0x21);
        if (op == .allocate_copy and model.is("context_copy_changed")) response[36] ^= 1;
        if (op == .bind and !counts.event) {
            var print: [9]u8 = @splat(0); print[4] = 1; print[8] = 'F';
            try nativeEvent(session, 0x100c, &print); _ = target.step();
            try t.expect(channel.phase == .waiting and channel.deadline == deadline and !owner.bound); counts.event = true;
        }
    }
    std.mem.writeInt(u32, backing.?[status + 64..][0..4], session.tx_write, .little);
    if (fifo_operation == .enable and model.is("context_fifo_timeout")) clock = deadline else {
        try nativeReply(session, channel.function, 0, response[0..channel.request.len]);
        if (fifo_operation == .enable and model.is("context_fifo_ack")) range_failure_call = range_calls + 4;
    }
    _ = scenario;
    _ = target.step(); range_failure_call = 0;
}
fn driveDeviceFifo(target: *@import("gsp_device.zig").Device, counts: *FifoCounts, scenario: []const u8) !void {
    var steps: usize = 0;
    while (target.phase == .ready and target.running.fifo_active != null and steps < 140) : (steps += 1) {
        _ = target.step();
        if (target.phase != .ready or target.running.fifo_active == null) break;
        try replyDeviceFifo(target, counts, scenario);
    }
    try t.expect(steps < 140);
}
fn checkDeviceFifos(target: *@import("gsp_device.zig").Device, table: *a.DriverApi, scenario: []const u8,
    context_handle: @import("gsp_runtime.zig").ContextHandle, deadline: u64) !void
{
    const model = @import("gsp_vram_test_model.zig").Model;
    const fifo_model = @import("gsp_fifo_test_model.zig").Model;
    const running = &target.running; const session = &target.session.?;
    const parent = running.contexts[context_handle.slot].owner.?;
    const count: usize = if (model.is("context_fifo_success")) 2 else 1;
    var handles: [2]@import("gsp_runtime.zig").ChannelHandle = undefined;
    var counts: FifoCounts = .{};
    fifo_model.install(table, scenario);
    errdefer |err| std.debug.print("fifo {s}: {s} phase={s} failure={?} active={?} alloc={d} free={d}\n",
        .{scenario,@errorName(err),@tagName(target.phase),target.failure,running.fifo_active,counts.allocations,counts.frees});
    for (0..count) |i| {
        const instance = try allocateContextStorage(target, 4096, deadline);
        const userd = try allocateContextStorage(target, 512, deadline);
        const sent = session.tx_sequence;
        try t.expectError(error.State, running.createExecutionChannel(context_handle, 1, instance, userd, deadline));
        try t.expectError(error.Bounds, running.createExecutionChannel(context_handle, 0, instance, instance, deadline));
        try t.expect(session.tx_sequence == sent and !model.slots[1 + i * 2].imported);
        handles[i] = try running.createExecutionChannel(context_handle, 0, instance, userd, deadline);
        var forged = handles[i]; forged.serial += 1; try t.expectError(error.Stale, running.executionChannelStatus(forged));
        try t.expectError(error.Busy, running.createExecutionContext(19, deadline));
        try running.releaseNativeBuffer(instance); try running.releaseNativeBuffer(userd);
        try driveDeviceFifo(target, &counts, scenario);
        if (target.phase != .ready) break;
        const result = try running.executionChannelStatus(handles[i]);
        try t.expect(result.state == .handed_off);
        if (result.info) |fifo_info| {
            try t.expect(fifo_info.config.context.group == parent.binding.group and fifo_info.config.context.share == parent.binding.share);
            try t.expect(fifo_info.work_submit_token == 0x13572468 and fifo_info.config.address == fifo_model.address(i));
            try t.expect(fifo_model.slots[i].active and fifo_model.slots[i].synced and parent.held());
            try t.expectError(error.Retained, running.retireExecutionContext(context_handle, deadline));
            try t.expectError(error.Retained, running.retireExecutionChannel(handles[i], deadline, false));
            if (i == 1) {
                const previous = (try running.executionChannelStatus(handles[0])).info.?;
                try t.expect(previous.config.handle != fifo_info.config.handle and previous.config.instance != fifo_info.config.instance and
                    previous.config.userd != fifo_info.config.userd and previous.config.address != fifo_info.config.address and previous.config.methods == fifo_info.config.methods);
            }
        } else try t.expect(result.rejected.? == 0x57 and !parent.held() and fifo_model.released == 1);
    }
    if (target.phase == .ready) {
        @import("gsp_buffer_test_model.zig").Model.closeHeapAdmission(table);
        if (count == 2) {
            try running.retireExecutionChannel(handles[0], deadline, true);
            try driveDeviceFifo(target, &counts, scenario);
            try t.expectError(error.Stale, running.executionChannelStatus(handles[0]));
            try t.expect((try running.executionChannelStatus(handles[1])).info != null and parent.held() and parent.methodStorage(0) != null);
            try t.expect(!fifo_model.slots[0].active and fifo_model.slots[1].active and model.slots[0].imported);
        }
        try running.beginDestroyGraph(deadline, true);
        var steps: usize = 0;
        while (target.phase == .ready and steps < 300) : (steps += 1) {
            _ = target.step();
            if (target.phase != .ready) break;
            if (running.fifo_active != null) { try replyDeviceFifo(target, &counts, scenario); continue; }
            const channel = running.activeChannel().?;
            if (channel.phase != .waiting) continue;
            if (running.context_active != null) {
                for (&running.fifos) |*slot| try t.expect(slot.owner == null);
                try t.expect(!parent.held() and model.slots[0].imported);
            }
            var response: [4096]u8 = @splat(0); @memcpy(response[0..channel.request.len], channel.request);
            const status = init.queues_offset + init.status_offset;
            std.mem.writeInt(u32, backing.?[status + 64..][0..4], session.tx_write, .little);
            try nativeReply(session, channel.function, 0, response[0..channel.request.len]); _ = target.step();
        }
        try t.expect(steps < 300);
    }
    const uncertain = model.is("context_fifo_changed") or model.is("context_fifo_ack") or model.is("context_fifo_timeout") or
        model.is("context_fifo_disable") or model.is("context_fifo_free") or model.is("context_fifo_dma");
    try t.expect(target.phase == .recovering and target.failure != null);
    if (uncertain) {
        const owner = running.fifos[handles[0].slot].owner.?;
        try t.expect(owner.namespace_live and owner.failure != null and parent.held() and model.slots[0].imported and
            owner.instance.info() != null and owner.userd.info() != null and fifo_model.slots[0].active);
        try t.expect(model.charged == 3 * 65536);
        if (model.is("context_fifo_dma")) try t.expect(!owner.live and !owner.enabled and !owner.commands.?.registered);
    } else {
        try t.expect(target.failure.? == error.RmClosed and model.charged == 0 and model.released == 1 + count * 2 and fifo_model.released == count);
        for (&running.fifos) |*slot| try t.expect(slot.owner == null);
        for (&running.contexts) |*slot| try t.expect(slot.owner == null);
        try t.expect(counts.allocations == count and counts.frees == if (model.is("context_fifo_allocate")) @as(usize, 0) else count);
        if (count == 2) try t.expect(counts.enables == 2 and counts.disables == 2);
    }
}

fn checkDeviceVram(target: *@import("gsp_device.zig").Device, table: *a.DriverApi, scenario: []const u8) !void {
    const model = @import("gsp_vram_test_model.zig").Model;
    const runtime = @import("gsp_runtime.zig");
    const running = &target.running;
    const session = &target.session.?;
    const deadline = clock + 5 * std.time.ns_per_s;
    const command = init.queues_offset + init.command_offset;
    const status = init.queues_offset + init.status_offset;
    model.install(table, scenario);
    defer model.dispose(table);
    var handles: [2]runtime.BufferHandle = undefined;
    var messages: usize = 0;
    var interleaved = false;
    const surface = runtime.vram.surface;
    const surfaces = std.mem.startsWith(u8, scenario, "vram_surface_");
    const private_storage = std.mem.startsWith(u8, scenario, "vram_storage");
    var storage_use: runtime.vram.storage.Use = .{};
    const success = model.is("vram_success") or model.is("vram_surface_linear") or model.is("vram_surface_tiled") or model.is("vram_storage");
    const layout: surface.Layout = if (model.is("vram_surface_linear")) .linear else .blocklinear;
    const requests = [_]surface.Request{
        if (model.is("vram_surface_contiguity")) .{ .width = 1920, .height = 1080, .usage = 44, .layout = layout }
            else .{ .width = 1919, .height = 1079, .format = .nv12, .usage = 28, .layout = layout },
        .{ .width = 1920, .height = 1080, .format = .argb8888, .usage = 44, .layout = layout },
    };
    const full: u64 = if (surfaces) (try surface.create(running.adapter_id, running.nativeAddressSpace().?.*, running.nativeMemoryCapabilities().?, requests[0])).allocation_bytes else 64 * 1024 * 1024;
    const total: usize = if (model.is("vram_storage_no_clear")) 0 else if (success) 2 else 1;
    if (model.is("vram_storage_no_clear")) {
        const caps = &running.graph.?.control_buffer.?.caps.?;
        const original = caps.*; caps.raw[2] &= ~@as(u8, 2);
        const sent = session.tx_sequence;
        try t.expectError(error.Unsupported, running.allocateNativeStorage(4096, deadline));
        try t.expect(sent == session.tx_sequence and running.native_active == null and model.charged == 0);
        caps.* = original;
    }
    errdefer |err| std.debug.print("native VRAM {s}: {s} phase={s} failure={?} active={?} messages={d} charge={d}\n",
        .{scenario, @errorName(err), @tagName(target.phase), target.failure, running.native_active, messages, model.charged});
    for (0..total) |index| {
        const plan = if (surfaces) try surface.create(running.adapter_id, running.nativeAddressSpace().?.*, running.nativeMemoryCapabilities().?, requests[index]) else null;
        const bytes: u64 = if (plan) |p| p.descriptor.byte_length else if (index == 0) full - 5 else 4091;
        handles[index] = if (surfaces) try running.allocateNativeSurface(requests[index], deadline)
            else if (private_storage) try running.allocateNativeStorage(bytes, deadline) else try running.allocateNativeBuffer(bytes, deadline);
        var forged = handles[index]; forged.serial += 1;
        try t.expectError(error.Stale, running.nativeBufferStatus(forged));
        var steps: usize = 0;
        while (target.phase == .ready and running.native_active != null and steps < 80) : (steps += 1) {
            _ = target.step();
            if (target.phase != .ready or running.native_active == null) break;
            const channel = running.activeChannel().?;
            if (channel.phase != .waiting) continue;
            const owner = running.native_buffers[running.native_active.?].owner.?;
            const op = owner.operation.?;
            const cursor = (session.tx_write + 62) % 63;
            const record = try transport.message.decode(session.profile, backing.?[command + 4096 + cursor * 4096 ..][0..4096], session.tx_sequence - 1);
            try t.expectEqualSlices(u8, channel.request, record.payload);
            messages += 1;
            channel.phase = .prepared;
            try target.port.owner.?.admit_command.?(target.port.owner.?.context, &target.port, deadline);
            var moved = owner.*;
            try t.expect(!moved.matches(channel, deadline));
            try t.expectError(error.Stale, moved.poll());
            const original = channel.request; channel.request = record.payload;
            try t.expectError(error.Binding, target.port.owner.?.admit_command.?(target.port.owner.?.context, &target.port, deadline));
            channel.request = original; channel.phase = .waiting;
            std.mem.writeInt(u32, backing.?[status + 64 ..][0..4], session.tx_write, .little);
            var response: [160]u8 = @splat(0);
            @memcpy(response[0..channel.request.len], record.payload);
            if (op == .allocate_memory or op == .allocate_virtual) {
                try t.expect(std.mem.readInt(u32, response[12..16], .little) == @as(u32, if (op == .allocate_memory) 0x40 else 0x50a0));
                try t.expect(std.mem.readInt(u64, response[96..104], .little) == owner.bytes);
                std.mem.writeInt(u64, response[112..120], if (op == .allocate_memory) 0x80000000 else model.address(index), .little);
                std.mem.writeInt(u64, response[120..128], owner.bytes - 1, .little);
                if ((op == .allocate_memory and model.is("vram_physical_reject")) or (op == .allocate_virtual and model.is("vram_virtual_reject"))) outputWord(&response, 16, 0x57);
                if (op == .allocate_memory and model.is("vram_size")) std.mem.writeInt(u64, response[96..104], owner.bytes + 65536, .little);
                if (private_storage and op == .allocate_memory) {
                    const policy = owner.storage_policy.?;
                    const attr = std.mem.readInt(u32, response[56..60], .little);
                    try t.expect(((attr >> 27) & 3) == 2 and std.mem.readInt(u32, response[36..40], .little) == 0 and
                        std.mem.readInt(u32, response[40..44], .little) & 0x1000 != 0 and owner.physical_extent == null);
                    std.mem.writeInt(u64, response[112..120], (policy.physical_bytes / 4 * (index + 1)) & ~@as(u64, 65535), .little);
                    if (model.is("vram_storage_bounds")) std.mem.writeInt(u64, response[112..120], policy.physical_bytes, .little);
                    if (model.is("vram_storage_contiguity")) response[59] ^= 0x18;
                }
                if (surfaces) {
                    const attr = std.mem.readInt(u32, response[56..60], .little);
                    try t.expect(((attr >> 16) & 3) == @as(u32, if (layout == .blocklinear) 2 else 0));
                    try t.expect(std.meta.eql(model.slots[index].descriptor, plan.?.descriptor));
                    if (op == .allocate_memory and requests[index].usage & 32 != 0) {
                        try t.expect(std.mem.readInt(u32, response[36..40], .little) == 8 and ((attr >> 27) & 3) == 2);
                        try t.expect(std.mem.readInt(u32, response[40..44], .little) & 0x1000 == 0);
                    }
                    if (op == .allocate_memory and model.is("vram_surface_changed")) response[58] ^= 2;
                    if (op == .allocate_memory and model.is("vram_surface_contiguity")) response[59] ^= 0x18;
                }
            } else if (op == .map) {
                try t.expect(std.mem.readInt(u32, response[32..36], .little) == 0x100 and model.slots[index].live and !model.slots[index].published);
                std.mem.writeInt(u64, response[40..48], model.address(index), .little);
                if (model.is("vram_map_reject")) outputWord(&response, 48, 0x57);
                if (!interleaved) {
                    var print: [9]u8 = @splat(0); print[4] = 1; print[8] = 'V';
                    try nativeEvent(session, 0x100c, &print);
                    _ = target.step();
                    try t.expect(channel.phase == .waiting and channel.deadline == deadline and owner.info() == null);
                    interleaved = true;
                }
            }
            if (op == .map and model.is("vram_timeout")) clock = deadline else {
                try nativeReply(session, channel.function, 0, response[0..channel.request.len]);
                if (op == .map and model.is("vram_ack")) range_failure_call = range_calls + 4;
            }
            _ = target.step(); range_failure_call = 0;
        }
        try t.expect(steps < 80);
        if (target.phase != .ready) break;
        const result = try running.nativeBufferStatus(handles[index]);
        try t.expect(result.state == .handed_off);
        if (result.info) |info| {
            try t.expect(info.address == model.address(index) and info.logical_bytes == bytes and info.allocation_bytes == @as(u64, if (plan) |p| p.allocation_bytes else if (index == 0) full else 65536));
            if (plan) |p| try t.expect(std.meta.eql(info.surface, p));
            try t.expect(model.slots[index].published and model.slots[index].reference);
            if (private_storage) {
                try t.expect(info.physical.?.bytes == info.allocation_bytes and info.physical.?.base != info.address);
                if (index == 0 and !model.is("vram_storage_no_clear")) {
                    if (model.is("vram_storage_acquire")) {
                        try t.expectError(error.Memory, running.retainNativeStorage(handles[0], &storage_use));
                        try t.expect(storage_use.self_address == 0 and !model.slots[0].imported and model.slots[0].gpu.lease.id == 0);
                    } else if (model.is("vram_storage_descriptor")) {
                        try t.expectError(error.Descriptor, running.retainNativeStorage(handles[0], &storage_use));
                        try t.expect(storage_use.retained and !storage_use.close(true) and model.slots[0].imported and model.slots[0].gpu.lease.id != 0);
                        _ = target.step(); break;
                    } else {
                        try running.retainNativeStorage(handles[0], &storage_use);
                        try t.expect(std.meta.eql(storage_use.info().?.physical, info.physical.?));
                        try t.expect(!std.meta.eql(storage_use.info().?.reference.reference, info.reference.reference));
                        var second_use: runtime.vram.storage.Use = .{};
                        try t.expectError(error.Busy, running.retainNativeStorage(handles[0], &second_use));
                        try t.expect(second_use.self_address == 0);
                        var moved = storage_use; try t.expect(moved.info() == null and !moved.close(true));
                        const saved = storage_use.source; storage_use.source.?.physical.base += 65536;
                        try t.expect(storage_use.info() == null and !storage_use.close(true)); storage_use.source = saved;
                        try t.expect(!storage_use.close(false) and storage_use.info() != null);
                    }
                }
            } else try t.expect(info.physical == null);
            var loan = try running.channel.?.handoff(deadline);
            try running.graph.?.reclaim(&loan, deadline);
            const sent = session.tx_sequence;
            try t.expectError(error.Retained, running.graph.?.beginDestroy(deadline));
            try t.expect(session.tx_sequence == sent);
            var returned = try running.graph.?.loan(deadline);
            running.channel = try @import("gsp_exchange.zig").Exchange.init(&returned.runtime, deadline);
        } else {
            try t.expect(result.rejected != null or result.host_rejected != null);
            try t.expect(model.charged == 0 and !model.slots[index].live);
            try running.releaseNativeBuffer(handles[index]);
            if (model.is("vram_budget")) try t.expect(messages == 0 and model.aborted == 0) else try t.expect(model.aborted == 1);
            break;
        }
    }
    if (target.phase == .ready) {
        if (success and !private_storage) model.slots[0].imported = true;
        if (success) @import("gsp_buffer_test_model.zig").Model.closeHeapAdmission(table);
        try t.expectError(error.Busy, running.beginDestroyGraph(deadline, false));
        try running.beginDestroyGraph(deadline, true);
        var steps: usize = 0;
        while (target.phase == .ready and steps < 160) : (steps += 1) {
            _ = target.step();
            if (success and model.released == 1 and model.slots[0].imported) {
                try t.expect(model.charged == full and model.slots[0].live and !model.slots[0].claimed and !model.slots[0].reference);
                if (private_storage) try t.expect(storage_use.close(true)) else model.slots[0].imported = false;
            }
            if (target.phase != .ready) break;
            const channel = running.activeChannel().?;
            if (channel.phase != .waiting) continue;
            var response: [160]u8 = @splat(0); @memcpy(response[0..channel.request.len], channel.request);
            if (running.native_active) |index| {
                const owner = running.native_buffers[index].owner.?;
                try t.expect(owner.state == .destroying and model.slots[index].claimed);
                if (owner.operation.? == .unmap) {
                    try t.expect(std.mem.readInt(u64, response[24..32], .little) == model.address(index));
                    if (model.is("vram_free")) outputWord(&response, 32, 0x57);
                }
            } else try t.expect(model.charged == 0); // Before the first parent free.
            std.mem.writeInt(u32, backing.?[status + 64 ..][0..4], session.tx_write, .little);
            try nativeReply(session, channel.function, 0, response[0..channel.request.len]);
            _ = target.step();
        }
        try t.expect(steps < 160);
    }
    const uncertain = model.is("vram_size") or model.is("vram_ack") or model.is("vram_timeout") or model.is("vram_free") or model.is("vram_finish") or model.is("vram_surface_changed") or model.is("vram_surface_contiguity") or
        model.is("vram_storage_bounds") or model.is("vram_storage_contiguity") or model.is("vram_storage_descriptor");
    try t.expect(target.phase == .recovering and target.failure != null);
    if (uncertain) {
        try t.expect(model.charged == full and model.slots[0].live and running.native_buffers[0].owner != null);
        try t.expect(running.native_buffers[0].owner.?.namespace_live);
    } else {
        try t.expect(target.failure.? == error.RmClosed and model.charged == 0);
        if (success) try t.expect(model.released == 2 and model.aborted == 0);
    }
}

fn checkDeviceMappings(target: *@import("gsp_device.zig").Device, table: *a.DriverApi, scenario: []const u8) !void {
    const model = @import("gsp_buffer_test_model.zig").Model;
    const runtime = @import("gsp_runtime.zig");
    const ex = @import("gsp_exchange.zig");
    const running = &target.running;
    const session = &target.session.?;
    const deadline = clock + 5 * std.time.ns_per_s;
    const command = init.queues_offset + init.command_offset;
    const status = init.queues_offset + init.status_offset;
    const transmitted = try t.allocator.alloc(u8, 65536);
    defer t.allocator.free(transmitted);
    model.install(table, scenario);
    defer model.dispose(table);
    var handles: [2]runtime.BufferHandle = undefined;
    var interleaved = false;
    var registers: usize = 0;
    var maps_done: usize = 0;
    var unmaps: usize = 0;
    var freeing = false;
    var count: usize = 0;
    errdefer |err| std.debug.print("native BO {s}: {s} phase={s} failure={?} active={?} registers={d} maps={d} unmaps={d} refs={any}\n",
        .{scenario, @errorName(err), @tagName(target.phase), target.failure, running.buffer_active, registers, maps_done, unmaps, model.refs});
    while (count < 2 and target.phase == .ready) : (count += 1) {
        handles[count] = try running.mapQueuedBuffer(&model.fence, @intCast(count), deadline);
        try t.expectError(error.Busy, running.mapQueuedBuffer(&model.fence, 0, deadline));
        var steps: usize = 0;
        while (target.phase == .ready and running.buffer_active != null and steps < 700) : (steps += 1) {
            const segment_count = model.segments;
            _ = target.step();
            try t.expect(model.segments - segment_count <= 64);
            if (target.phase != .ready or running.buffer_active == null) break;
            const owner = running.buffers[running.buffer_active.?].owner.?;
            const channel = &owner.exchange;
            if (channel.phase != .waiting) continue;
            try t.expect(running.nativeAddressSpace() == null and running.nativeControlBuffer() == null and owner.info() == null);
            const operation = owner.operation.?;
            const element_count: usize = (channel.request.len + 80 + 4095) / 4096;
            const first = (session.tx_write + 63 - @as(u32, @intCast(element_count))) % 63;
            for (0..element_count) |element| {
                const cursor = (first + element) % 63;
                @memcpy(transmitted[element * 4096 ..][0..4096], backing.?[command + 4096 + cursor * 4096 ..][0..4096]);
            }
            const request = try transport.message.decode(session.profile, transmitted[0 .. element_count * 4096], session.tx_sequence - 1);
            try t.expectEqualSlices(u8, channel.request, request.payload);
            const phase = channel.phase;
            channel.phase = .prepared;
            try target.port.owner.?.admit_command.?(target.port.owner.?.context, &target.port, deadline);
            var moved = owner.*;
            try t.expect(!moved.matches(channel, deadline));
            try t.expectError(error.Stale, moved.poll());
            const original_request = channel.request;
            channel.request = request.payload;
            try t.expectError(error.Binding, target.port.owner.?.admit_command.?(target.port.owner.?.context, &target.port, deadline));
            channel.request = original_request;
            channel.phase = phase;
            std.mem.writeInt(u32, backing.?[status + 64 ..][0..4], session.tx_write, .little);
            var response: [160]u8 = @splat(0);
            const payload = request.payload;
            const response_bytes: usize = if (operation == .register) 0 else payload.len;
            if (response_bytes != 0) @memcpy(response[0..response_bytes], payload);
            const part_offset = @as(u64, owner.operation_part) * @import("gsp_buffer_wire.zig").max_registration_pages * 4096;
            if (operation == .register) {
                registers += 1;
                try t.expect(payload.len == 56 + std.mem.readInt(u32, payload[40..44], .little) * 8);
                for (0..(payload.len - 56) / 8) |page| try t.expect(std.mem.readInt(u64, payload[56 + page * 8 ..][0..8], .little) == model.page(count, part_offset + page * 4096) >> 12);
            } else if (operation == .allocate) {
                try t.expect(std.mem.readInt(u64, payload[96..104], .little) == model.rounded[count]);
                std.mem.writeInt(u64, response[112..120], model.address(count), .little);
                std.mem.writeInt(u64, response[120..128], model.rounded[count] - 1, .little);
            } else if (operation == .map) {
                try t.expect(std.mem.readInt(u64, payload[40..48], .little) == part_offset);
                std.mem.writeInt(u64, response[40..48], model.address(count) + part_offset + @as(u64, if (model.is("mapping_offset")) 4096 else 0), .little);
                maps_done += 1;
                if (model.is("mapping_reject") and owner.operation_part == 1) std.mem.writeInt(u32, response[48..52], 0x57, .little);
                if (!interleaved) {
                    const held_deadline = channel.deadline;
                    var print: [9]u8 = @splat(0); print[4] = 1; print[8] = 'B';
                    try nativeEvent(session, 0x100c, &print);
                    _ = target.step();
                    try t.expect(channel.phase == .waiting and channel.deadline == held_deadline and owner.operation.? == operation and owner.info() == null);
                    interleaved = true;
                }
            } else if (operation == .unmap) {
                try t.expect(std.mem.readInt(u64, payload[24..32], .little) == model.address(count) + part_offset);
                unmaps += 1;
            }
            if (operation == .map and model.is("mapping_timeout")) clock = deadline else {
                try nativeReply(session, request.rpc.function, 0, response[0..response_bytes]);
                if (operation == .map and model.is("mapping_ack")) range_failure_call = range_calls + 4;
            }
            _ = target.step(); range_failure_call = 0;
        }
        try t.expect(steps < 700);
        if (target.phase != .ready) break;
        const result = try running.bufferStatus(handles[count]);
        try t.expect(result.state == .handed_off);
        if (result.info) |info| {
            try t.expect(info.address == model.address(count) and info.logical_bytes == model.rounded[count] - 5 and info.mapped_bytes == model.rounded[count]);
            try t.expect(info.parts == @as(u16, if (count == 0) 3 else 1));
            try t.expect(model.refs[count] and model.dma[count].lease.id != 0 and model.gpu[count].lease.id != 0);
            try t.expectError(error.Busy, running.retireBuffer(handles[count], deadline, false));
            // The parent guard must reject before transmitting even its first
            // event free. Restore the exact loan and keep both children live.
            var token = try running.channel.?.handoff(deadline);
            try running.graph.?.reclaim(&token, deadline);
            const sent = session.tx_sequence;
            try t.expectError(error.Retained, running.graph.?.beginDestroy(deadline));
            try t.expect(session.tx_sequence == sent);
            var loan = try running.graph.?.loan(deadline);
            running.channel = try ex.Exchange.init(&loan.runtime, deadline);
        } else {
            try t.expect(model.is("mapping_reject") or model.is("mapping_segment") or model.is("mapping_gpu"));
            try t.expect(!model.refs[count] and model.releases == 1 and (result.rejected != null or result.host_rejected != null));
            break;
        }
        if (model.is("mapping_release")) break;
    }
    if (target.phase == .ready) {
        if (model.is("mapping_success")) model.closeHeapAdmission(table);
        try t.expectError(error.Busy, running.beginDestroyGraph(deadline, false));
        try running.beginDestroyGraph(deadline, true);
        var steps: usize = 0;
        while (target.phase == .ready and steps < 120) : (steps += 1) {
            _ = target.step();
            if (target.phase != .ready) break;
            const channel = running.activeChannel().?;
            if (channel.phase != .waiting) continue;
            var response: [160]u8 = @splat(0);
            @memcpy(response[0..channel.request.len], channel.request);
            if (running.buffer_active) |index| {
                const owner = running.buffers[index].owner.?;
                try t.expect(!freeing);
                if (owner.operation.? == .unmap) {
                    const offset = @as(u64, owner.operation_part) * @import("gsp_buffer_wire.zig").max_registration_pages * 4096;
                    const selected: usize = if (owner.logical_bytes > 4096) 0 else 1;
                    try t.expect(std.mem.readInt(u64, response[24..32], .little) == model.address(selected) + offset);
                    unmaps += 1;
                }
            } else {
                freeing = true;
                try t.expect(!model.refs[0] and !model.refs[1] and running.buffer_active == null);
                try t.expectError(error.Stale, running.bufferStatus(handles[0]));
            }
            std.mem.writeInt(u32, backing.?[status + 64 ..][0..4], session.tx_write, .little);
            try nativeReply(session, channel.function, 0, response[0..channel.request.len]);
            _ = target.step();
        }
        try t.expect(steps < 120);
        if (!model.is("mapping_release")) {
            try t.expect(freeing and running.graph.?.state == .finished and !ControlModel.active);
            try t.expectError(error.Stale, session.rm_names.validate(running.graph.?.reservation));
            if (model.is("mapping_success")) try t.expect(registers == 4 and maps_done == 4 and unmaps == 4 and model.releases == 2 and model.segments == 20481);
        }
    }
    try t.expect(target.phase == .recovering and running.failure != null and running.nativeObject() == null);
    if (model.is("mapping_offset") or model.is("mapping_ack") or model.is("mapping_timeout") or model.is("mapping_release")) {
        try t.expect(model.refs[0] and model.dma[0].lease.id != 0 and model.releases == 0);
        try t.expectError(error.Retained, session.rm_names.retire(running.graph.?.reservation));
        if (!model.is("mapping_release")) try t.expect(!freeing and unmaps == 0);
    }
}

fn checkDeviceOutputs(target: *@import("gsp_device.zig").Device, words: []u32, frts: u64, scenario: anytype) !void {
    const rpc = @import("gsp_display_rpc.zig");
    const ddc_case = scenario == .outputs_ddc or scenario == .outputs_ddc_bus_changed;
    DeviceModel.receiver_logs = 0;
    DeviceModel.ddc_logs = 0;
    DeviceModel.aux_logs = 0;
    DeviceModel.wiring_logs = 0;
    DeviceModel.hpd_logs = 0;
    DeviceModel.xpio_logs = 0;
    const running = &target.running;
    const owner = &running.outputs;
    const session = &target.session.?;
    const command = init.queues_offset + init.command_offset;
    const status = init.queues_offset + init.status_offset;
    const initial_sequence = session.tx_sequence;
    const mask: u32 = if (scenario == .outputs_empty) 0 else if (scenario == .outputs_all) 0xffffffff else 0x80000001;
    var steps: usize = 0;
    var requests: usize = 0;
    var passes: usize = 0;
    var interleaved = false;
    var aux_segment: u8 = 0;
    var aux_offset: u8 = 0;
    errdefer |err| std.debug.print("actual outputs scenario={s} error={s} phase={s} failure={?} state={s} requests={d} count={d}\n",
        .{@tagName(scenario), @errorName(err), @tagName(target.phase), target.failure, @tagName(owner.state), requests, owner.data.count});
    try t.expect(owner.state == .detached and running.nativeOutputs() == null and running.nativeObject() != null);
    while (target.phase == .ready and steps < 1200) : (steps += 1) {
        _ = target.step();
        if (target.phase != .ready) break;
        if (owner.state == .returned) {
            try t.expect(running.nativeObject() != null and owner.channel() == null);
            if (scenario != .outputs_hpd or passes == 2) break;
            if (passes == 0) {
                try t.expect(interleaved and running.nativeOutputs() == null and !owner.data.coherent);
            } else {
                try t.expect(running.nativeOutputs() != null);
                try devicePost(target, true, false); // Invalidate an already published generation.
                _ = target.step();
                try t.expect(running.nativeOutputs() == null);
                try t.expect(CatalogModel.count == 0 and CatalogModel.invalidations == 1);
            }
            try t.expect(running.output_refresh);
            const sent = session.tx_sequence;
            try t.expect(target.step() == .idle and session.tx_sequence == sent); // One-second coalescing bound.
            clock = running.output_next_ns;
            passes += 1;
            _ = target.step();
            try t.expect(owner.state == .topology and !running.output_refresh);
        }
        try t.expect(running.nativeOutputs() == null and running.nativeObject() == null);
        const source = owner.channel() orelse continue;
        const channel = &source.exchange;
        if (channel.phase != .waiting) continue;
        const query = source.request.?;
        const deadline = channel.deadline.?;
        const cursor = (session.tx_write + 62) % 63;
        const request = try transport.message.decode(session.profile,
            backing.?[command + 4096 + @as(usize, cursor) * 4096 ..][0..4096], session.tx_sequence - 1);
        try t.expect(request.rpc.function == 76 and std.mem.readInt(u32, request.payload[0..4], .little) == running.graph.?.reservation.client);
        try t.expect(std.mem.readInt(u32, request.payload[4..8], .little) ==
            (if (query == .ports or query == .ddc) running.graph.?.base.plan.handles.i2c else running.graph.?.base.plan.handles.display));
        try t.expect(std.mem.readInt(u32, request.payload[8..12], .little) == @intFromEnum(std.meta.activeTag(query)));
        try t.expect(std.mem.readInt(u32, request.payload[20..24], .little) == @as(u32, if (query == .ddc) 2 else if (query == .aux) 1 else 0) and channel == running.activeChannel());
        var response: [rpc.max_request_bytes]u8 = @splat(0);
        const payload = response[0..request.payload.len];
        @memcpy(payload, request.payload);
        outputWord(backing.?, status + 64, session.tx_write); // Real modeled command consumer, including ring wrap.
        if (requests == 0) {
            const native = target.port.owner.?;
            const saved = channel.request;
            const function = channel.function;
            const before = range_calls;
            var foreign: [rpc.max_request_bytes]u8 = @splat(0);
            @memcpy(foreign[0..saved.len], saved);
            channel.phase = .prepared;
            channel.request = foreign[0..saved.len];
            try t.expectError(error.Binding, native.admit_command.?(native.context, &target.port, deadline));
            channel.request = saved;
            channel.function = 103;
            try t.expectError(error.Binding, native.admit_command.?(native.context, &target.port, deadline));
            channel.function = function;
            try native.admit_command.?(native.context, &target.port, deadline);
            channel.phase = .waiting;
            try t.expect(range_calls == before and running.channel.?.phase == .handed_off);
            try t.expectError(error.State, running.channel.?.poll(deadline));
            try t.expect(session.state == .active);
        }
        if (scenario == .outputs_hpd and passes == 0 and !interleaved and owner.data.count == 1) {
            try devicePost(target, false, false);
            _ = target.step();
            try t.expect(owner.invalidated and source.pending == null and session.pending == null and channel.phase == .waiting);
            interleaved = true;
        }
        if (scenario == .outputs_sequence and query == .edid and !interleaved) {
            try deviceSequence(target, &.{ 3, 1 });
            _ = target.step();
            try t.expect(running.sequence.self_address != 0 and source.pending != null);
            for (0..10) |_| {
                if (running.sequence.self_address == 0) break;
                clock += 1000;
                _ = target.step();
            }
            try t.expect(running.sequence.self_address == 0 and source.pending == null and session.pending == null);
            try nativeEvent(session, 0x101c, &.{1});
            _ = target.step();
            try t.expect(channel.in_lockdown and !running.channel.?.in_lockdown);
            try nativeEvent(session, 0x101c, &.{0});
            _ = target.step();
            try t.expect(!channel.in_lockdown and channel.deadline == deadline and owner.invalidated and source.pending == null);
            interleaved = true;
        }
        switch (query) {
            .heads => outputWord(payload, 32, if (scenario == .outputs_empty) 0 else if (scenario == .outputs_all) 32 else 4),
            .active => |head| {
                outputWord(payload, 36, if (head == 0) mask & 1 else if (head == 3) mask & 0x80000000 else 0);
                if (scenario == .outputs_partial and head == 1) outputWord(payload, 12, 0x55);
            },
            .supported => {
                const changed = (scenario == .outputs_changed and owner.state == .topology and owner.probe.?.state == .verify) or
                    (scenario == .outputs_final_changed and owner.state == .final_check);
                outputWord(payload, 28, if (changed) 1 else mask);
                outputWord(payload, 32, if (changed) 1 else mask);
                if (scenario == .outputs_rejected) outputWord(payload, 12, 0x55);
                if (scenario == .outputs_final_rejected and owner.state == .final_check) outputWord(payload, 12, 0x66);
            },
            .connectors => |id| {
                outputWord(payload, 32, 1);
                outputWord(payload, 36, 0x80000001);
                outputWord(payload, 40, if (scenario == .outputs_virtual) 1 else 2);
                outputWord(payload, 44, 17);
                outputWord(payload, 48, 0x61);
                outputWord(payload, 52, 4);
                outputWord(payload, 56, 19);
                outputWord(payload, 60, 0xffffffff);
                outputWord(payload, 64, 2);
                if (scenario == .outputs_partial and id == 1) outputWord(payload, 12, 0x55);
            },
            .resource => |id| {
                outputWord(payload, 32, 0xffffffff); // Unassigned OR must remain unassigned.
                outputWord(payload, 36, 2);
                outputWord(payload, 40, if (scenario == .outputs_aux) 8 else 1);
                outputWord(payload, 56, 1);
                outputWord(payload, 60, 27); // DCB index is not log2(RM display ID).
                payload[72] = 1;
                payload[73] = @intFromBool(id == 0x80000000);
            },
            .buses => {
                outputWord(payload, 32, 0);
                outputWord(payload, 36, if (ddc_case) (if (scenario == .outputs_ddc_bus_changed and owner.state == .receivers) @as(u32, 4) else 3) else 37);
            },
            .connected => |id| outputWord(payload, 32, if (id == 1 and scenario != .outputs_all) 1 else 0),
            .edid => {
                try t.expect(std.mem.readInt(u32, payload[36..40], .little) == 2); // RAW; no cached boot EDID.
                outputWord(payload, 32, if (scenario == .outputs_missing) 0 else 256);
                outputEdid(payload[40..296], scenario == .outputs_incomplete or ddc_case or scenario == .outputs_aux, scenario == .outputs_bad_edid);
                if (scenario == .outputs_edid_rejected) outputWord(payload, 12, 0x55);
            },
            .ports => {
                try t.expect(ddc_case);
                payload[26] = 7;
                payload[27] = 7;
            },
            .ddc => |ddc| {
                try t.expect(ddc_case and ddc.port == @as(u8, if (scenario == .outputs_ddc_bus_changed) 3 else 2) and ddc.display_id == 1);
                var blob: [4096]u8 = @splat(0);
                outputEdidFull(&blob);
                _ = try rpc.ddc_wire.encode(.{ .port = ddc.port, .block = ddc.block }, blob[@as(usize, ddc.block) * 128 ..][0..128], payload[24..]);
            },
            .aux => |request_aux| {
                try t.expect(scenario == .outputs_aux and request_aux.display_id == 1);
                const operation = request_aux.operation;
                const count = rpc.aux_wire.length(operation);
                outputWord(payload, 60, count);
                switch (operation) {
                    .caps => payload[44] = 0x14,
                    .segment => |segment| aux_segment = segment,
                    .offset => |offset| aux_offset = offset,
                    .read => |read| {
                        var blob: [4096]u8 = undefined;
                        outputEdidFull(&blob);
                        const position = @as(usize, aux_segment) * 256 + aux_offset;
                        @memcpy(payload[44..][0..count], blob[position..][0..count]);
                        aux_offset +%= count;
                        if (read.last) aux_segment = 0;
                    },
                    else => return error.UnexpectedAux,
                }
            },
        }
        if (scenario == .outputs_timeout and requests == 0) clock = deadline else {
            try nativeEvent(session, 76, payload);
            if (scenario == .outputs_ack and owner.state == .receivers and owner.data.count == 1 and query == .connected)
                range_failure_call = range_calls + 4;
        }
        _ = target.step();
        range_failure_call = 0;
        requests += 1;
    }
    try t.expect(steps < 1200);
    if (target.phase != .ready) {
        try t.expect(scenario == .outputs_ack or scenario == .outputs_timeout or scenario == .catalog_rejected);
        try t.expect(!CatalogModel.active and CatalogModel.count == 0);
        try t.expect(target.phase == .recovering and running.nativeOutputs() == null and running.nativeObject() == null);
        try t.expectError(error.Retained, session.rm_names.retire(running.graph.?.reservation));
        const pending = session.pending;
        const sent = session.tx_sequence;
        var count: usize = 0;
        while (target.phase != .failed and count < 12000) : (count += 1) {
            clock += 1000;
            DeviceModel.tick(words, frts, false);
            _ = target.step();
        }
        try t.expect(count < 12000 and target.memory.?.retained and target.interrupts.closed and target.recovery.report != null);
        try t.expect(session.tx_sequence == sent and std.meta.eql(pending, session.pending));
        return;
    }
    try t.expect(session.tx_sequence == initial_sequence + requests and session.pending == null and running.graph.?.state == .loaned);
    try t.expect(owner.state == .returned and running.output_generation == @as(u64, if (scenario == .outputs_hpd) 3 else 1));
    if (scenario == .outputs_changed or scenario == .outputs_ddc_bus_changed or scenario == .outputs_final_changed or scenario == .outputs_final_rejected or scenario == .outputs_sequence) {
        try t.expect(!owner.data.coherent and running.nativeOutputs() == null);
        if (scenario == .outputs_ddc_bus_changed) try t.expect(CatalogModel.count == 0);
        if (scenario == .outputs_final_rejected) try t.expect(owner.data.final_rejection.?.control.? == 0x66);
        return;
    }
    const data = running.nativeOutputs() orelse return error.MissingOutputs;
    const expected: usize = if (scenario == .outputs_rejected or scenario == .outputs_empty) 0 else @popCount(mask);
    try t.expect(data.count == expected and data.topology.count == expected and data.coherent);
    try t.expect(data.topology.epoch == target.epoch and data.topology.client == running.graph.?.reservation.client);
    if (scenario == .outputs_rejected) try t.expect(data.topology.rejected.?.control.? == 0x55);
    try t.expect(CatalogModel.count == expected and target.catalog.published == (expected != 0));
    if (expected == 0) return;
    try t.expect(CatalogModel.first.connector_id == 1 and CatalogModel.last.connector_id == 0x80000000);
    if (scenario == .outputs_wiring) {
        const wire = &data.topology.routes[0].wiring;
        try t.expect(wire.relation.static.index == 27 and wire.connector.?.index == 0 and wire.physical.?.index == 17);
        try t.expect(wire.hpd[0].?.line.? == 3 and wire.external_dongle[0].?.table.? == 1);
        try t.expect(CatalogModel.first.connector_kind == a.gfx_output_kind_hdmi);
        try t.expect(DeviceModel.wiring_logs == 2 and DeviceModel.hpd_logs == 1 and DeviceModel.xpio_logs == 1);
        try t.expect(target.board.?.validated_device.? == 0x2504 and target.running.outputs.board == &target.board.?);
    } else try t.expect(CatalogModel.first.connector_kind == 0); // No invented identity for multiple records or a virtual path.
    if (scenario == .outputs_virtual) try t.expect(data.topology.routes[0].wiring.relation == .virtual and DeviceModel.hpd_logs == 0 and DeviceModel.xpio_logs == 0);
    const first = &data.receivers[0];
    try t.expect(first.display_id == 1 and first.client == data.topology.client and first.epoch == target.epoch);
    try t.expect(data.topology.routes[0].resource.?.index == 0xffffffff and data.topology.routes[0].resource.?.dcb_index == 27);
    if (scenario == .outputs_partial) try t.expect(data.topology.routes[0].connectors == null and data.topology.routes[0].rejections[0].?.control.? == 0x55)
    else try t.expect(data.topology.routes[0].connectors.?.data[0].index == 17 and
        (scenario == .outputs_virtual or data.topology.routes[0].connectors.?.data[1].kind == 0xffffffff));
    try t.expect(data.topology.routes[0].buses.?.communication == 0 and
        data.topology.routes[0].buses.?.ddc == @as(u32, if (scenario == .outputs_ddc) 3 else 37));
    if (scenario == .outputs_partial) try t.expect(data.topology.activeHeads(1) == null and data.topology.heads[1].rejected.?.control.? == 0x55)
    else try t.expect(data.topology.activeHeads(1).? == 1 and data.topology.activeHeads(0x80000000).? == 8);
    if (scenario == .outputs_all) {
        try t.expect(requests == 229 and data.final_receipt_serial != 0 and data.receivers[31].display_id == 0x80000000);
        for (&data.receivers) |*capture| try t.expect(capture.status == .disconnected and capture.edid_bytes == 0);
    } else {
        const expected_status: @import("gsp_receiver.zig").Status = switch (scenario) {
            .outputs_missing => .edid_missing,
            .outputs_incomplete => .incomplete_edid,
            .outputs_bad_edid => .invalid_edid,
            .outputs_edid_rejected => .edid_rejected,
            else => .valid_edid,
        };
        try t.expect(first.status == expected_status and first.connected.?);
        if (first.status == .valid_edid) try t.expect(first.report.hdmi and first.report.mode_count != 0 and first.report.audio_count != 0);
        if (scenario == .outputs_ddc) try t.expect(first.source == .ddc and first.edid_bytes == 4096 and first.report.declared_extensions == 31 and first.report.complete());
        if (scenario == .outputs_aux) try t.expect(first.source == .aux and first.edid_bytes == 4096 and first.aux_caps_bytes == 16 and first.report.complete());
        if (scenario == .outputs_ddc) try t.expect(DeviceModel.receiver_logs == 2 and DeviceModel.ddc_logs == 1);
        if (scenario == .outputs_aux) try t.expect(DeviceModel.receiver_logs == 2 and DeviceModel.aux_logs == 1);
        const published = &CatalogModel.first;
        try t.expect(published.flags & a.gfx_output_flag_connected != 0 and CatalogModel.last.edid_bytes == 0 and CatalogModel.last.mode_count == 0);
        switch (first.status) {
            .valid_edid => try t.expect(published.mode_count > 0 and published.edid_bytes == first.edid_bytes),
            .edid_missing => try t.expect(published.flags & a.gfx_output_flag_edid_missing != 0 and published.mode_count == 0),
            .edid_rejected => try t.expect(published.flags & a.gfx_output_flag_query_failed != 0 and published.mode_count == 0),
            .invalid_edid => try t.expect(published.flags & a.gfx_output_flag_edid_invalid != 0 and published.mode_count == 0),
            .incomplete_edid => try t.expect(published.flags & a.gfx_output_flag_receiver_incomplete != 0),
            else => return error.UnexpectedReceiver,
        }
        try t.expect(data.receivers[1].display_id == 0x80000000 and data.receivers[1].status == .disconnected);
        try t.expect(data.receivers[1].report.audio_count == 0 and data.receivers[1].edid_bytes == 0);
    }
}

fn checkDeviceRuntime(target: *@import("gsp_device.zig").Device, words: []u32, frts: u64, scenario: anytype) !void {
    const core = @import("gsp_core.zig");
    const original_deadline = target.deadline;
    const reader = target.reader.?;
    const initial_events = target.running.snapshot.events;
    const initial_sequencers = target.running.snapshot.sequencers;
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
            std.mem.writeInt(u32, xid[0..4], 23, .little);
            std.mem.writeInt(u32, xid[4..8], 3, .little);
            std.mem.writeInt(u32, xid[8..12], 4, .little);
            @memcpy(xid[12..16], "diag");
            try nativeEvent(&target.session.?, 0x1006, &xid);
            try t.expect(target.step() == .progress and target.running.snapshot.xid_count == 1 and target.running.snapshot.last_xid == 23);
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
            try t.expect(count < 16 and target.running.snapshot.sequencers == initial_sequencers + 1 and words[core.reg.mailbox0 / 4] == 0x7979);
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
