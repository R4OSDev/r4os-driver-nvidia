const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const t = std.testing;
const Storage = @import("gsp_dma.zig").Storage;
const radix = @import("gsp_radix.zig");
const Fault = enum { none, allocation, pin_second, map_second, pin_header, map_header, overlap, sync_second, timeout, regression, unmap, unpin, release, bounce };
var fault: Fault = .none;
var backing: ?[]align(4096) u8 = null;
var pins: [4]bool = @splat(false);
var maps: [4]bool = @splat(false);
var pin_calls: usize = 0;
var map_calls: usize = 0;
var sync_calls: usize = 0;
var close_calls: usize = 0;
var queries: usize = 0;
var closing = false;
var clock: u64 = 100;
var image_bytes: usize = 0;

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
    std.debug.assert(backing == null and alignment == 4096);
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
fn any(values: []const bool) bool {
    for (values) |value| if (value) return true;
    return false;
}
fn pin(address: u64, bytes: u32, flags: u32, out: *a.DmaPinnedBuffer) callconv(.c) i32 {
    const index = pin_calls;
    pin_calls += 1;
    std.debug.assert(index < 4 and !pins[index] and !maps[index] and flags == 0);
    std.debug.assert(address == @intFromPtr(backing.?.ptr) + index * a.dma_mapping_max_bytes and bytes <= a.dma_mapping_max_bytes and bytes & 4095 == 0);
    if (fault == .pin_second and index == 1) return -1;
    pins[index] = true;
    out.* = .{ .handle = 0x1000 + index, .virt_addr = address, .bytes = bytes, .page_count = bytes / 4096 };
    if (fault == .pin_header) out.flags = 1;
    return 0;
}
fn map(pin_info: *const a.DmaPinnedBuffer, constraints: *const a.DmaConstraints, direction: u32, out: *a.DmaMapping) callconv(.c) i32 {
    const index = pin_info.handle - 0x1000;
    map_calls += 1;
    std.debug.assert(pins[index] and !maps[index] and direction == a.dma_direction_to_device);
    std.debug.assert(constraints.max_segments == 64 and constraints.alignment == 4096 and constraints.dma_mask == radix.dma_mask);
    const source: [*]const u8 = @ptrFromInt(pin_info.virt_addr);
    // A real bounced map synchronizes immediately, before PTE addresses exist.
    std.debug.assert(std.mem.allEqual(u8, source[0..pin_info.bytes], 0));
    if (fault == .map_second and index == 1) return -1;
    maps[index] = true;
    out.* = .{ .handle = 0x2000 + index, .pin_handle = pin_info.handle, .requested_bytes = pin_info.bytes, .mapped_bytes = pin_info.bytes, .direction = direction, .flags = constraints.flags, .segment_count = 2 };
    const first = (pin_info.bytes / 2) & ~@as(u32, 4095);
    out.segments[0] = .{ .phys_addr = 0x100000000 + index * 0x10000000, .bytes = first };
    out.segments[1] = .{ .phys_addr = 0x108000000 + index * 0x10000000, .bytes = pin_info.bytes - first };
    if (fault == .map_header) out.segment_count = 65;
    if (fault == .overlap) out.segments[1].phys_addr = out.segments[0].phys_addr;
    if (fault == .bounce and index == 0) out.flags |= a.dma_mapping_flag_bounced;
    if (index == 1 and fault == .timeout) clock = 1100;
    if (index == 1 and fault == .regression) clock = 1;
    return 0;
}
fn sync(mapping: *const a.DmaMapping) callconv(.c) i32 {
    const index = mapping.handle - 0x2000;
    std.debug.assert(maps[index] and pins[index] and index == sync_calls);
    const need = radix.requirements(image_bytes) catch unreachable;
    if (sync_calls == 0) {
        std.debug.assert(std.mem.readInt(u64, backing.?[0..8], .little) == 0x100001000);
        std.debug.assert(std.mem.allEqual(u8, backing.?[need.table_bytes..][0..image_bytes], 0x79));
        std.debug.assert(std.mem.allEqual(u8, backing.?[need.table_bytes + image_bytes ..], 0));
    }
    sync_calls += 1;
    return if (fault == .sync_second and index == 1) -1 else 0;
}
fn unmap(mapping: *a.DmaMapping) callconv(.c) i32 {
    const index = mapping.handle - 0x2000;
    std.debug.assert(maps[index] and pins[index]);
    close_calls += 1;
    if (fault == .unmap) {
        mapping.* = .{}; // A failed in/out callback must not erase ownership.
        return -1;
    }
    maps[index] = false;
    mapping.* = .{};
    return 0;
}
fn unpin(pin_info: *a.DmaPinnedBuffer) callconv(.c) i32 {
    const index = pin_info.handle - 0x1000;
    std.debug.assert(pins[index] and !any(&maps));
    close_calls += 1;
    if (fault == .unpin) {
        pin_info.* = .{};
        return -1;
    }
    pins[index] = false;
    pin_info.* = .{};
    return 0;
}

test "firmware CPU storage GSP DMA keeps partial maps and synchronizes all radix backing before publication" {
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
    for (std.enums.values(Fault)) |case| {
        fault = case;
        clock = 100;
        closing = false;
        pin_calls = 0;
        map_calls = 0;
        sync_calls = 0;
        close_calls = 0;
        queries = 0;
        image_bytes = if (case == .none) 63541248 else 16 * 1024 * 1024 + 17;
        const image = try t.allocator.alloc(u8, image_bytes);
        defer t.allocator.free(image);
        @memset(image, 0x79);
        var storage: Storage = .{};
        const failure: ?anyerror = switch (case) {
            .allocation => error.Memory,
            .pin_second => error.Pin,
            .map_second => error.Map,
            .pin_header, .map_header => error.Descriptor,
            .overlap => error.Overlap,
            .sync_second => error.Synchronization,
            .timeout => error.Timeout,
            .regression => error.ClockRegression,
            else => null,
        };
        if (failure) |expected| {
            try t.expectError(expected, storage.stage(&ctx, image, 1000));
            try t.expect(storage.report == null);
        } else {
            const result = try storage.stage(&ctx, image, 1000);
            try t.expectEqual(@as(u64, 0x100000000), result.root_address);
            try t.expectEqual(if (case == .none) @as(usize, 4) else 2, result.mappings);
            try t.expectEqual(result.mappings * 2, result.segments);
            try t.expectEqual(result.mappings, sync_calls);
            try t.expectEqual(if (case == .bounce) @as(usize, 1) else 0, result.bounced);
        }
        try t.expectError(error.Busy, storage.stage(&ctx, image, 1000));
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
        try t.expect(std.mem.allEqual(u8, image, 0x79));
    }
}
