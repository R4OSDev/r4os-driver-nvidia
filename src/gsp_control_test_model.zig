// Host-only backend for the existing actual-Device test. It drives the same
// DriverHeap/DMA callbacks; these three pages are never a hardware proof.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const wire = @import("gsp_buffer_wire.zig");
pub const Model = struct {
    const allocation_handle: u64 = 0xe10000001;
    const pin_handle: u64 = 0xe10000002;
    const mapping_handle: u64 = 0xe10000003;
    pub var original: a.DriverApi = undefined;
    var heap_api: a.DriverHeapApi = undefined;
    pub var data: [wire.bytes]u8 align(4096) = undefined;
    pub var active: bool = false;
    pub var pinned: bool = false;
    pub var mapped: bool = false;
    pub var synced: bool = false;
    pub var releases: usize = 0;
    pub var scenario: []const u8 = "";
    pub const pages = [_]u64{ 0x6000000000, 0x7000000000, 0x6000004000 };
    pub fn install(api: *a.DriverApi) void {
        original = api.*;
        api.heap_query = heap;
        api.dma_pin_buffer = pin;
        api.dma_map_pinned = map;
        api.dma_sync_for_device = sync;
        api.dma_unmap = unmap;
        api.dma_unpin_buffer = unpin;
    }
    pub fn reset(name: []const u8) void {
        // Only discards host model effects after the real test asserted their
        // retention. Production has no equivalent discard/quiescence shortcut.
        active = false;
        pinned = false;
        mapped = false;
        synced = false;
        releases = 0;
        scenario = name;
    }
    pub fn is(name: []const u8) bool {
        return std.mem.eql(u8, name, scenario);
    }
    fn heap(out: *a.DriverHeapApi) callconv(.c) i32 {
        const result = original.heap_query.?(&heap_api);
        if (result != 0) return result;
        out.* = heap_api;
        out.allocate = @intFromPtr(&allocate);
        out.release = @intFromPtr(&release);
        return 0;
    }
    fn allocate(bytes: u64, alignment: u32, out: *a.DriverHeapAllocation) callconv(.c) i32 {
        if (bytes != wire.bytes) {
            const f: *const fn (u64, u32, *a.DriverHeapAllocation) callconv(.c) i32 = @ptrFromInt(heap_api.allocate);
            return f(bytes, alignment, out);
        }
        std.debug.assert(!active and alignment == 4096);
        active = true;
        @memset(&data, 0xa5);
        out.* = .{ .handle = allocation_handle, .cpu_address = @intFromPtr(&data), .byte_length = wire.bytes, .alignment = 4096 };
        return if (is("control_allocation")) -1 else 0;
    }
    fn release(handle: u64) callconv(.c) i32 {
        if (handle != allocation_handle) {
            const f: *const fn (u64) callconv(.c) i32 = @ptrFromInt(heap_api.release);
            return f(handle);
        }
        std.debug.assert(active and !mapped and !pinned);
        if (is("control_release")) return -1;
        active = false;
        releases += 1;
        return 0;
    }
    fn pin(cpu: u64, bytes: u32, flags: u32, out: *a.DmaPinnedBuffer) callconv(.c) i32 {
        if (cpu != @intFromPtr(&data)) return original.dma_pin_buffer(cpu, bytes, flags, out);
        std.debug.assert(active and !pinned and bytes == wire.bytes and flags == 0 and std.mem.allEqual(u8, &data, 0));
        pinned = true;
        out.* = .{ .handle = pin_handle, .virt_addr = cpu, .bytes = bytes, .page_count = wire.pages };
        return 0;
    }
    fn map(input: *const a.DmaPinnedBuffer, constraints: *const a.DmaConstraints, direction: u32, out: *a.DmaMapping) callconv(.c) i32 {
        if (input.handle != pin_handle) return original.dma_map_pinned(input, constraints, direction, out);
        std.debug.assert(pinned and !mapped and direction == a.dma_direction_bidirectional and constraints.flags == a.dma_flag_coherent);
        mapped = true;
        out.* = .{ .handle = mapping_handle, .pin_handle = pin_handle, .requested_bytes = wire.bytes, .mapped_bytes = wire.bytes, .direction = direction, .flags = constraints.flags, .segment_count = wire.pages };
        for (pages, 0..) |address, i| out.segments[i] = .{ .phys_addr = address, .bytes = 4096 };
        if (is("control_bounce")) out.flags |= a.dma_mapping_flag_bounced;
        if (is("control_alias")) out.segments[2].phys_addr = pages[0];
        return 0;
    }
    fn sync(input: *const a.DmaMapping) callconv(.c) i32 {
        if (input.handle != mapping_handle) return original.dma_sync_for_device(input);
        std.debug.assert(mapped and !synced and std.mem.allEqual(u8, &data, 0));
        synced = true;
        return if (is("control_sync")) -1 else 0;
    }
    fn unmap(input: *a.DmaMapping) callconv(.c) i32 {
        if (input.handle != mapping_handle) return original.dma_unmap(input);
        std.debug.assert(mapped);
        if (is("control_dma_unmap")) return -1;
        mapped = false;
        return 0;
    }
    fn unpin(input: *a.DmaPinnedBuffer) callconv(.c) i32 {
        if (input.handle != pin_handle) return original.dma_unpin_buffer(input);
        std.debug.assert(!mapped and pinned);
        pinned = false;
        return 0;
    }
};
