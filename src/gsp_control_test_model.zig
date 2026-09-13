// Host-only common BO callbacks for the existing actual-Device test. Its
// three scattered pages model bus addresses, never physical GPU evidence.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const wire = @import("gsp_buffer_wire.zig");
pub const Model = struct {
    pub var original: a.DriverApi = undefined;
    pub var data: [wire.bytes]u8 align(4096) = undefined;
    pub var active = false;
    pub var cpu_mapped = false;
    pub var mapped = false;
    pub var gpu_mapped = false;
    pub var reading = false;
    pub var synced = false;
    pub var releases: usize = 0;
    pub var scenario: []const u8 = "";
    var sync_failed = false;
    var descriptor: a.GfxBufferDescriptor = .{};
    var dma: a.GfxDeviceLease = .{};
    var gpu: a.GfxDeviceLease = .{};
    var read_lease: a.GfxDeviceLease = .{};
    const reference: a.GfxBufferHandle = .{ .id = 71, .generation = 131 };
    const buffer: a.GfxBufferHandle = .{ .id = 72, .generation = 132 };
    const cpu: a.GfxBufferHandle = .{ .id = 73, .generation = 133 };
    pub const pages = [_]u64{ 0x6000000000, 0x7000000000, 0x6000004000 };
    pub fn install(api: *a.DriverApi) void {
        original = api.*;
        api.gfx_memory_query = memory;
    }
    pub fn reset(name: []const u8) void {
        // Only host effects are discarded after the real retention assertions.
        // Production has no equivalent forced-discard/quiescence shortcut.
        active = false;
        cpu_mapped = false;
        mapped = false;
        gpu_mapped = false;
        reading = false;
        synced = false;
        sync_failed = false;
        releases = 0;
        scenario = name;
        dma = .{};
        gpu = .{};
        read_lease = .{};
    }
    pub fn is(name: []const u8) bool {
        return std.mem.eql(u8, name, scenario);
    }
    fn memory(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        const result = original.gfx_memory_query.?(out);
        if (result != a.gfx_buffer_result_ok) return result;
        out.buffer_create = @intFromPtr(&create);
        out.buffer_describe = @intFromPtr(&describe);
        out.buffer_map = @intFromPtr(&mapCpu);
        out.buffer_unmap = @intFromPtr(&unmapCpu);
        out.buffer_release = @intFromPtr(&release);
        out.device_acquire = @intFromPtr(&acquire);
        out.device_segment = @intFromPtr(&segment);
        out.device_release = @intFromPtr(&releaseDevice);
        return a.gfx_buffer_result_ok;
    }
    fn create(input: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) callconv(.c) i32 {
        std.debug.assert(!active and input.byte_length == wire.bytes and input.alignment == 4096);
        active = true;
        descriptor = input.*;
        @memset(&data, 0xa5);
        out.* = .{ .buffer = buffer, .reference = reference };
        return if (is("control_allocation")) -1 else a.gfx_buffer_result_ok;
    }
    fn describe(input: *const a.GfxBufferHandle, out: *a.GfxBufferDescriptor) callconv(.c) i32 {
        std.debug.assert(active and std.meta.eql(input.*, reference));
        out.* = descriptor;
        return a.gfx_buffer_result_ok;
    }
    fn mapCpu(input: *const a.GfxBufferHandle, access: u32, offset: u64, bytes: u64, out: *a.GfxBufferMap) callconv(.c) i32 {
        std.debug.assert(active and !cpu_mapped and !reading and std.meta.eql(input.*, reference) and access == 1 and offset == 0 and bytes == wire.bytes);
        cpu_mapped = true;
        out.* = .{ .lease = cpu, .cpu_address = @intFromPtr(&data), .byte_length = bytes, .cache_policy = if (is("control_cache")) a.gfx_buffer_cache_write_combining else a.gfx_buffer_cache_write_back };
        return a.gfx_buffer_result_ok;
    }
    fn unmapCpu(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        std.debug.assert(active and cpu_mapped and std.meta.eql(input.*, cpu));
        if (is("control_sync") and !sync_failed) {
            sync_failed = true;
            return -1;
        }
        if (mapped and is("context_upload_sync")) return -1;
        synced = mapped or std.mem.allEqual(u8, &data, 0);
        cpu_mapped = false;
        return a.gfx_buffer_result_ok;
    }
    fn acquire(input: *const a.GfxBufferHandle, request: *const a.GfxDeviceRequest, out: *a.GfxDeviceLease) callconv(.c) i32 {
        std.debug.assert(active and synced and !cpu_mapped and std.meta.eql(input.*, reference) and
            request.byte_offset == 0 and request.adapter_id == 0x01000000 and request.device_generation != 0);
        if (request.access == 0) {
            std.debug.assert(mapped and gpu_mapped and !reading and request.byte_length > 0 and request.byte_length <= wire.bytes and request.byte_length & 3 == 0 and
                request.gpu_virtual_address == 0x600000 and request.address_space == 1 and request.dma_mask == std.math.maxInt(u64));
            if (is("context_upload_acquire")) return -1;
            reading = true;
            out.* = .{ .lease = .{ .id = 76, .generation = 136 }, .byte_length = request.byte_length,
                .gpu_virtual_address = request.gpu_virtual_address, .device_generation = request.device_generation, .adapter_id = request.adapter_id,
                .driver_owner = 7, .access = request.access, .address_space = request.address_space, .dma_mask = request.dma_mask };
            read_lease = out.*; return a.gfx_buffer_result_ok;
        }
        std.debug.assert(request.byte_length == wire.bytes);
        const is_gpu = request.access == 3;
        if (is_gpu) {
            std.debug.assert(mapped and !gpu_mapped and request.gpu_virtual_address == 0x600000 and request.address_space == 1);
            if (is("control_gpu_acquire")) return -1;
            gpu_mapped = true;
        } else {
            std.debug.assert(!mapped and request.access == 4 and request.address_space == 0 and request.gpu_virtual_address == 0 and request.dma_mask == (@as(u64, 1) << 47) - 1);
            mapped = true;
        }
        out.* = .{ .lease = .{ .id = if (is_gpu) 75 else 74, .generation = if (is_gpu) 135 else 134 }, .byte_length = request.byte_length, .gpu_virtual_address = request.gpu_virtual_address, .device_generation = request.device_generation, .adapter_id = request.adapter_id, .driver_owner = 7, .access = request.access, .address_space = request.address_space, .dma_mask = request.dma_mask };
        if (is_gpu) gpu = out.* else dma = out.*;
        return a.gfx_buffer_result_ok;
    }
    fn segment(input: *const a.GfxDeviceLease, offset: u64, out: *a.GfxDmaSegment) callconv(.c) i32 {
        std.debug.assert(mapped and std.meta.eql(input.*, dma) and offset & 4095 == 0 and offset < wire.bytes);
        const i = offset / 4096;
        out.* = .{ .dma_address = if (is("control_alias") and i == 2) pages[0] else pages[i], .byte_length = 4096, .next_offset = offset + 4096 };
        return a.gfx_buffer_result_ok;
    }
    fn releaseDevice(input: *const a.GfxDeviceLease, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(active and quiesced == 1);
        if (input.access == 0) {
            std.debug.assert(reading and gpu_mapped and mapped and std.meta.eql(input.*, read_lease));
            if (is("context_upload_release")) return -1;
            reading = false; read_lease = .{}; return a.gfx_buffer_result_ok;
        }
        std.debug.assert(!reading);
        if (input.access == 3) {
            std.debug.assert(gpu_mapped and mapped and std.meta.eql(input.*, gpu));
            if (is("control_gpu_release")) return -1;
            gpu_mapped = false;
        } else {
            std.debug.assert(mapped and !gpu_mapped and std.meta.eql(input.*, dma));
            if (is("control_dma_unmap")) return -1;
            mapped = false;
        }
        return a.gfx_buffer_result_ok;
    }
    fn release(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        std.debug.assert(active and !cpu_mapped and !mapped and !gpu_mapped and !reading and std.meta.eql(input.*, reference));
        if (is("control_release")) return -1;
        active = false;
        releases += 1;
        return a.gfx_buffer_result_ok;
    }
};
