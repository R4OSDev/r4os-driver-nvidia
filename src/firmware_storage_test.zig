const std = @import("std");
const r4os = @import("r4os");
const firmware = @import("firmware.zig");
const resources = @import("firmware_resources.zig");
const Storage = @import("firmware_storage.zig").Storage;
const a = r4os.abi;
const t = std.testing;
comptime {
    _ = @import("gsp_dma_test.zig");
    _ = @import("gsp_boot_storage_test.zig");
    _ = @import("boot_resources.zig");
}
const Fault = enum { none, create, map, unmap, release, collect, read, short };
var fault: Fault = .none;
var backing: ?[]u8 = null;
var reference = false;
var mapped = false;
var closing = false;
var memory_queries: usize = 0;
var unmaps: usize = 0;
var releases: usize = 0;
var clock: u64 = 100;

fn apiTable() a.DriverApi {
    var table: a.DriverApi = undefined;
    table.magic = a.driver_magic;
    table.version = 29;
    table.size = @sizeOf(a.DriverApi);
    table.resource_query = resourceQuery;
    table.gfx_memory_query = memoryQuery;
    return table;
}
fn resourceQuery(out: *a.DriverResourceApi) callconv(.c) i32 {
    out.* = .{ .stat = @intFromPtr(&stat), .read_at = @intFromPtr(&read), .now_ns = @intFromPtr(&now) };
    return 0;
}
fn now() callconv(.c) u64 {
    return clock;
}
fn stat(name: [*]const u8, length: u32, out: *a.DriverResourceInfo) callconv(.c) i32 {
    const lock = std.mem.eql(u8, name[0..length], "NVFW-LOCK.json");
    if (!lock) std.debug.assert(std.mem.eql(u8, name[0..length], firmware.specification(.ga10x).resource));
    out.* = .{ .handle = if (lock) 1 else 2, .byte_length = if (lock) resources.lock_bytes.len else firmware.specification(.ga10x).bytes, .module_generation = 3 };
    return 0;
}
fn read(id: u64, offset: u64, output: [*]u8, length: u32, _: u64) callconv(.c) i32 {
    if (id == 1) {
        std.debug.assert(offset == 0 and length == resources.lock_bytes.len);
        @memcpy(output[0..length], resources.lock_bytes);
    } else {
        std.debug.assert(id == 2 and mapped and length <= 65536);
        if (fault == .read) return a.driver_resource_error_io;
        @memset(output[0..length], 0);
        if (fault == .short) return @as(i32, @intCast(length)) - 1;
    }
    return @intCast(length);
}
fn memoryQuery(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
    memory_queries += 1;
    if (closing) return a.gfx_buffer_error_closed;
    out.* = .{ .buffer_create = @intFromPtr(&create), .buffer_map = @intFromPtr(&map), .buffer_unmap = @intFromPtr(&unmap), .buffer_release = @intFromPtr(&release), .collect = @intFromPtr(&collect) };
    return a.gfx_buffer_result_ok;
}
fn create(input: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) callconv(.c) i32 {
    std.debug.assert(backing == null and !reference and input.byte_length == firmware.specification(.ga10x).bytes);
    backing = t.allocator.alloc(u8, if (fault == .create) 65536 else @intCast(input.byte_length)) catch return a.gfx_buffer_error_budget;
    if (fault == .create) return a.gfx_buffer_error_budget;
    reference = true;
    out.* = .{ .buffer = .{ .id = 1, .generation = 3 }, .reference = .{ .id = 2, .generation = 4 } };
    return a.gfx_buffer_result_ok;
}
fn map(input: *const a.GfxBufferHandle, access: u32, offset: u64, bytes: u64, out: *a.GfxBufferMap) callconv(.c) i32 {
    std.debug.assert(reference and input.id == 2 and access == a.gfx_buffer_map_write and offset == 0 and bytes == backing.?.len);
    if (fault == .map) return a.gfx_buffer_error_busy;
    mapped = true;
    out.* = .{ .lease = .{ .id = 3, .generation = 5 }, .cpu_address = @intFromPtr(backing.?.ptr), .byte_length = bytes, .cache_policy = a.gfx_buffer_cache_write_back };
    return a.gfx_buffer_result_ok;
}
fn unmap(input: *const a.GfxBufferHandle) callconv(.c) i32 {
    std.debug.assert(mapped and input.id == 3);
    unmaps += 1;
    if (fault == .unmap) return a.gfx_buffer_error_busy;
    mapped = false;
    return a.gfx_buffer_result_ok;
}
fn release(input: *const a.GfxBufferHandle) callconv(.c) i32 {
    std.debug.assert(!mapped and reference and input.id == 2);
    releases += 1;
    if (fault == .release) return a.gfx_buffer_error_busy;
    reference = false;
    return a.gfx_buffer_result_ok;
}
fn collect() callconv(.c) i32 {
    std.debug.assert(!mapped and !reference);
    if (fault == .collect or fault == .create) return a.gfx_buffer_error_busy;
    if (backing) |bytes| t.allocator.free(bytes);
    backing = null;
    return a.gfx_buffer_result_ok;
}

test "firmware CPU storage retains private and public failures, uses cached shutdown API and exposes no partial view" {
    var table = apiTable();
    const ctx = r4os.r4dev.DriverContext.init(&table);
    for ([_]Fault{ .create, .map, .unmap, .release, .collect, .read, .short, .none }) |failure| {
        fault = if (failure == .create or failure == .map) failure else .none;
        closing = false;
        memory_queries = 0;
        unmaps = 0;
        releases = 0;
        clock = 100;
        var storage: Storage = .{};
        if (failure == .create) {
            try t.expectError(error.Memory, storage.begin(&ctx, .ga10x, 1000));
        } else if (failure == .map) {
            try t.expectError(error.Mapping, storage.begin(&ctx, .ga10x, 1000));
        } else {
            try storage.begin(&ctx, .ga10x, 1000);
            try t.expectEqual(firmware.Load.State.reading, try storage.step());
            try t.expect(storage.ready() == null);
            fault = failure;
            if (failure == .read) try t.expectError(error.ReadFailed, storage.step());
            if (failure == .short) try t.expectError(error.ShortRead, storage.step());
            if (failure == .none) {
                clock = 1100;
                try t.expectError(error.Timeout, storage.step());
            }
        }
        try t.expect(storage.ready() == null);
        closing = true; // Real kernel refuses fresh memory queries at shutdown.
        if (failure == .create or failure == .unmap or failure == .release or failure == .collect) {
            try t.expect(!storage.close());
            try t.expect(storage.memory != null and backing != null);
            try t.expectError(error.BadState, storage.begin(&ctx, .ga10x, 1000));
        }
        fault = .none;
        try t.expect(storage.close());
        const unmaps_at_close = unmaps;
        const releases_at_close = releases;
        try t.expect(storage.close());
        try t.expectEqual(unmaps_at_close, unmaps);
        try t.expectEqual(releases_at_close, releases);
        try t.expectEqual(@as(usize, 1), memory_queries);
        try t.expect(backing == null and !reference and !mapped);
    }
}
