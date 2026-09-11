const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const t = std.testing;
const Pair = @import("booter_storage.zig").Pair;
const firmware = @import("firmware.zig");
const resources = @import("firmware_resources.zig");
const fixtures = @import("booter_fixture").files;
const Fault = enum { none, generation, short, hash, allocation, allocation_descriptor, pin, map, timeout, regression, unmap, unpin, release };
var fault: Fault = .none;
var memory: [2]?[]align(256) u8 = .{ null, null };
var pinned: [2]bool = @splat(false);
var mapped: [2]bool = @splat(false);
var clock: u64 = 100;
var closing = false;
var allocation_count: usize = 0;
var close_calls: usize = 0;

fn resourceQuery(out: *a.DriverResourceApi) callconv(.c) i32 {
    std.debug.assert(!closing);
    out.* = .{ .stat = @intFromPtr(&stat), .read_at = @intFromPtr(&read), .now_ns = @intFromPtr(&now) };
    return 0;
}
fn now() callconv(.c) u64 {
    return clock;
}
fn stat(name: [*]const u8, length: u32, out: *a.DriverResourceInfo) callconv(.c) i32 {
    if (std.mem.eql(u8, name[0..length], "NVFW-LOCK.json")) {
        out.* = .{ .handle = 100, .byte_length = resources.lock_bytes.len, .module_generation = 7 };
        return 0;
    }
    for (fixtures, 0..) |file, index| {
        if (!std.mem.eql(u8, file.name, name[0..length])) continue;
        out.* = .{ .handle = index + 1, .byte_length = file.bytes.len, .module_generation = if (fault == .generation and index == 9) 8 else 7 };
        return 0;
    }
    return a.driver_resource_error_not_found;
}
fn read(handle: u64, offset: u64, output: [*]u8, length: u32, deadline: u64) callconv(.c) i32 {
    const bytes = if (handle == 100) resources.lock_bytes else fixtures[handle - 1].bytes;
    std.debug.assert(offset == 0 and bytes.len == length and deadline == 1100);
    @memcpy(output[0..length], bytes);
    if (handle == 10) {
        if (fault == .short) return @as(i32, @intCast(length)) - 1;
        if (fault == .hash) output[0] ^= 1;
    }
    return @intCast(length);
}
fn heapQuery(out: *a.DriverHeapApi) callconv(.c) i32 {
    std.debug.assert(!closing);
    out.* = .{ .allocate = @intFromPtr(&allocate), .release = @intFromPtr(&release) };
    return 0;
}
fn allocate(bytes: u64, alignment: u32, out: *a.DriverHeapAllocation) callconv(.c) i32 {
    const index = allocation_count;
    std.debug.assert(index < 2 and memory[index] == null and bytes == firmware.lock.booters[index].image.bytes and alignment == 256);
    memory[index] = t.allocator.alignedAlloc(u8, comptime std.mem.Alignment.fromByteUnits(256), @intCast(bytes)) catch return -1;
    allocation_count += 1;
    out.* = .{ .handle = 1000 + index, .cpu_address = @intFromPtr(memory[index].?.ptr), .byte_length = bytes, .alignment = 256 };
    if (index == 1 and fault == .allocation_descriptor) out.version = 2;
    return if (index == 1 and fault == .allocation) -1 else 0;
}
fn release(handle: u64) callconv(.c) i32 {
    const index = handle - 1000;
    std.debug.assert(!mapped[index] and !pinned[index] and memory[index] != null);
    close_calls += 1;
    if (fault == .release and index == 1) return -1;
    t.allocator.free(memory[index].?);
    memory[index] = null;
    return 0;
}
fn pin(cpu: u64, bytes: u32, flags: u32, out: *a.DmaPinnedBuffer) callconv(.c) i32 {
    const index = allocation_count - 1;
    std.debug.assert(!pinned[index] and !mapped[index] and cpu == @intFromPtr(memory[index].?.ptr) and bytes == memory[index].?.len and flags == 0);
    pinned[index] = true;
    out.* = .{ .handle = 2000 + index, .virt_addr = cpu, .bytes = bytes, .page_count = @intCast(((cpu & 4095) + bytes + 4095) / 4096) };
    return if (fault == .pin and index == 1) -1 else 0;
}
fn map(input: *const a.DmaPinnedBuffer, constraints: *const a.DmaConstraints, direction: u32, out: *a.DmaMapping) callconv(.c) i32 {
    const index = input.handle - 2000;
    std.debug.assert(pinned[index] and !mapped[index] and direction == a.dma_direction_to_device);
    std.debug.assert(constraints.dma_mask == 0x1ffffffffffff and constraints.max_segments == 1 and constraints.alignment == 256 and constraints.max_segment_bytes == input.bytes);
    // Validate the actual CPU bytes at the DMA boundary: fuse version1 uses
    // signature0, all remaining original image bytes must stay identical.
    const body = memory[index].?;
    const original = fixtures[index * 7].bytes;
    const offset = std.mem.readInt(u32, fixtures[index * 7 + 3].bytes[0..4], .little);
    std.debug.assert(std.mem.eql(u8, body[0..offset], original[0..offset]));
    std.debug.assert(std.mem.eql(u8, body[offset..][0..384], fixtures[index * 7 + 2].bytes[0..384]));
    std.debug.assert(std.mem.eql(u8, body[offset + 384 ..], original[offset + 384 ..]));
    mapped[index] = true;
    out.* = .{ .handle = 3000 + index, .pin_handle = input.handle, .requested_bytes = input.bytes, .mapped_bytes = input.bytes, .direction = direction, .flags = constraints.flags | a.dma_mapping_flag_bounced, .segment_count = 1 };
    out.segments[0] = .{ .phys_addr = 0x100000000 + index * 0x100000, .bytes = input.bytes };
    if (index == 1) {
        if (fault == .timeout) clock = 1100;
        if (fault == .regression) clock = 1;
    }
    return if (fault == .map and index == 1) -1 else 0;
}
fn unmap(input: *a.DmaMapping) callconv(.c) i32 {
    const index = input.handle - 3000;
    std.debug.assert(mapped[index] and pinned[index]);
    close_calls += 1;
    if (index == 1 and fault == .unmap) {
        input.* = .{};
        return -1;
    }
    mapped[index] = false;
    return 0;
}
fn unpin(input: *a.DmaPinnedBuffer) callconv(.c) i32 {
    const index = input.handle - 2000;
    std.debug.assert(!mapped[index] and pinned[index]);
    close_calls += 1;
    if (index == 1 and fault == .unpin) {
        input.* = .{};
        return -1;
    }
    pinned[index] = false;
    return 0;
}

