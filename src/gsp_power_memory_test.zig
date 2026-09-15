//! Independent RUSD page beside the existing graph-control BO fixture.
const std = @import("std");
const a = @import("r4os").abi;
pub const Model = struct {
    pub var data: [4096]u8 align(4096) = undefined;
    pub var active = false;
    pub var mapped = false;
    pub var cpu = false;
    pub var attached = false;
    pub var releases: usize = 0;
    pub var scenario: []const u8 = "";
    pub var wanted_mask: u64 = 0;
    pub var wanted_until: u64 = 0;
    pub var exchanges: usize = 0;
    pub var published: a.GfxTelemetryState = .{};
    var descriptor: a.GfxBufferDescriptor = .{};
    var dma: a.GfxDeviceLease = .{};
    const reference: a.GfxBufferHandle = .{ .id = 1071, .generation = 1131 };
    const cpu_lease: a.GfxBufferHandle = .{ .id = 1073, .generation = 1133 };
    pub const address: u64 = 0x5000000000;
    pub fn reset(name: []const u8) void {
        // Only test disposal discards retained effects between independent
        // boots; the assertions run before this fixture reset.
        active = false; mapped = false; cpu = false; attached = false;
        releases = 0; scenario = name; dma = .{};
        wanted_mask = 0; wanted_until = 0; exchanges = 0; published = .{};
    }
    pub fn exchange(input: *const a.GfxTelemetryState, output: *a.GfxTelemetryDemand) callconv(.c) i32 {
        std.debug.assert(is("power_success") and input.version == 1 and input.size == 544 and
            input.adapter_id == 0x01000000 and input.memory_generation != 0 and input.sampled_ns != 0);
        exchanges += 1; published = input.*;
        output.* = .{ .adapter_id = input.adapter_id, .memory_generation = input.memory_generation,
            .until_ns = wanted_until, .metric_mask = wanted_mask };
        return a.gfx_buffer_result_ok;
    }
    pub fn owns(handle: a.GfxBufferHandle) bool { return handle.id >= 1071 and handle.id <= 1074; }
    pub fn is(name: []const u8) bool { return std.mem.eql(u8, scenario, name); }
    pub fn create(input: *const a.GfxBufferDescriptor, output: *a.GfxBufferReference) i32 {
        if (!std.mem.startsWith(u8, scenario, "power_")) return a.gfx_buffer_error_oom;
        std.debug.assert(!active and input.byte_length == data.len and input.alignment == 4096);
        active = true; descriptor = input.*; @memset(&data, 0xa5);
        output.* = .{ .buffer = .{ .id = 1072, .generation = 1132 }, .reference = reference };
        return a.gfx_buffer_result_ok;
    }
    pub fn describe(input: *const a.GfxBufferHandle, output: *a.GfxBufferDescriptor) i32 {
        std.debug.assert(active and std.meta.eql(input.*, reference)); output.* = descriptor; return a.gfx_buffer_result_ok;
    }
    pub fn mapCpu(input: *const a.GfxBufferHandle, access: u32, offset: u64, bytes: u64, output: *a.GfxBufferMap) i32 {
        std.debug.assert(active and !cpu and std.meta.eql(input.*, reference) and offset == 0 and bytes == data.len and
            access == @as(u32, if (mapped) a.gfx_buffer_map_read else a.gfx_buffer_map_write));
        cpu = true;
        output.* = .{ .lease = cpu_lease, .cpu_address = @intFromPtr(&data), .byte_length = data.len, .cache_policy = a.gfx_buffer_cache_write_back };
        return a.gfx_buffer_result_ok;
    }
    pub fn unmapCpu(input: *const a.GfxBufferHandle) i32 {
        std.debug.assert(active and cpu and std.meta.eql(input.*, cpu_lease)); cpu = false; return a.gfx_buffer_result_ok;
    }
    pub fn acquire(input: *const a.GfxBufferHandle, request: *const a.GfxDeviceRequest, output: *a.GfxDeviceLease) i32 {
        std.debug.assert(active and !mapped and !cpu and std.meta.eql(input.*, reference) and std.mem.allEqual(u8, &data, 0) and
            request.byte_length == data.len and request.byte_offset == 0 and request.access == 4 and request.address_space == 0 and
            request.gpu_virtual_address == 0 and request.adapter_id == 0x01000000 and request.device_generation != 0);
        mapped = true;
        output.* = .{ .lease = .{ .id = 1074, .generation = 1134 }, .byte_length = data.len, .adapter_id = request.adapter_id,
            .device_generation = request.device_generation, .driver_owner = 7, .access = 4, .dma_mask = request.dma_mask };
        dma = output.*; return a.gfx_buffer_result_ok;
    }
    pub fn segment(input: *const a.GfxDeviceLease, offset: u64, output: *a.GfxDmaSegment) i32 {
        std.debug.assert(mapped and std.meta.eql(input.*, dma) and offset == 0);
        output.* = .{ .dma_address = address, .byte_length = data.len, .next_offset = data.len }; return a.gfx_buffer_result_ok;
    }
    pub fn releaseDevice(input: *const a.GfxDeviceLease, quiesced: u32) i32 {
        std.debug.assert(active and mapped and !attached and !cpu and quiesced == 1 and std.meta.eql(input.*, dma));
        mapped = false; return a.gfx_buffer_result_ok;
    }
    pub fn release(input: *const a.GfxBufferHandle) i32 {
        std.debug.assert(active and !mapped and !cpu and !attached and std.meta.eql(input.*, reference));
        active = false; releases += 1; return a.gfx_buffer_result_ok;
    }
    pub fn update(stamp: u64) void {
        std.debug.assert(attached and mapped and !cpu);
        // Original 570.144 header offsets, independently witnessed by C.
        std.mem.writeInt(u64, data[72..80], stamp, .little);
        std.mem.writeInt(u32, data[80..84], 1500, .little);
        std.mem.writeInt(u32, data[84..88], 7000, .little);
        std.mem.writeInt(u64, data[264..272], stamp, .little);
        std.mem.writeInt(u32, data[272..276], 4, .little); // P2 mask.
        std.mem.writeInt(u64, data[296..304], stamp, .little);
        std.mem.writeInt(u32, data[304..308], 55 * 256, .little);
    }
};
