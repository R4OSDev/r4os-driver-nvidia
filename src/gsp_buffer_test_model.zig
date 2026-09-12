// Host-only shared BO/heap/queue callbacks for the existing actual Device
// test. Bus pages are modeled; no host result qualifies physical GPU work.
const std = @import("std");
const a = @import("r4os").abi;
const t = std.testing;
pub const Model = struct {
    pub const rounded = [_]u64{ 80 * 1024 * 1024, 4096 };
    pub const fence: a.GfxFence = .{ .slot = 1, .adapter_id = 0x01000000, .timeline = 19, .point = 31, .device_generation = 7, .reset_generation = 11 };
    pub var original: a.DriverApi = undefined;
    pub var refs: [2]bool = @splat(false);
    pub var dma: [2]a.GfxDeviceLease = @splat(.{});
    pub var gpu: [2]a.GfxDeviceLease = @splat(.{});
    pub var releases: usize = 0;
    pub var segments: usize = 0;
    pub var scenario: []const u8 = "";
    const Allocation = struct { bytes: ?[]align(8) u8 = null, handle: u64 = 0 };
    var allocations: [8]Allocation = @splat(.{});
    var serial: u64 = 0;
    pub fn install(table: *a.DriverApi, name: []const u8) void {
        original = table.*;
        table.heap_query = heap;
        table.gfx_memory_query = memory;
        table.gfx_queue_query = queue;
        scenario = name;
        refs = @splat(false); dma = @splat(.{}); gpu = @splat(.{});
        releases = 0; segments = 0;
    }
    pub fn dispose(table: *a.DriverApi) void {
        table.* = original;
        // Used only after retention assertions; production has no forced
        // disposal. The fixture owns these host allocations independently.
        for (&allocations) |*entry| if (entry.bytes) |bytes| {
            t.allocator.free(bytes); entry.* = .{};
        };
    }
    pub fn is(name: []const u8) bool { return std.mem.eql(u8, name, scenario); }
    pub fn page(index: usize, offset: u64) u64 { return 0x6000000000 + index * 0x100000000 + offset * 2; }
    pub fn address(index: usize) u64 { return 0x10000000 + index * 0x10000000; }
    fn reference(index: usize) a.GfxBufferHandle { return .{ .id = @intCast(171 + index), .generation = 331 }; }
    fn selected(input: *const a.GfxBufferHandle) ?usize {
        for (0..2) |i| if (std.meta.eql(input.*, reference(i))) return i;
        return null;
    }
    fn heap(out: *a.DriverHeapApi) callconv(.c) i32 {
        out.* = .{ .allocate = @intFromPtr(&allocate), .release = @intFromPtr(&releaseHeap) }; return 0;
    }
    fn allocate(bytes: u64, alignment: u32, out: *a.DriverHeapAllocation) callconv(.c) i32 {
        std.debug.assert(alignment <= 8 and bytes <= 132000);
        for (&allocations) |*entry| if (entry.bytes == null) {
            const data = t.allocator.alignedAlloc(u8, .@"8", @intCast(bytes)) catch return -1;
            serial += 1;
            entry.* = .{ .bytes = data, .handle = 0xe10000000 + serial };
            out.* = .{ .handle = entry.handle, .cpu_address = @intFromPtr(data.ptr), .byte_length = bytes, .alignment = 8 };
            return 0;
        };
        return -1;
    }
    fn releaseHeap(handle: u64) callconv(.c) i32 {
        for (&allocations) |*entry| if (entry.handle == handle) {
            t.allocator.free(entry.bytes.?); entry.* = .{}; return 0;
        };
        return -1;
    }
    fn queue(out: *a.GfxDriverQueueApi) callconv(.c) i32 {
        out.* = .{ .retain_resource = @intFromPtr(&retain) }; return a.gfx_queue_ok;
    }
    fn retain(input: *const a.GfxFence, which: u32, out: *a.GfxBufferReference) callconv(.c) i32 {
        if (!std.meta.eql(input.*, fence) or which >= 2 or refs[which]) return -1;
        refs[which] = true;
        out.* = .{ .reference = reference(which), .buffer = .{ .id = @intCast(181 + which), .generation = 431 }, .flags = a.gfx_buffer_reference_mapping_only };
        return a.gfx_buffer_result_ok;
    }
    fn memory(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        if (original.gfx_memory_query.?(out) != a.gfx_buffer_result_ok) return -1;
        out.buffer_describe = @intFromPtr(&describe); out.buffer_release = @intFromPtr(&release);
        out.device_acquire = @intFromPtr(&acquire); out.device_segment = @intFromPtr(&segment); out.device_release = @intFromPtr(&releaseDevice);
        return a.gfx_buffer_result_ok;
    }
    fn fallback() a.GfxDriverMemoryApi { var api: a.GfxDriverMemoryApi = .{}; std.debug.assert(original.gfx_memory_query.?(&api) == a.gfx_buffer_result_ok); return api; }
    fn describe(input: *const a.GfxBufferHandle, out: *a.GfxBufferDescriptor) callconv(.c) i32 {
        const i = selected(input) orelse {
            const call: *const fn (*const a.GfxBufferHandle, *a.GfxBufferDescriptor) callconv(.c) i32 = @ptrFromInt(fallback().buffer_describe);
            return call(input, out);
        };
        std.debug.assert(refs[i]); out.* = .{ .byte_length = rounded[i] - 5, .alignment = 4096, .usage = 15 }; return a.gfx_buffer_result_ok;
    }
    fn release(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        const i = selected(input) orelse {
            const call: *const fn (*const a.GfxBufferHandle) callconv(.c) i32 = @ptrFromInt(fallback().buffer_release);
            return call(input);
        };
        std.debug.assert(refs[i] and dma[i].lease.id == 0 and gpu[i].lease.id == 0);
        refs[i] = false; releases += 1; return a.gfx_buffer_result_ok;
    }
    fn acquire(input: *const a.GfxBufferHandle, request: *const a.GfxDeviceRequest, out: *a.GfxDeviceLease) callconv(.c) i32 {
        const i = selected(input).?;
        std.debug.assert(refs[i] and request.byte_offset == 0 and request.byte_length == rounded[i] and request.adapter_id == 0x01000000);
        const virtual = request.access == 3;
        if (virtual) {
            std.debug.assert(dma[i].lease.id != 0 and gpu[i].lease.id == 0 and request.gpu_virtual_address == address(i));
            if (is("mapping_gpu")) return -1;
        } else std.debug.assert(request.access == 4 and dma[i].lease.id == 0 and request.gpu_virtual_address == 0);
        out.* = .{ .lease = .{ .id = @intCast(191 + i * 2 + @intFromBool(virtual)), .generation = 531 }, .byte_length = request.byte_length,
            .gpu_virtual_address = request.gpu_virtual_address, .device_generation = request.device_generation, .adapter_id = request.adapter_id,
            .driver_owner = 7, .access = request.access, .address_space = request.address_space, .dma_mask = request.dma_mask };
        if (virtual) gpu[i] = out.* else dma[i] = out.*;
        return a.gfx_buffer_result_ok;
    }
    fn segment(input: *const a.GfxDeviceLease, offset: u64, out: *a.GfxDmaSegment) callconv(.c) i32 {
        const i = (input.lease.id - 191) / 2;
        std.debug.assert(i < 2 and refs[i] and std.meta.eql(input.*, dma[i]) and offset < rounded[i] and offset & 4095 == 0);
        segments += 1;
        if (is("mapping_segment") and offset >= 40 * 1024 * 1024) return -1;
        out.* = .{ .dma_address = page(i, offset), .byte_length = 4096, .next_offset = offset + 4096 }; return a.gfx_buffer_result_ok;
    }
    fn releaseDevice(input: *const a.GfxDeviceLease, quiesced: u32) callconv(.c) i32 {
        if (input.lease.id < 191) {
            const call: *const fn (*const a.GfxDeviceLease, u32) callconv(.c) i32 = @ptrFromInt(fallback().device_release);
            return call(input, quiesced);
        }
        const i = (input.lease.id - 191) / 2;
        std.debug.assert(i < 2 and refs[i] and quiesced == 1);
        if (input.access == 3) {
            std.debug.assert(std.meta.eql(input.*, gpu[i]));
            if (is("mapping_release")) return -1;
            gpu[i] = .{};
        } else { std.debug.assert(gpu[i].lease.id == 0 and std.meta.eql(input.*, dma[i])); dma[i] = .{}; }
        return a.gfx_buffer_result_ok;
    }
};