test "firmware CPU storage Booter pair validates production parts and retains every partial DMA owner" {
    var table: a.DriverApi = undefined;
    table.magic = a.driver_magic;
    table.version = 34;
    table.size = @sizeOf(a.DriverApi);
    table.resource_query = resourceQuery;
    table.heap_query = heapQuery;
    table.dma_pin_buffer = pin;
    table.dma_map_pinned = map;
    table.dma_unmap = unmap;
    table.dma_unpin_buffer = unpin;
    const ctx = r4os.r4dev.DriverContext.init(&table);
    const fuses = @import("booter.zig").Fuses{ .debug_disable_raw = 1, .ucode_version_raw = 1, .ucode_id = 3 };
    inline for (std.meta.fields(Fault)) |field| {
        fault = @enumFromInt(field.value);
        clock = 100;
        closing = false;
        allocation_count = 0;
        close_calls = 0;
        const pair = try t.allocator.create(Pair);
        defer t.allocator.destroy(pair);
        pair.* = .{};
        const result = pair.stage(&ctx, 0x176, fuses, 7, 1000);
        switch (fault) {
            .generation => try t.expectError(error.Generation, result),
            .short => try t.expectError(error.ShortRead, result),
            .hash => try t.expectError(error.Hash, result),
            .allocation, .allocation_descriptor => try t.expectError(error.Memory, result),
            .pin => try t.expectError(error.Pin, result),
            .map => try t.expectError(error.Map, result),
            .timeout => try t.expectError(error.Timeout, result),
            .regression => try t.expectError(error.ClockRegression, result),
            else => {
                try result;
                try t.expect(pair.complete and pair.reads == 15 and pair.generation == 7);
                try t.expectError(error.Busy, pair.stage(&ctx, 0x176, fuses, 7, 1000));
                pair.images[1].device.execution_owner = 79;
                try t.expect(!pair.close() and !pair.images[1].close());
                try t.expect(pair.complete and pair.images[0].prepared != null and pair.images[1].prepared != null and close_calls == 0);
                pair.images[1].device.execution_owner = 0;
            },
        }
        closing = true; // Teardown must use cached APIs, even after failure.
        if (fault == .unmap or fault == .unpin or fault == .release) {
            try t.expect(!pair.close());
            try t.expect(memory[0] != null and memory[1] != null and mapped[0] and pinned[0]);
            if (fault == .unmap) try t.expectEqual(@as(u64, 3001), pair.images[1].device.mapping.handle);
            if (fault == .unpin) try t.expectEqual(@as(u64, 2001), pair.images[1].device.pin.handle);
            try t.expectError(error.Busy, pair.stage(&ctx, 0x176, fuses, 7, 1000));
        }
        fault = .none;
        try t.expect(pair.close());
        try t.expect(pair.close());
        try t.expect(memory[0] == null and memory[1] == null and !mapped[0] and !mapped[1] and !pinned[0] and !pinned[1]);
    }
}
