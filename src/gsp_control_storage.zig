//! Private control storage uses the common BO owner from normal Driver Work.
//! CPU access, direct DMA residency and confirmed GPU-VA residency are distinct
//! leases over the same pages. RM reachability vetoes every backing release.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const wire = @import("gsp_buffer_wire.zig");
pub const Error = error{ Busy, Api, Memory, Descriptor, Map, Synchronization };
const ok = a.gfx_buffer_result_ok;
const dma_mask = (@as(u64, 1) << 47) - 1;
pub const Storage = struct {
    self_address: usize = 0,
    memory: ?r4os.driver_memory.Context = null,
    adapter: u32 = 0,
    epoch: u64 = 0,
    reference: a.GfxBufferReference = .{},
    cpu: a.GfxBufferMap = .{},
    dma: a.GfxDeviceLease = .{},
    gpu: a.GfxDeviceLease = .{},
    reference_stamp: a.GfxBufferReference = .{},
    dma_stamp: a.GfxDeviceLease = .{},
    gpu_stamp: a.GfxDeviceLease = .{},
    pages_stamp: [wire.pages]u64 = @splat(0),
    pages: [wire.pages]u64 = @splat(0),
    retained: bool = false,
    prepared: bool = false,

    pub fn prepare(self: *Storage, ctx: *const r4os.r4dev.DriverContext, adapter: u32, epoch: u64) Error!void {
        if (self.self_address != 0) return error.Busy;
        if (adapter == 0 or epoch == 0) return error.Descriptor;
        // Older kernels reject a Work query: no private heap fallback can
        // silently claim the common BO lifetime or later app-buffer support.
        const memory = ctx.memory() orelse return error.Api;
        self.self_address = @intFromPtr(self);
        self.memory = memory;
        self.adapter = adapter;
        self.epoch = epoch;
        const request: a.GfxBufferDescriptor = .{
            .byte_length = wire.bytes,
            .alignment = 4096,
            .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write |
                a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_transfer_target,
        };
        if (memory.bufferCreate(&request, &self.reference) != ok) return error.Memory;
        const reference = self.reference;
        if (reference.version != 1 or reference.size < @sizeOf(a.GfxBufferReference) or
            !handleValid(reference.buffer) or !handleValid(reference.reference) or reference.flags != 0 or reference.reserved0 != 0) return error.Descriptor;
        var described: a.GfxBufferDescriptor = .{};
        if (memory.bufferDescribe(&reference.reference, &described) != ok or !std.meta.eql(request, described)) return error.Descriptor;
        if (memory.bufferMap(&reference.reference, a.gfx_buffer_map_write, 0, wire.bytes, &self.cpu) != ok) return error.Map;
        const cpu = self.cpu;
        if (cpu.version != 1 or cpu.size < @sizeOf(a.GfxBufferMap) or !handleValid(cpu.lease) or
            cpu.cpu_address == 0 or cpu.cpu_address & 4095 != 0 or cpu.cpu_address > std.math.maxInt(u64) - wire.bytes or
            cpu.byte_length != wire.bytes or cpu.cache_policy != a.gfx_buffer_cache_write_back or cpu.reserved0 != 0) return error.Descriptor;
        const pointer: [*]u8 = @ptrFromInt(cpu.cpu_address);
        @memset(pointer[0..wire.bytes], 0);
        // CPU Unmap publishes the WB visibility boundary before direct DMA
        // residency; neither the CPU pointer nor a bounce buffer is sent to RM.
        if (memory.bufferUnmap(&cpu.lease) != ok) return error.Synchronization;
        self.cpu = .{};
        if (memory.deviceAcquire(&reference.reference, &.{ .byte_length = wire.bytes, .adapter_id = adapter, .device_generation = epoch, .access = 4, .dma_mask = dma_mask }, &self.dma) != ok) return error.Map;
        if (!self.deviceValid(self.dma, 4, 0) or self.dma.dma_mask != dma_mask) return error.Descriptor;
        for (&self.pages, 0..) |*page, i| {
            var segment: a.GfxDmaSegment = .{};
            const offset = i * 4096;
            if (memory.deviceSegment(&self.dma, offset, &segment) != ok) return error.Map;
            if (segment.version != 1 or segment.size < @sizeOf(a.GfxDmaSegment) or segment.dma_address == 0 or
                segment.dma_address & 4095 != 0 or segment.dma_address > dma_mask - 4095 or
                segment.byte_length != 4096 or segment.next_offset != offset + 4096) return error.Descriptor;
            for (self.pages[0..i]) |prior| if (prior == segment.dma_address) return error.Descriptor;
            page.* = segment.dma_address;
        }
        self.reference_stamp = self.reference;
        self.dma_stamp = self.dma;
        self.pages_stamp = self.pages;
        self.prepared = true;
    }
    // Invoked only after successful RM map response AND its queue ACK.
    pub fn retainGpu(self: *Storage, address: u64) Error!void {
        if (!self.valid() or !self.retained or self.gpu.lease.id != 0) return error.Busy;
        if (self.memory.?.deviceAcquire(&self.reference.reference, &.{ .byte_length = wire.bytes, .gpu_virtual_address = address, .adapter_id = self.adapter, .device_generation = self.epoch, .access = 3, .address_space = 1 }, &self.gpu) != ok) return error.Map;
        if (!self.deviceValid(self.gpu, 3, address) or self.gpu.driver_owner != self.dma.driver_owner) return error.Descriptor;
        self.gpu_stamp = self.gpu;
    }
    fn deviceValid(self: *const Storage, value: a.GfxDeviceLease, access: u32, address: u64) bool {
        return value.version == 1 and value.size >= @sizeOf(a.GfxDeviceLease) and handleValid(value.lease) and
            value.byte_offset == 0 and value.byte_length == wire.bytes and value.gpu_virtual_address == address and
            value.device_generation == self.epoch and value.adapter_id == self.adapter and value.driver_owner != 0 and
            value.access == access and value.address_space == @as(u32, if (access == 3) 1 else 0);
    }
    pub fn valid(self: *const Storage) bool {
        return self.self_address == @intFromPtr(self) and self.memory != null and self.prepared and self.cpu.lease.id == 0 and
            self.adapter != 0 and self.epoch != 0 and self.dma.adapter_id == self.adapter and self.dma.device_generation == self.epoch and
            std.meta.eql(self.reference, self.reference_stamp) and std.meta.eql(self.dma, self.dma_stamp) and
            std.meta.eql(self.gpu, self.gpu_stamp) and std.meta.eql(self.pages, self.pages_stamp);
    }
    pub fn gpuReady(self: *const Storage, address: u64) bool {
        return self.valid() and self.gpu.lease.id != 0 and self.gpu.gpu_virtual_address == address;
    }
    /// Private before RPC publication, or after every mapping/object free ACK.
    pub fn close(self: *Storage) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.retained) return false;
        self.prepared = false;
        const memory = self.memory orelse return false;
        if (self.gpu.lease.id != 0) {
            if (memory.deviceRelease(&self.gpu, 1) != ok) return false;
            self.gpu = .{};
        }
        if (self.dma.lease.id != 0) {
            if (memory.deviceRelease(&self.dma, 1) != ok) return false;
            self.dma = .{};
        }
        if (self.cpu.lease.id != 0) {
            if (memory.bufferUnmap(&self.cpu.lease) != ok) return false;
            self.cpu = .{};
        }
        if (self.reference.reference.id != 0) {
            if (memory.bufferRelease(&self.reference.reference) != ok) return false;
            self.reference = .{};
        }
        if (memory.collect() != ok) return false;
        self.* = .{};
        return true;
    }
};
fn handleValid(value: a.GfxBufferHandle) bool {
    return value.id != 0 and value.generation != 0 and value.reserved0 == 0;
}
