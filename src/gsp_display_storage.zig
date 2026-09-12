//! One private coherent 4KB display pushbuffer; physical DMA, no GPU VA.
//! Device/RM reachability is retained independently of the CPU producer map.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub const Error = error{Busy, Api, Memory, Descriptor, Map, Retained};
pub const bytes: u64 = 4096;
const mask: u64 = (@as(u64, 1) << 40) - 1;
pub const Storage = struct {
    self_address: usize = 0,
    memory: ?r4os.driver_memory.Context = null,
    reference: a.GfxBufferReference = .{},
    reference_stamp: a.GfxBufferReference = .{},
    cpu: a.GfxBufferMap = .{},
    dma: a.GfxDeviceLease = .{},
    dma_stamp: a.GfxDeviceLease = .{},
    segment: a.GfxDmaSegment = .{},
    segment_stamp: a.GfxDmaSegment = .{},
    adapter: u32 = 0,
    epoch: u64 = 0,
    ready: bool = false,
    retained: bool = false,

    pub fn prepare(self: *Storage, ctx: *const r4os.r4dev.DriverContext, adapter: u32, epoch: u64) Error!void {
        if (self.self_address != 0) return error.Busy;
        if (adapter == 0 or epoch == 0) return error.Descriptor;
        const memory = ctx.memory() orelse return error.Api;
        self.self_address = @intFromPtr(self); self.memory = memory; self.adapter = adapter; self.epoch = epoch;
        self.prepareInner() catch |err| {
            // Malformed partially returned ownership is never guessed away.
            if (err == error.Descriptor or err == error.Retained) self.retained = true;
            return err;
        };
    }
    fn prepareInner(self: *Storage) Error!void {
        const memory = self.memory.?;
        const descriptor: a.GfxBufferDescriptor = .{ .byte_length = bytes, .alignment = bytes,
            .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source };
        const created = memory.bufferCreate(&descriptor, &self.reference);
        self.reference_stamp = self.reference;
        if (created != a.gfx_buffer_result_ok and self.reference.reference.id == 0 and self.reference.buffer.id == 0) return error.Memory;
        const ref = self.reference;
        if (ref.version != 1 or ref.size < @sizeOf(a.GfxBufferReference) or !validHandle(ref.reference) or !validHandle(ref.buffer) or ref.flags != 0 or ref.reserved0 != 0) return error.Descriptor;
        if (created != a.gfx_buffer_result_ok) return error.Memory;
        var described: a.GfxBufferDescriptor = .{};
        if (memory.bufferDescribe(&ref.reference, &described) != a.gfx_buffer_result_ok or !std.meta.eql(descriptor, described)) return error.Descriptor;
        const mapped = memory.bufferMap(&ref.reference, a.gfx_buffer_map_write, 0, bytes, &self.cpu);
        if (mapped != a.gfx_buffer_result_ok and self.cpu.lease.id == 0) return error.Map;
        const cpu = self.cpu;
        if (cpu.version != 1 or cpu.size < @sizeOf(a.GfxBufferMap) or !validHandle(cpu.lease) or cpu.cpu_address == 0 or cpu.cpu_address & 4095 != 0 or
            cpu.cpu_address > std.math.maxInt(u64) - bytes or cpu.byte_length != bytes or cpu.cache_policy != a.gfx_buffer_cache_write_back or cpu.reserved0 != 0) return error.Descriptor;
        if (mapped != a.gfx_buffer_result_ok) return error.Map;
        const ptr: [*]u8 = @ptrFromInt(cpu.cpu_address); @memset(ptr[0..bytes], 0);
        if (memory.bufferUnmap(&cpu.lease) != a.gfx_buffer_result_ok) return error.Retained;
        self.cpu = .{};
        // Private command storage remains CPU-producible while DMA-resident.
        // Unlike image data it has no public reference or independent users.
        const acquired = memory.deviceAcquire(&ref.reference, &.{ .byte_length = bytes, .adapter_id = self.adapter,
            .device_generation = self.epoch, .access = 4, .dma_mask = mask }, &self.dma);
        self.dma_stamp = self.dma;
        if (acquired != a.gfx_buffer_result_ok and self.dma.lease.id == 0) return error.Map;
        const dma = self.dma;
        if (dma.version != 1 or dma.size < @sizeOf(a.GfxDeviceLease) or !validHandle(dma.lease) or dma.byte_offset != 0 or dma.byte_length != bytes or
            dma.gpu_virtual_address != 0 or dma.device_generation != self.epoch or dma.adapter_id != self.adapter or dma.driver_owner == 0 or
            dma.access != 4 or dma.address_space != 0 or dma.dma_mask != mask) return error.Descriptor;
        if (acquired != a.gfx_buffer_result_ok) return error.Map;
        if (memory.deviceSegment(&dma, 0, &self.segment) != a.gfx_buffer_result_ok) return error.Map;
        const segment = self.segment;
        if (segment.version != 1 or segment.size < @sizeOf(a.GfxDmaSegment) or segment.dma_address == 0 or segment.dma_address & 4095 != 0 or
            segment.dma_address > mask - 4095 or segment.byte_length != bytes or segment.next_offset != bytes) return error.Descriptor;
        self.segment_stamp = segment; self.ready = true;
    }
    pub fn physical(self: *const Storage) ?u64 {
        if (self.self_address != @intFromPtr(self) or !self.ready or self.memory == null or self.cpu.lease.id != 0 or self.epoch == 0 or self.adapter == 0 or
            !std.meta.eql(self.reference, self.reference_stamp) or !std.meta.eql(self.dma, self.dma_stamp) or !std.meta.eql(self.segment, self.segment_stamp)) return null;
        return self.segment.dma_address;
    }
    /// Caller must clear retained only after the channel's hardware retirement.
    pub fn close(self: *Storage) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.retained) return false;
        const memory = self.memory orelse return false;
        self.ready = false;
        if (self.dma.lease.id != 0) {
            if (memory.deviceRelease(&self.dma, 1) != a.gfx_buffer_result_ok) return false;
            self.dma = .{}; self.dma_stamp = .{};
        }
        if (self.cpu.lease.id != 0) {
            if (memory.bufferUnmap(&self.cpu.lease) != a.gfx_buffer_result_ok) return false;
            self.cpu = .{};
        }
        if (self.reference.reference.id != 0) {
            if (memory.bufferRelease(&self.reference.reference) != a.gfx_buffer_result_ok) return false;
            self.reference = .{}; self.reference_stamp = .{};
        }
        if (memory.collect() != a.gfx_buffer_result_ok) return false;
        self.* = .{}; return true;
    }
};
fn validHandle(h: a.GfxBufferHandle) bool { return h.id != 0 and h.generation != 0 and h.reserved0 == 0; }
