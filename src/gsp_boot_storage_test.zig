const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const t = std.testing;
const storage = @import("gsp_boot_storage.zig");
const wpr = @import("gsp_wpr.zig");
const radix = @import("gsp_radix.zig");
const Fault = enum { none, allocation, pin, map, descriptor, sync, timeout, overlap, unmap, unpin, release, bounce };
var fault: Fault = .none;
var backing: [2]?[]align(4096) u8 = .{ null, null };
var pins: [5]bool = @splat(false);
var maps: [5]bool = @splat(false);
var allocated: usize = 0;
var pin_count: usize = 0;
var sync_count: usize = 0;
var close_count: usize = 0;
var heap_queries: usize = 0;
var closing = false;
var clock: u64 = 100;
var device_pack: [storage.pack_bytes]u8 = @splat(0xa5);

fn now() callconv(.c) u64 {
    return clock;
}
fn resources(out: *a.DriverResourceApi) callconv(.c) i32 {
    out.* = .{ .now_ns = @intFromPtr(&now) };
    return 0;
}
fn heap(out: *a.DriverHeapApi) callconv(.c) i32 {
    std.debug.assert(!closing);
    heap_queries += 1;
    out.* = .{ .allocate = @intFromPtr(&allocate), .release = @intFromPtr(&release) };
    return 0;
}
fn allocate(bytes: u64, alignment: u32, out: *a.DriverHeapAllocation) callconv(.c) i32 {
    const index = allocated;
    std.debug.assert(index < 2 and backing[index] == null and alignment == 4096);
    std.debug.assert(bytes == (if (index == 0) @as(u64, 63676416) else storage.pack_bytes));
    backing[index] = t.allocator.alignedAlloc(u8, comptime std.mem.Alignment.fromByteUnits(4096), @intCast(bytes)) catch return -1;
    @memset(backing[index].?, 0xa5);
    allocated += 1;
    out.* = .{ .handle = 0xe00000001 + index, .cpu_address = @intFromPtr(backing[index].?.ptr), .byte_length = bytes, .alignment = 4096 };
    return if (index == 1 and fault == .allocation) -1 else 0;
}
fn release(handle: u64) callconv(.c) i32 {
    const index = handle - 0xe00000001;
    const active = if (index == 0) pins[0..4] else pins[4..5];
    for (active) |value| std.debug.assert(!value);
    close_count += 1;
    if (index == 1 and fault == .release) return -1;
    t.allocator.free(backing[index].?);
    backing[index] = null;
    return 0;
}
fn pin(address: u64, bytes: u32, flags: u32, out: *a.DmaPinnedBuffer) callconv(.c) i32 {
    const index = pin_count;
    pin_count += 1;
    std.debug.assert(index < 5 and flags == 0 and !pins[index] and !maps[index]);
    const expected = if (index == 4) @intFromPtr(backing[1].?.ptr) else @intFromPtr(backing[0].?.ptr) + index * a.dma_mapping_max_bytes;
    std.debug.assert(address == expected and bytes & 4095 == 0);
    pins[index] = true;
    out.* = .{ .handle = 0x1000 + index, .virt_addr = address, .bytes = bytes, .page_count = bytes / 4096 };
    return if (index == 4 and fault == .pin) -1 else 0;
}
fn map(info: *const a.DmaPinnedBuffer, constraints: *const a.DmaConstraints, direction: u32, out: *a.DmaMapping) callconv(.c) i32 {
    const index = info.handle - 0x1000;
    std.debug.assert(pins[index] and !maps[index] and direction == a.dma_direction_to_device);
    std.debug.assert(constraints.dma_mask == radix.dma_mask and constraints.alignment == 4096);
    std.debug.assert(constraints.max_segments == (if (index == 4) @as(u32, 1) else 64));
    const data: [*]const u8 = @ptrFromInt(info.virt_addr);
    if (index == 4) {
        std.debug.assert(std.mem.allEqual(u8, data[0..storage.signature_offset], 0x42));
        std.debug.assert(std.mem.allEqual(u8, data[storage.signature_offset..storage.metadata_offset], 0x53));
        std.debug.assert(std.mem.allEqual(u8, data[storage.metadata_offset..storage.pack_bytes], 0));
        @memcpy(&device_pack, data[0..storage.pack_bytes]);
    } else std.debug.assert(std.mem.allEqual(u8, data[0..info.bytes], 0));
    maps[index] = true;
    out.* = .{ .handle = 0x2000 + index, .pin_handle = info.handle, .requested_bytes = info.bytes, .mapped_bytes = info.bytes, .direction = direction, .flags = constraints.flags, .segment_count = 1 };
    out.segments[0] = .{ .phys_addr = if (index == 4) 0x200000000 else 0x100000000 + index * a.dma_mapping_max_bytes, .bytes = info.bytes };
    if (index == 4) switch (fault) {
        .map => return -1, // Partial published handle must remain owned.
        .descriptor => out.segments[0].reserved = 1,
        .timeout => clock = 1100,
        .overlap => out.segments[0].phys_addr = 0x100000000 - storage.metadata_offset, // Only metadata overlaps GSP.
        .bounce => out.flags |= a.dma_mapping_flag_bounced,
        else => {},
    };
    return 0;
}
fn word(data: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, data[offset..][0..8], .little);
}
fn sync(mapping: *const a.DmaMapping) callconv(.c) i32 {
    const index = mapping.handle - 0x2000;
    std.debug.assert(index == sync_count and maps[index] and pins[index]);
    sync_count += 1;
    if (index == 4) {
        const meta = backing[1].?[storage.metadata_offset..];
        std.debug.assert(word(meta, 0) == wpr.magic and word(meta, 16) == 0x100000000);
        std.debug.assert(word(meta, 32) == 0x200000000 and word(meta, 72) == 0x200006000);
        std.debug.assert(std.mem.allEqual(u8, meta[200..], 0));
        std.debug.assert(word(device_pack[storage.metadata_offset..], 0) == 0);
        if (fault == .sync) return -1;
        @memcpy(&device_pack, backing[1].?);
    }
    return 0;
}
fn unmap(mapping: *a.DmaMapping) callconv(.c) i32 {
    const index = mapping.handle - 0x2000;
    std.debug.assert(maps[index] and pins[index]);
    close_count += 1;
    mapping.* = .{};
    if (index == 4 and fault == .unmap) return -1;
    maps[index] = false;
    return 0;
}
fn unpin(info: *a.DmaPinnedBuffer) callconv(.c) i32 {
    const index = info.handle - 0x1000;
    std.debug.assert(pins[index] and !maps[index]);
    close_count += 1;
    info.* = .{};
    if (index == 4 and fault == .unpin) return -1;
    pins[index] = false;
    return 0;
}

