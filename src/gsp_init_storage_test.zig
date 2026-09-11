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
    std.debug.assert(mapping.handle == 0x2006 and maps[6] and pins[6]);
    std.debug.assert(bytes != 0 and bytes <= 65536 and offset <= init.queue_allocation_bytes - bytes);
    range_calls += 1;
    if (range_failure != 0) return range_failure;
    if (fault == .bounce) {
        const start = init.queues_offset + offset;
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
    var held: reservation.Lease = .{ .display = &capture, .backing = &b, .epoch = 9, .serial = 7, .plan = prepared.plan, .allocation = b.allocation.handle, .cpu_address = b.allocation.cpu_address, .mapping = b.mapping.handle, .pin = b.pin.handle, .metadata_address = b.report.?.metadata_address };
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
    const port = try lease.transportPort();
    var bytes: [32]u8 = @splat(0x79);
    try port.read(port.context, .status, 0, &bytes);
    try t.expect(std.mem.allEqual(u8, &bytes, 0));
    const calls = range_calls;
    b.mapping.handle += 1;
    try t.expectEqual(@as(u64, 0), port.generation(port.context));
    try t.expectError(error.Stale, port.read(port.context, .status, 0, &bytes));
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
    try lease.retainForDevice();
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
    range_failure = -79;
    try t.expectError(error.Synchronization, port.read(port.context, .status, 0, &bytes));
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
        const port = lease.port();
        var bytes: [80]u8 = @splat(0x5a);
        const calls = range_calls;
        try t.expectError(error.QueueRange, port.read(port.context, .status, init.queue_bytes, bytes[0..1]));
        try t.expectError(error.QueueRange, port.publish(port.context, .command, 0, bytes[0..0]));
        try t.expectError(error.QueueRange, port.read(port.context, .command, std.math.maxInt(usize), &bytes));
        try t.expectError(error.QueueAlias, port.read(port.context, .status, 0, backing.?[0..4]));
        try t.expectError(error.QueueAlias, port.publish(port.context, .command, 0, backing.?[0..4]));
        try t.expectEqual(calls, range_calls);
        const map_handle = storage.pieces[6].mapping.handle;
        storage.pieces[6].mapping.handle += 1;
        try t.expectEqual(@as(u64, 0), port.generation(port.context));
        try t.expectError(error.QueueClosed, port.read(port.context, .status, 0, &bytes));
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
        try t.expectError(error.Synchronization, port.read(port.context, .status, 0, &bytes));
        try t.expectEqual(@as(i32, -123), lease.last_status);
        try t.expect(std.mem.allEqual(u8, &bytes, 0x5a));
        try t.expect(!lease.retainForDevice());
        try t.expectError(error.QueueClosed, port.publish(port.context, .command, 16, bytes[0..4]));
        try t.expect(!storage.close());
        range_failure = 0;
        try t.expect(lease.releaseBeforeSubmission());
        try t.expectEqual(@as(u64, 0), port.generation(port.context));
        try t.expectError(error.QueueClosed, port.read(port.context, .status, 0, &bytes));
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
