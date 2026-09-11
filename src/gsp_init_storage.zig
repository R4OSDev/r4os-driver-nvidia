//! Pre-submission storage for Libos/RM arguments, logs and shared queues.
//! One resident allocation, one contiguous argument mapping, five contiguous
//! log mappings and one scatter/gather queue mapping. Nothing is submitted.
//! The eventual execution owner must prove quiescence before close and close
//! this owner before any other boot allocation referenced by the init state.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const init = @import("gsp_init.zig");
const radix = @import("gsp_radix.zig");
pub const max_mappings = 7;
pub const Error = init.Error || @import("gsp_dma.zig").Error;
const Piece = struct {
    pin: a.DmaPinnedBuffer = .{},
    mapping: a.DmaMapping = .{},
};
const Area = struct { offset: usize, bytes: usize, segments: u16, direction: u32 };
const areas: [max_mappings]Area = blk: {
    var values: [max_mappings]Area = undefined;
    values[0] = .{ .offset = 0, .bytes = 8192, .segments = 1, .direction = a.dma_direction_to_device };
    for (1..6) |index| values[index] = .{
        .offset = init.logs_offset + (index - 1) * init.log_bytes,
        .bytes = init.log_bytes,
        .segments = 1,
        .direction = a.dma_direction_bidirectional,
    };
    values[6] = .{ .offset = init.queues_offset, .bytes = init.queue_allocation_bytes, .segments = a.dma_max_segments, .direction = a.dma_direction_bidirectional };
    break :blk values;
};
pub const Report = struct {
    init: init.Report,
    mappings: usize = max_mappings,
    queue_segments: usize,
    bounced: usize,
};
pub const Storage = struct {
    context: ?r4os.r4dev.DriverContext = null,
    heap: ?r4os.r4dev.DriverHeapContext = null,
    clock: ?r4os.r4dev.DriverResourceContext = null,
    allocation: a.DriverHeapAllocation = .{},
    pieces: [max_mappings]Piece = @splat(.{}),
    piece_count: usize = 0,
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

    /// Other allocations remain borrowed and owned by the caller through this
    /// call. Their spans only exclude aliasing; successful preparation confers
    /// no ownership of those external allocations or of GPU execution state.
    pub fn stage(self: *Storage, ctx: *const r4os.r4dev.DriverContext, chip_id: u16, excluded: []const init.Span, timeout_ns: u64) Error!Report {
        if (self.context != null) return error.Busy;
        if (chip_id != 0x176) return error.Profile;
        if (excluded.len > init.max_excluded) return error.Segments;
        if (!ctx.supportsDriverApi(19, @offsetOf(a.DriverApi, "dma_unpin_buffer") + @sizeOf(usize))) return error.Api;
        self.context = ctx.*;
        self.clock = ctx.resources() orelse return error.Api;
        self.last_clock = self.clock.?.nowNs();
        self.deadline = std.math.add(u64, self.last_clock, timeout_ns) catch return error.InvalidDeadline;
        if (timeout_ns == 0 or self.deadline == std.math.maxInt(u64)) return error.InvalidDeadline;
        self.heap = ctx.heap() orelse return error.Api;
        try self.checkClock();
        if (self.heap.?.allocate(init.output_bytes, init.page_bytes, &self.allocation) != a.driver_heap_ok) return error.Memory;
        const allocation = &self.allocation;
        if (allocation.handle == 0 or allocation.cpu_address == 0 or allocation.cpu_address & 4095 != 0 or
            allocation.byte_length != init.output_bytes or allocation.alignment < init.page_bytes or
            allocation.cpu_address > std.math.maxInt(u64) - allocation.byte_length) return error.Memory;
        try self.checkClock();
        const data: [*]u8 = @ptrFromInt(allocation.cpu_address);
        const output = data[0..init.output_bytes];
        @memset(output, 0); // Initial map can already synchronize bounce backing.
        var addresses: [6]u64 = undefined;
        var queue_segments: [a.dma_max_segments]init.Span = undefined;
        var queue_count: usize = 0;
        var bounced: usize = 0;
        for (areas, 0..) |area, index| {
            try self.checkClock();
            const piece = &self.pieces[index];
            self.piece_count = index + 1; // Retain even partially published errors.
            if (ctx.pinDmaBuffer(output[area.offset..][0..area.bytes], &piece.pin) != 0) return error.Pin;
            const pin = &piece.pin;
            if (pin.version != 1 or pin.size < @sizeOf(a.DmaPinnedBuffer) or pin.handle == 0 or
                pin.virt_addr != allocation.cpu_address + area.offset or pin.bytes != area.bytes or
                pin.page_count != area.bytes / init.page_bytes or pin.flags != 0 or pin.reserved != 0) return error.Descriptor;
            try self.checkClock();
            const constraints = a.DmaConstraints{
                .dma_mask = radix.dma_mask,
                .alignment = init.page_bytes,
                .max_segment_bytes = @intCast(area.bytes),
                .max_segments = area.segments,
                .flags = a.dma_flag_coherent | a.dma_flag_allow_bounce,
            };
            if (ctx.mapDmaPinned(pin, &constraints, area.direction, &piece.mapping) != 0) return error.Map;
            const map = &piece.mapping;
            if (map.version != 1 or map.size < @sizeOf(a.DmaMapping) or map.handle == 0 or map.pin_handle != pin.handle or
                map.requested_bytes != area.bytes or map.mapped_bytes != area.bytes or map.direction != area.direction or
                map.segment_count == 0 or map.segment_count > area.segments or map.reserved0 != 0 or map.reserved1 != 0 or
                (map.flags & ~a.dma_mapping_flag_bounced) != constraints.flags) return error.Descriptor;
            var covered: u64 = 0;
            for (map.segments[0..map.segment_count], 0..) |segment, segment_index| {
                if (segment.reserved != 0 or segment.bytes == 0 or segment.bytes > area.bytes - covered) return error.Descriptor;
                covered += segment.bytes;
                if (index == 6) queue_segments[segment_index] = .{ .address = segment.phys_addr, .bytes = segment.bytes } else addresses[index] = segment.phys_addr;
            }
            if (covered != area.bytes) return error.Descriptor;
            if (index == 6) queue_count = map.segment_count;
            if (map.flags & a.dma_mapping_flag_bounced != 0) bounced += 1;
            try self.checkClock();
        }
        // Check the whole contiguous argument span before deriving its RM page.
        if (addresses[0] == 0 or addresses[0] > radix.dma_mask or 8191 > radix.dma_mask - addresses[0]) return error.Address;
        var bindings: init.Bindings = .{
            .chip_id = chip_id,
            .libos = .{ .address = addresses[0], .bytes = init.page_bytes },
            .rm = .{ .address = addresses[0] + init.page_bytes, .bytes = init.page_bytes },
            .logs = undefined,
            .queues = queue_segments[0..queue_count],
            .excluded = excluded,
        };
        for (&bindings.logs, 0..) |*span, index| span.* = .{ .address = addresses[index + 1], .bytes = init.log_bytes };
        const prepared = try init.encode(&bindings, output);
        try self.checkClock();
        // Required also for bidirectional logs/queues: PTEs and command metadata
        // were filled after the initial mapping copied zeroes to a bounce area.
        for (self.pieces[0..self.piece_count]) |*piece| {
            if (ctx.syncDmaForDevice(&piece.mapping) != 0) return error.Synchronization;
            try self.checkClock();
        }
        self.report = .{ .init = prepared, .queue_segments = queue_count, .bounced = bounced };
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