test "firmware CPU storage boot pack owns complete GSP lifetime and resynchronizes metadata before publication" {
    var api: a.DriverApi = undefined;
    api.magic = a.driver_magic;
    api.version = 34;
    api.size = @sizeOf(a.DriverApi);
    api.heap_query = heap;
    api.resource_query = resources;
    api.dma_pin_buffer = pin;
    api.dma_map_pinned = map;
    api.dma_sync_for_device = sync;
    api.dma_unmap = unmap;
    api.dma_unpin_buffer = unpin;
    const ctx = r4os.r4dev.DriverContext.init(&api);
    const image = try t.allocator.alloc(u8, wpr.image_bytes);
    defer t.allocator.free(image);
    @memset(image, 0x79);
    const boot_image: [24576]u8 = @splat(0x42);
    const signature: [4096]u8 = @splat(0x53);
    const fields = [_]u32{ 5, 20480, 2176, 22656, 16, 0, 0, 0, 0, 2048, 2048, 4096, 6144, 10496, 1, 0, 0, 0, 0, 24576, 0 };
    var descriptor: [84]u8 = undefined;
    for (fields, 0..) |value, index| std.mem.writeInt(u32, descriptor[index * 4 ..][0..4], value, .little);
    const sources = storage.Sources{
        .chip_id = 0x176,
        .raw = .{ .values = .{ 0x80420100, 0x47f7, 0x10, 0x80, 2, 0, 0x10, 1, 12288, 0x1ffffe00, 0, 0, 0x10e09 }, .present = 0x1fff },
        .image = image,
        .boot_image = &boot_image,
        .descriptor = &descriptor,
        .signature = &signature,
    };
    for (std.enums.values(Fault)) |case| {
        fault = case;
        clock = 100;
        closing = false;
        allocated = 0;
        pin_count = 0;
        sync_count = 0;
        close_count = 0;
        heap_queries = 0;
        var owned: storage.Storage = .{};
        const failure: ?anyerror = switch (case) {
            .allocation => error.Memory,
            .pin => error.Pin,
            .map => error.Map,
            .descriptor => error.Descriptor,
            .sync => error.Synchronization,
            .timeout => error.Timeout,
            .overlap => error.Overlap,
            else => null,
        };
        if (failure) |expected| {
            try t.expectError(expected, owned.stageAdmitted(&ctx, &sources, 1000));
            try t.expect(owned.report == null);
        } else {
            const report = try owned.stageAdmitted(&ctx, &sources, 1000);
            try t.expectEqual(@as(u64, 0x200007000), report.metadata_address);
            try t.expectEqual(@as(usize, 5), sync_count);
            try t.expectEqual(case == .bounce, report.pack_bounced);
            try t.expectEqualSlices(u8, backing[1].?, &device_pack);
            try t.expect(wpr.matchesPlan(device_pack[storage.metadata_offset..][0..wpr.bytes], &owned.vram_plan.?));
            if (case == .none) {
                owned.vram_owner = 0x790010;
                try t.expect(!owned.close() and owned.report != null and owned.vram_plan != null);
                owned.vram_owner = 0;
            }
        }
        try t.expectError(error.Busy, owned.stageAdmitted(&ctx, &sources, 1000));
        closing = true;
        if (case == .unmap or case == .unpin or case == .release) {
            try t.expect(!owned.close());
            try t.expect(owned.report == null and owned.image.report != null and backing[0] != null and backing[1] != null);
        }
        fault = .none;
        try t.expect(owned.close());
        const count = close_count;
        try t.expect(owned.close());
        try t.expectEqual(count, close_count);
        try t.expectEqual(@as(usize, 2), heap_queries);
        for (backing) |slot| try t.expect(slot == null);
        for (pins) |active| try t.expect(!active);
        for (maps) |active| try t.expect(!active);
    }
    try t.expect(std.mem.allEqual(u8, image, 0x79));
    try t.expect(std.mem.allEqual(u8, &boot_image, 0x42));
    try t.expect(std.mem.allEqual(u8, &signature, 0x53));
}
