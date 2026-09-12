//! Private resident control pages owned by the real R4D heap/DMA services.
//! No R4DRAW app buffer, bounce copy, BAR address or GPU VA is substituted.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const wire = @import("gsp_buffer_wire.zig");
pub const Error = error{ Busy, Api, Memory, Descriptor, Pin, Map, Synchronization };
pub const Storage = struct {
    self_address: usize = 0,
    ctx: ?r4os.r4dev.DriverContext = null,
    heap: ?r4os.r4dev.DriverHeapContext = null,
    allocation: a.DriverHeapAllocation = .{},
    pin: a.DmaPinnedBuffer = .{},
    mapping: a.DmaMapping = .{},
    allocation_stamp: a.DriverHeapAllocation = .{},
    pin_stamp: a.DmaPinnedBuffer = .{},
    mapping_stamp: a.DmaMapping = .{},
    pages_stamp: [wire.pages]u64 = @splat(0),
    pages: [wire.pages]u64 = @splat(0),
    retained: bool = false,
    prepared: bool = false,

    pub fn prepare(self: *Storage, ctx: *const r4os.r4dev.DriverContext) Error!void {
        if (self.self_address != 0) return error.Busy;
        if (!ctx.supportsDriverApi(19, @offsetOf(a.DriverApi, "dma_unpin_buffer") + @sizeOf(usize))) return error.Api;
        self.self_address = @intFromPtr(self);
        self.ctx = ctx.*;
        self.heap = ctx.heap() orelse return error.Api;
        if (self.heap.?.allocate(wire.bytes, 4096, &self.allocation) != a.driver_heap_ok) return error.Memory;
        const allocation = self.allocation;
        if (allocation.handle == 0 or allocation.cpu_address == 0 or allocation.cpu_address & 4095 != 0 or
            allocation.byte_length != wire.bytes or allocation.alignment < 4096 or
            allocation.cpu_address > std.math.maxInt(u64) - wire.bytes) return error.Descriptor;
        const pointer: [*]u8 = @ptrFromInt(allocation.cpu_address);
        @memset(pointer[0..wire.bytes], 0);
        if (ctx.pinDmaBuffer(pointer[0..wire.bytes], &self.pin) != 0) return error.Pin;
        const pin = self.pin;
        if (pin.version != 1 or pin.size < @sizeOf(a.DmaPinnedBuffer) or pin.handle == 0 or
            pin.virt_addr != allocation.cpu_address or pin.bytes != wire.bytes or pin.page_count != wire.pages or
            pin.flags != 0 or pin.reserved != 0) return error.Descriptor;
        const constraints = a.DmaConstraints{ .dma_mask = (@as(u64, 1) << 47) - 1, .alignment = 4096, .max_segment_bytes = wire.bytes, .max_segments = a.dma_max_segments, .flags = a.dma_flag_coherent };
        if (ctx.mapDmaPinned(&pin, &constraints, a.dma_direction_bidirectional, &self.mapping) != 0) return error.Map;
        const mapping = &self.mapping;
        if (mapping.version != 1 or mapping.size < @sizeOf(a.DmaMapping) or mapping.handle == 0 or
            mapping.pin_handle != pin.handle or mapping.requested_bytes != wire.bytes or mapping.mapped_bytes != wire.bytes or
            mapping.direction != a.dma_direction_bidirectional or mapping.flags != constraints.flags or
            mapping.segment_count == 0 or mapping.segment_count > a.dma_max_segments or mapping.reserved0 != 0 or mapping.reserved1 != 0) return error.Descriptor;
        var count: usize = 0;
        for (mapping.segments[0..mapping.segment_count]) |segment| {
            if (segment.reserved != 0 or segment.phys_addr == 0 or (segment.phys_addr | segment.bytes) & 4095 != 0 or
                segment.bytes == 0 or segment.bytes > wire.bytes or segment.phys_addr > constraints.dma_mask or
                segment.bytes - 1 > constraints.dma_mask - segment.phys_addr) return error.Descriptor;
            var offset: u64 = 0;
            while (offset < segment.bytes) : (offset += 4096) {
                if (count >= self.pages.len) return error.Descriptor;
                const page = segment.phys_addr + offset;
                for (self.pages[0..count]) |prior| if (prior == page) return error.Descriptor;
                self.pages[count] = page;
                count += 1;
            }
        }
        if (count != self.pages.len) return error.Descriptor;
        if (ctx.syncDmaForDevice(mapping) != 0) return error.Synchronization;
        self.allocation_stamp = self.allocation;
        self.pin_stamp = self.pin;
        self.mapping_stamp = self.mapping;
        self.pages_stamp = self.pages;
        self.prepared = true;
    }
    pub fn valid(self: *const Storage) bool {
        return self.self_address == @intFromPtr(self) and self.ctx != null and self.prepared and
            self.allocation.handle != 0 and self.pin.handle != 0 and self.mapping.handle != 0 and
            std.meta.eql(self.allocation, self.allocation_stamp) and std.meta.eql(self.pin, self.pin_stamp) and
            std.meta.eql(self.mapping, self.mapping_stamp) and std.meta.eql(self.pages, self.pages_stamp);
    }
    /// Private before RPC publication, or after every mapping/object free ACK.
    /// The leaf refuses all cleanup while the remote owner can still reach it.
    pub fn close(self: *Storage) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.retained) return false;
        self.prepared = false;
        const ctx = self.ctx orelse return false;
        if (self.mapping.handle != 0) {
            var value = self.mapping;
            if (ctx.unmapDma(&value) != 0) return false;
            self.mapping = .{};
        }
        if (self.pin.handle != 0) {
            var value = self.pin;
            if (ctx.unpinDmaBuffer(&value) != 0) return false;
            self.pin = .{};
        }
        if (self.allocation.handle != 0) {
            const heap = self.heap orelse return false;
            if (heap.release(self.allocation.handle) != a.driver_heap_ok) return false;
        }
        self.* = .{};
        return true;
    }
};
