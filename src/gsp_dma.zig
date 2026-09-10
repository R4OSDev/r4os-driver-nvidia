//! Resident GSP radix backing and bounded R4D DMA ownership, without GPU
//! submission. A future execution owner must establish device quiescence
//! before close; a timeout alone never grants release after submission.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const radix = @import("gsp_radix.zig");
pub const max_mappings = 4;
pub const Error = radix.Error || error{ Api, Busy, Memory, Pin, Map, Descriptor, Synchronization, InvalidDeadline, Timeout, ClockRegression };
const Piece = struct {
    offset: usize = 0,
    pin: a.DmaPinnedBuffer = .{},
    mapping: a.DmaMapping = .{},
};
pub const Report = struct {
    root_address: u64,
    image_bytes: usize,
    allocation_bytes: usize,
    table_bytes: usize,
    mappings: usize,
    segments: usize,
    bounced: usize,
};
pub const Storage = struct {
    context: ?r4os.r4dev.DriverContext = null,
    heap: ?r4os.r4dev.DriverHeapContext = null,
    clock: ?r4os.r4dev.DriverResourceContext = null,
    allocation: a.DriverHeapAllocation = .{},
    pieces: [max_mappings]Piece = @splat(.{}),
    segments: [radix.max_segments]radix.Segment = @splat(.{ .address = 0, .bytes = 0 }),
    piece_count: usize = 0,
    segment_count: usize = 0,
    deadline: u64 = 0,
    last_clock: u64 = 0,
    report: ?Report = null,

    fn checkClock(self: *Storage) Error!void {
        const now = self.clock.?.nowNs();
        if (now == std.math.maxInt(u64)) return error.InvalidDeadline;
        if (now < self.last_clock) return error.ClockRegression;
        if (now >= self.deadline) return error.Timeout;
        self.last_clock = now;
    }

    /// image borrows the admitted .fwimage bytes only until this call returns.
    /// Device mapping initially synchronizes zeroed backing. After the radix
    /// entries and image are written, EVERY mapping is synchronized again,
    /// including any bounce backing, before a usable root is published.
    pub fn stage(self: *Storage, ctx: *const r4os.r4dev.DriverContext, image: []const u8, timeout_ns: u64) Error!Report {
        if (self.context != null) return error.Busy;
        const need = try radix.requirements(image.len);
        if (need.allocation_bytes > @as(usize, a.dma_mapping_max_bytes) * max_mappings) return error.Capacity;
        if (!ctx.supportsDriverApi(19, @offsetOf(a.DriverApi, "dma_unpin_buffer") + @sizeOf(usize))) return error.Api;
        self.context = ctx.*;
        self.clock = ctx.resources() orelse return error.Api;
        self.last_clock = self.clock.?.nowNs();
        self.deadline = std.math.add(u64, self.last_clock, timeout_ns) catch return error.InvalidDeadline;
        if (timeout_ns == 0 or self.deadline == std.math.maxInt(u64)) return error.InvalidDeadline;
        self.heap = ctx.heap() orelse return error.Api;
        try self.checkClock();
        if (self.heap.?.allocate(need.allocation_bytes, radix.page_bytes, &self.allocation) != a.driver_heap_ok) return error.Memory;
        const allocation = &self.allocation;
        if (allocation.handle == 0 or allocation.cpu_address == 0 or allocation.cpu_address & 4095 != 0 or
            allocation.byte_length != need.allocation_bytes or allocation.alignment < radix.page_bytes or
            allocation.cpu_address > std.math.maxInt(u64) - allocation.byte_length) return error.Memory;
        try self.checkClock();
        const data: [*]u8 = @ptrFromInt(allocation.cpu_address);
        const output = data[0..need.allocation_bytes];
        // Map's initial synchronization may copy to bounce memory. Do not let
        // that copy expose uninitialized resident heap contents to a device.
        @memset(output, 0);
        var offset: usize = 0;
        var bounced: usize = 0;
        while (offset < output.len) {
            try self.checkClock();
            const piece = &self.pieces[self.piece_count];
            self.piece_count += 1; // Retain even partially published failures.
            piece.offset = offset;
            const length = @min(output.len - offset, a.dma_mapping_max_bytes);
            if (ctx.pinDmaConstBuffer(output[offset..][0..length], &piece.pin) != 0) return error.Pin;
            const pin = &piece.pin;
            if (pin.version != 1 or pin.size < @sizeOf(a.DmaPinnedBuffer) or pin.handle == 0 or
                pin.virt_addr != allocation.cpu_address + offset or pin.bytes != length or pin.page_count != length / 4096 or
                pin.flags != 0 or pin.reserved != 0) return error.Descriptor;
            try self.checkClock();
            const constraints = a.DmaConstraints{
                .dma_mask = radix.dma_mask,
                .alignment = radix.page_bytes,
                .max_segment_bytes = @intCast(length),
                .max_segments = a.dma_max_segments,
                .flags = a.dma_flag_coherent | a.dma_flag_allow_bounce,
            };
            if (ctx.mapDmaPinned(pin, &constraints, a.dma_direction_to_device, &piece.mapping) != 0) return error.Map;
            const map = &piece.mapping;
            if (map.version != 1 or map.size < @sizeOf(a.DmaMapping) or map.handle == 0 or map.pin_handle != pin.handle or
                map.requested_bytes != length or map.mapped_bytes != length or map.direction != a.dma_direction_to_device or
                map.segment_count == 0 or map.segment_count > a.dma_max_segments or map.reserved0 != 0 or map.reserved1 != 0 or
                (map.flags & ~a.dma_mapping_flag_bounced) != constraints.flags) return error.Descriptor;
            var covered: usize = 0;
            for (map.segments[0..map.segment_count]) |segment| {
                if (segment.reserved != 0 or segment.bytes == 0 or segment.bytes > length - covered) return error.Descriptor;
                if (self.segment_count == self.segments.len) return error.Segments;
                self.segments[self.segment_count] = .{ .address = segment.phys_addr, .bytes = segment.bytes };
                self.segment_count += 1;
                covered += segment.bytes;
            }
            if (covered != length) return error.Descriptor;
            if (map.flags & a.dma_mapping_flag_bounced != 0) bounced += 1;
            try self.checkClock();
            offset += length;
        }
        const root = try radix.encode(image, self.segments[0..self.segment_count], output);
        try self.checkClock();
        for (self.pieces[0..self.piece_count]) |*piece| {
            if (ctx.syncDmaForDevice(&piece.mapping) != 0) return error.Synchronization;
            try self.checkClock();
        }
        self.report = .{
            .root_address = root,
            .image_bytes = image.len,
            .allocation_bytes = need.allocation_bytes,
            .table_bytes = need.table_bytes,
            .mappings = self.piece_count,
            .segments = self.segment_count,
            .bounced = bounced,
        };
        return self.report.?;
    }

    pub fn close(self: *Storage) bool {
        self.report = null;
        const ctx = self.context orelse return self.allocation.handle == 0;
        var index = self.piece_count;
        while (index > 0) {
            index -= 1;
            const piece = &self.pieces[index];
            if (piece.mapping.handle != 0) {
                var descriptor = piece.mapping;
                if (ctx.unmapDma(&descriptor) != 0) return false;
                piece.mapping = .{};
            }
        }
        index = self.piece_count;
        while (index > 0) {
            index -= 1;
            const piece = &self.pieces[index];
            if (piece.pin.handle != 0) {
                var descriptor = piece.pin;
                if (ctx.unpinDmaBuffer(&descriptor) != 0) return false;
                piece.pin = .{};
            }
        }
        if (self.allocation.handle != 0) {
            const heap = self.heap orelse return false;
            if (heap.release(self.allocation.handle) != a.driver_heap_ok) return false;
        }
        self.* = .{};
        return true;
    }
};
