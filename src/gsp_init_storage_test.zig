const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const t = std.testing;
const init = @import("gsp_init.zig");
const radix = @import("gsp_radix.zig");
const Storage = @import("gsp_init_storage.zig").Storage;
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

test "firmware CPU storage GSP init owns bidirectional logs and queues with exact partial cleanup" {
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
