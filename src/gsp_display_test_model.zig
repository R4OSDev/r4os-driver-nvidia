// Host-only coherent physical display rings, alongside the actual native
// VRAM/graph models. Release asserts the independently supplied MMIO state.
const std = @import("std");
const a = @import("r4os").abi;
pub const Model = struct {
    const Slot = struct { data: [4096]u8 align(4096) = undefined, active: bool = false, cpu: bool = false, synced: bool = false,
        descriptor: a.GfxBufferDescriptor = .{}, dma: a.GfxDeviceLease = .{}, hardware: bool = false, control: u32 = 0, state: u32 = 0 };
    pub var slots: [5]Slot = @splat(.{});
    var original: a.GfxDriverMemoryApi = .{};
    var scenario: []const u8 = "";
    pub var released: usize = 0;
    pub var words: []u32 = undefined;
    pub fn install(table: *a.DriverApi, name: []const u8, mmio: []u32) void {
        std.debug.assert(table.gfx_memory_query.?(&original) == a.gfx_buffer_result_ok);
        table.gfx_memory_query = query; slots = @splat(.{}); scenario = name; released = 0; words = mmio;
    }
    pub fn is(name: []const u8) bool { return std.mem.eql(u8, scenario, name); }
    fn query(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = original;
        out.buffer_create = @intFromPtr(&create); out.buffer_describe = @intFromPtr(&describe); out.buffer_map = @intFromPtr(&map);
        out.buffer_unmap = @intFromPtr(&unmap); out.buffer_release = @intFromPtr(&release);
        out.device_acquire = @intFromPtr(&acquire); out.device_release = @intFromPtr(&releaseDevice); out.device_segment = @intFromPtr(&segment);
        return a.gfx_buffer_result_ok;
    }
    fn ref(index: usize) a.GfxBufferHandle { return .{ .id = @intCast(1301 + index), .generation = 1301 }; }
    fn cpuRef(index: usize) a.GfxBufferHandle { return .{ .id = @intCast(1321 + index), .generation = 1302 }; }
    fn select(input: a.GfxBufferHandle) ?usize { for (0..slots.len) |i| if (std.meta.eql(input, ref(i))) return i; return null; }
    pub fn address(index: usize) u64 { return 0x8000000000 + index * 0x100000; }
    fn create(d: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) callconv(.c) i32 {
        if (d.byte_length != 4096) {
            const call: *const fn (*const a.GfxBufferDescriptor, *a.GfxBufferReference) callconv(.c) i32 = @ptrFromInt(original.buffer_create);
            return call(d, out);
        }
        std.debug.assert(d.byte_length == 4096 and d.alignment == 4096 and d.location == 0 and (d.usage == 7 or d.usage == 15));
        if (is("display_dma_oom")) return a.gfx_buffer_error_capacity;
        for (&slots, 0..) |*slot, i| if (!slot.active) {
            slot.* = .{ .active = true, .descriptor = d.* }; @memset(&slot.data, 0xa5);
            out.* = .{ .reference = ref(i), .buffer = .{ .id = @intCast(1311 + i), .generation = 1303 } }; return a.gfx_buffer_result_ok;
        };
        return a.gfx_buffer_error_capacity;
    }
    fn describe(input: *const a.GfxBufferHandle, out: *a.GfxBufferDescriptor) callconv(.c) i32 {
        const i = select(input.*) orelse { const call: *const fn (*const a.GfxBufferHandle, *a.GfxBufferDescriptor) callconv(.c) i32 = @ptrFromInt(original.buffer_describe); return call(input, out); };
        std.debug.assert(slots[i].active); out.* = slots[i].descriptor; return a.gfx_buffer_result_ok;
    }
    fn map(input: *const a.GfxBufferHandle, access: u32, offset: u64, length: u64, out: *a.GfxBufferMap) callconv(.c) i32 {
        const i = select(input.*) orelse { const call: *const fn (*const a.GfxBufferHandle, u32, u64, u64, *a.GfxBufferMap) callconv(.c) i32 = @ptrFromInt(original.buffer_map); return call(input, access, offset, length, out); };
        const slot = &slots[i];
        std.debug.assert(slot.active and !slot.cpu and access == a.gfx_buffer_map_write and offset == 0 and length == 4096);
        slot.cpu = true; out.* = .{ .lease = cpuRef(i), .cpu_address = @intFromPtr(&slot.data), .byte_length = length, .cache_policy = a.gfx_buffer_cache_write_back };
        if (is("context_display_map") and slot.dma.lease.id != 0 and slot.descriptor.usage == 15) out.byte_length -= 1;
        return a.gfx_buffer_result_ok;
    }
    fn unmap(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        for (&slots, 0..) |*slot, i| if (std.meta.eql(input.*, cpuRef(i))) {
            std.debug.assert(slot.active and slot.cpu);
            if (is("display_dma_unmap")) return a.gfx_buffer_error_busy;
            slot.cpu = false; slot.synced = slot.dma.lease.id != 0 or std.mem.allEqual(u8, &slot.data, 0); return a.gfx_buffer_result_ok;
        };
        const call: *const fn (*const a.GfxBufferHandle) callconv(.c) i32 = @ptrFromInt(original.buffer_unmap); return call(input);
    }
    fn acquire(input: *const a.GfxBufferHandle, request: *const a.GfxDeviceRequest, out: *a.GfxDeviceLease) callconv(.c) i32 {
        const i = select(input.*) orelse { const call: *const fn (*const a.GfxBufferHandle, *const a.GfxDeviceRequest, *a.GfxDeviceLease) callconv(.c) i32 = @ptrFromInt(original.device_acquire); return call(input, request, out); };
        const slot = &slots[i];
        std.debug.assert(slot.active and !slot.cpu and slot.synced and request.byte_length == 4096 and request.byte_offset == 0 and
            slot.dma.lease.id == 0 and request.access == 4 and request.address_space == 0 and request.gpu_virtual_address == 0 and request.dma_mask == 0xffffffffff);
        out.* = .{ .lease = .{ .id = @intCast(1341 + i), .generation = 1304 }, .byte_length = request.byte_length,
            .device_generation = request.device_generation, .adapter_id = request.adapter_id,
            .driver_owner = 7, .access = request.access, .address_space = request.address_space, .dma_mask = request.dma_mask };
        slot.dma = out.*; return a.gfx_buffer_result_ok;
    }
    fn segment(input: *const a.GfxDeviceLease, offset: u64, out: *a.GfxDmaSegment) callconv(.c) i32 {
        if (input.lease.id < 1341 or input.lease.id >= 1341 + slots.len) {
            const call: *const fn (*const a.GfxDeviceLease, u64, *a.GfxDmaSegment) callconv(.c) i32 = @ptrFromInt(original.device_segment);
            return call(input, offset, out);
        }
        const i = input.lease.id - 1341; const slot = &slots[i];
        std.debug.assert(slot.active and std.meta.eql(input.*, slot.dma) and offset == 0);
        out.* = .{ .dma_address = address(i), .byte_length = 4096, .next_offset = 4096 };
        if (is("display_dma_segment")) out.byte_length = 2048;
        return a.gfx_buffer_result_ok;
    }
    fn releaseDevice(input: *const a.GfxDeviceLease, quiesced: u32) callconv(.c) i32 {
        if (input.lease.id < 1341 or input.lease.id >= 1341 + slots.len) { const call: *const fn (*const a.GfxDeviceLease, u32) callconv(.c) i32 = @ptrFromInt(original.device_release); return call(input, quiesced); }
        const slot = &slots[input.lease.id - 1341]; std.debug.assert(slot.active and quiesced == 1 and std.meta.eql(input.*, slot.dma));
        if (slot.hardware) std.debug.assert(words[slot.control / 4] == 0 and words[slot.state / 4] == 0);
        if (is("display_dma_release")) return a.gfx_buffer_error_busy;
        slot.dma = .{}; return a.gfx_buffer_result_ok;
    }
    fn release(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        const i = select(input.*) orelse { const call: *const fn (*const a.GfxBufferHandle) callconv(.c) i32 = @ptrFromInt(original.buffer_release); return call(input); };
        const slot = &slots[i]; std.debug.assert(slot.active and !slot.cpu and slot.dma.lease.id == 0);
        slot.active = false; released += 1; return a.gfx_buffer_result_ok;
    }
};
