// Per-channel host BOs for the existing actual Device path. Earlier common
// VRAM and graph-control models remain active through their saved tables.
const std = @import("std");
const a = @import("r4os").abi;
const bytes = @import("gsp_buffer_wire.zig").bytes;
pub const Model = struct {
    const Slot = struct { data: [bytes]u8 align(4096) = undefined, active: bool = false, cpu: bool = false, synced: bool = false,
        descriptor: a.GfxBufferDescriptor = .{}, dma: a.GfxDeviceLease = .{}, gpu: a.GfxDeviceLease = .{} };
    pub var slots: [2]Slot = @splat(.{});
    var original: a.GfxDriverMemoryApi = .{};
    var scenario: []const u8 = "";
    pub var released: usize = 0;
    pub fn install(table: *a.DriverApi, name: []const u8) void {
        std.debug.assert(table.gfx_memory_query.?(&original) == a.gfx_buffer_result_ok);
        table.gfx_memory_query = query; slots = @splat(.{}); scenario = name; released = 0;
    }
    fn query(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = original;
        out.buffer_create = @intFromPtr(&create); out.buffer_describe = @intFromPtr(&describe); out.buffer_map = @intFromPtr(&map);
        out.buffer_unmap = @intFromPtr(&unmap); out.buffer_release = @intFromPtr(&release);
        out.device_acquire = @intFromPtr(&acquire); out.device_release = @intFromPtr(&releaseDevice); out.device_segment = @intFromPtr(&segment);
        return a.gfx_buffer_result_ok;
    }
    fn ref(index: usize) a.GfxBufferHandle { return .{ .id = @intCast(901 + index), .generation = 801 }; }
    fn cpuRef(index: usize) a.GfxBufferHandle { return .{ .id = @intCast(921 + index), .generation = 802 }; }
    fn select(input: a.GfxBufferHandle) ?usize { for (0..slots.len) |i| if (std.meta.eql(input, ref(i))) return i; return null; }
    pub fn address(index: usize) u64 { return 0x50000000 + index * 0x100000; }
    fn create(d: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) callconv(.c) i32 {
        std.debug.assert(d.byte_length == bytes and d.alignment == 4096 and d.usage & 3 == 3);
        for (&slots, 0..) |*slot, i| if (!slot.active) {
            slot.* = .{ .active = true, .descriptor = d.* }; @memset(&slot.data, 0xa5);
            out.* = .{ .reference = ref(i), .buffer = .{ .id = @intCast(911 + i), .generation = 803 } }; return a.gfx_buffer_result_ok;
        };
        return a.gfx_buffer_error_capacity;
    }
    fn describe(input: *const a.GfxBufferHandle, out: *a.GfxBufferDescriptor) callconv(.c) i32 {
        const i = select(input.*) orelse { const call: *const fn (*const a.GfxBufferHandle, *a.GfxBufferDescriptor) callconv(.c) i32 = @ptrFromInt(original.buffer_describe); return call(input, out); };
        std.debug.assert(slots[i].active); out.* = slots[i].descriptor; return a.gfx_buffer_result_ok;
    }
    fn map(input: *const a.GfxBufferHandle, access: u32, offset: u64, length: u64, out: *a.GfxBufferMap) callconv(.c) i32 {
        const i = select(input.*).?; const slot = &slots[i];
        std.debug.assert(slot.active and !slot.cpu and slot.dma.lease.id == 0 and access == 1 and offset == 0 and length == bytes);
        slot.cpu = true; out.* = .{ .lease = cpuRef(i), .cpu_address = @intFromPtr(&slot.data), .byte_length = length, .cache_policy = a.gfx_buffer_cache_write_back };
        return a.gfx_buffer_result_ok;
    }
    fn unmap(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        for (&slots, 0..) |*slot, i| if (std.meta.eql(input.*, cpuRef(i))) {
            std.debug.assert(slot.active and slot.cpu); slot.cpu = false; slot.synced = std.mem.allEqual(u8, &slot.data, 0); return a.gfx_buffer_result_ok;
        };
        unreachable;
    }
    fn acquire(input: *const a.GfxBufferHandle, request: *const a.GfxDeviceRequest, out: *a.GfxDeviceLease) callconv(.c) i32 {
        const i = select(input.*) orelse { const call: *const fn (*const a.GfxBufferHandle, *const a.GfxDeviceRequest, *a.GfxDeviceLease) callconv(.c) i32 = @ptrFromInt(original.device_acquire); return call(input, request, out); };
        const slot = &slots[i]; const virtual = request.access == 3;
        std.debug.assert(slot.active and !slot.cpu and slot.synced and request.byte_length == bytes and request.byte_offset == 0);
        if (virtual) std.debug.assert(slot.dma.lease.id != 0 and slot.gpu.lease.id == 0 and request.gpu_virtual_address == address(i) and request.address_space == 1)
        else std.debug.assert(slot.dma.lease.id == 0 and request.access == 4 and request.address_space == 0);
        out.* = .{ .lease = .{ .id = @intCast(941 + i * 2 + @intFromBool(virtual)), .generation = 804 }, .byte_length = request.byte_length,
            .gpu_virtual_address = request.gpu_virtual_address, .device_generation = request.device_generation, .adapter_id = request.adapter_id,
            .driver_owner = 7, .access = request.access, .address_space = request.address_space, .dma_mask = request.dma_mask };
        if (virtual) slot.gpu = out.* else slot.dma = out.*;
        return a.gfx_buffer_result_ok;
    }
    fn segment(input: *const a.GfxDeviceLease, offset: u64, out: *a.GfxDmaSegment) callconv(.c) i32 {
        const i = (input.lease.id - 941) / 2; const slot = &slots[i];
        std.debug.assert(slot.active and std.meta.eql(input.*, slot.dma) and offset & 4095 == 0 and offset < bytes);
        out.* = .{ .dma_address = 0x8000000000 + @as(u64, i) * 0x100000 + offset * 2, .byte_length = 4096, .next_offset = offset + 4096 }; return a.gfx_buffer_result_ok;
    }
    fn releaseDevice(input: *const a.GfxDeviceLease, quiesced: u32) callconv(.c) i32 {
        if (input.lease.id < 941 or input.lease.id > 944) { const call: *const fn (*const a.GfxDeviceLease, u32) callconv(.c) i32 = @ptrFromInt(original.device_release); return call(input, quiesced); }
        const i = (input.lease.id - 941) / 2; const slot = &slots[i]; std.debug.assert(slot.active and quiesced == 1);
        if (input.access == 3) {
            std.debug.assert(std.meta.eql(input.*, slot.gpu));
            if (std.mem.eql(u8, scenario, "context_fifo_dma")) return a.gfx_buffer_error_busy;
            slot.gpu = .{};
        } else { std.debug.assert(slot.gpu.lease.id == 0 and std.meta.eql(input.*, slot.dma)); slot.dma = .{}; }
        return a.gfx_buffer_result_ok;
    }
    fn release(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        const i = select(input.*) orelse { const call: *const fn (*const a.GfxBufferHandle) callconv(.c) i32 = @ptrFromInt(original.buffer_release); return call(input); };
        const slot = &slots[i]; std.debug.assert(slot.active and !slot.cpu and slot.dma.lease.id == 0 and slot.gpu.lease.id == 0);
        slot.active = false; released += 1; return a.gfx_buffer_result_ok;
    }
};
