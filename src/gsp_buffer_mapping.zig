//! General existing-BO mapping on the actual GSP exchange. The common kernel
//! owns pages; this owner owns RM names, mappings and their confirmed unwind.
//! Original R4OS policy; wire fields remain in the attributed buffer codec.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const boot = @import("gsp_boot_events.zig");
const exchange = @import("gsp_exchange.zig");
const names = @import("gsp_rm_names.zig");
const vaspace = @import("gsp_vaspace.zig");
pub const wire = @import("gsp_buffer_wire.zig");
pub const Error = wire.Error || names.Error || error{ Api, Descriptor, Memory, Map, Busy, Retained };
pub const State = enum { creating, unwinding, ready, handed_off, destroying, closed, finished, failed };
pub const Info = struct { epoch: u64, buffer: a.GfxBufferHandle, virtual: u32, address: u64, logical_bytes: u64, mapped_bytes: u64, parts: u16 };
const chunk_bytes: u64 = wire.max_registration_pages * 4096;
const scratch_bytes = exchange.message.max_payload_bytes + wire.max_registration_pages * 8;
const dma_mask: u64 = (@as(u64, 1) << 47) - 1;
const page_batch = 64;

pub const Owner = struct {
    self_address: usize = 0,
    exchange: exchange.Exchange,
    memory: r4os.driver_memory.Context,
    heap: r4os.r4dev.DriverHeapContext,
    reservation: names.Children,
    namespace_live: bool = true,
    space: vaspace.Info,
    adapter: u32,
    source: a.GfxBufferReference,
    source_stamp: a.GfxBufferReference,
    logical_bytes: u64,
    mapped_bytes: u64,
    parts: u16,
    state: State = .creating,
    allocation: a.DriverHeapAllocation = .{},
    allocation_stamp: a.DriverHeapAllocation = .{},
    dma: a.GfxDeviceLease = .{},
    dma_stamp: a.GfxDeviceLease = .{},
    gpu: a.GfxDeviceLease = .{},
    gpu_stamp: a.GfxDeviceLease = .{},
    prepared: bool = false,
    registered: u16 = 0,
    mapped: u16 = 0,
    allocated: bool = false,
    address: u64 = 0,
    loaded_pages: usize = 0,
    operation: ?wire.Operation = null,
    operation_part: u16 = 0,
    request_bytes: usize = 0,
    small_request: [wire.max_request_bytes]u8 = undefined,
    deadline: u64,
    rejected: ?u32 = null,
    host_rejected: ?Error = null,
    failure: ?Error = null,
    protocol_failure: ?exchange.Error = null,

    /// On success this owner adopts the exact driver reference. On error the
    /// caller still owns it. No CPU payload mapping, allocation or copy occurs.
    pub fn init(token: *boot.Handoff, ctx: *const r4os.r4dev.DriverContext, adapter: u32, space: vaspace.Info,
        parent: names.Lease, source: a.GfxBufferReference, deadline: u64) Error!Owner
    {
        if (token.claimed or token.session.state != .active or token.session.pending != null or
            adapter == 0 or space.epoch != token.session.epoch or parent.epoch != space.epoch or parent.client != space.client) return error.Stale;
        try token.session.guard(deadline);
        if (source.version != 1 or source.size < @sizeOf(a.GfxBufferReference) or source.reserved0 != 0 or
            source.flags != a.gfx_buffer_reference_mapping_only or !handleValid(source.reference) or !handleValid(source.buffer)) return error.Descriptor;
        const memory = ctx.memory() orelse return error.Api;
        const heap = ctx.heap() orelse return error.Api;
        var descriptor: a.GfxBufferDescriptor = .{};
        if (memory.bufferDescribe(&source.reference, &descriptor) != a.gfx_buffer_result_ok) return error.Descriptor;
        if (descriptor.version != 1 or descriptor.size < @sizeOf(a.GfxBufferDescriptor) or descriptor.reserved0 != 0 or
            descriptor.byte_length == 0 or descriptor.location != a.gfx_buffer_location_system or descriptor.modifier != 0 or
            descriptor.adapter_id != 0 or descriptor.driver_owner != 0 or descriptor.device_generation != 0) return error.Descriptor;
        const rounded = (std.math.add(u64, descriptor.byte_length, 4095) catch return error.Bounds) & ~@as(u64, 4095);
        const count = (rounded - 1) / chunk_bytes + 1;
        if (count >= std.math.maxInt(u16)) return error.Bounds;
        const reservation = try token.session.rm_names.reserveChildren(parent, @intCast(count + 1));
        errdefer token.session.rm_names.retireChildren(reservation) catch {};
        try wire.validatePart(.{ .space = space, .memory = try reservation.object(0), .virtual = try reservation.object(@intCast(count)) },
            .{ .total_bytes = rounded, .byte_length = @min(rounded, chunk_bytes) });
        return .{ .exchange = try exchange.Exchange.init(token, deadline), .memory = memory, .heap = heap,
            .reservation = reservation, .space = space, .adapter = adapter, .source = source, .source_stamp = source,
            .logical_bytes = descriptor.byte_length, .mapped_bytes = rounded, .parts = @intCast(count), .deadline = deadline };
    }
    fn stable(self: *const Owner) Error!void {
        if ((self.self_address != 0 and self.self_address != @intFromPtr(self)) or self.space.epoch != self.exchange.session.epoch or
            !std.meta.eql(self.source, self.source_stamp) or !std.meta.eql(self.allocation, self.allocation_stamp) or
            !std.meta.eql(self.dma, self.dma_stamp) or !std.meta.eql(self.gpu, self.gpu_stamp)) return error.Stale;
        if (self.namespace_live) try self.exchange.session.rm_names.validateChildren(self.reservation);
    }
    fn fail(self: *Owner, err: Error) Error {
        self.failure = err;
        self.state = .failed;
        if (self.namespace_live) self.exchange.session.rm_names.retainChildren(self.reservation) catch {};
        self.protocol_failure = self.exchange.fail(error.Handler);
        return err;
    }
    pub fn info(self: *const Owner) ?Info {
        self.stable() catch return null;
        if (self.self_address != @intFromPtr(self) or (self.state != .ready and self.state != .handed_off) or
            self.exchange.session.state != .active or self.mapped != self.parts or !self.allocated or self.gpu.lease.id == 0) return null;
        return .{ .epoch = self.space.epoch, .buffer = self.source.buffer, .virtual = self.reservation.object(self.parts) catch return null,
            .address = self.address, .logical_bytes = self.logical_bytes, .mapped_bytes = self.mapped_bytes, .parts = self.parts };
    }
    fn binding(self: *const Owner, index: u16) Error!wire.Binding {
        if (index >= self.parts) return error.Bounds;
        return .{ .space = self.space, .memory = try self.reservation.object(index), .virtual = try self.reservation.object(self.parts) };
    }
    fn part(self: *const Owner, index: u16) wire.Part {
        const offset = @as(u64, index) * chunk_bytes;
        return .{ .total_bytes = self.mapped_bytes, .offset = offset, .byte_length = @min(chunk_bytes, self.mapped_bytes - offset) };
    }
    fn request(self: *const Owner) []u8 {
        if (self.allocation.handle == 0) return @constCast(&self.small_request);
        const data: [*]u8 = @ptrFromInt(self.allocation.cpu_address);
        return data[0..exchange.message.max_payload_bytes];
    }
    fn pages(self: *const Owner) []u64 {
        const data: [*]u64 = @ptrFromInt(self.allocation.cpu_address + exchange.message.max_payload_bytes);
        return data[0..wire.max_registration_pages];
    }
    fn prepare(self: *Owner) Error!void {
        const allocated = self.heap.allocate(scratch_bytes, 8, &self.allocation);
        self.allocation_stamp = self.allocation;
        if (allocated != a.driver_heap_ok and self.allocation.handle == 0) return error.Memory;
        const value = self.allocation;
        if (value.version != 1 or value.size < @sizeOf(a.DriverHeapAllocation) or value.handle == 0 or value.cpu_address == 0 or
            value.cpu_address & 7 != 0 or value.byte_length < scratch_bytes or value.alignment < 8 or value.reserved != 0 or
            value.cpu_address > std.math.maxInt(u64) - value.byte_length) return error.Descriptor;
        if (allocated != a.driver_heap_ok) return error.Memory;
        const acquired = self.memory.deviceAcquire(&self.source.reference, &.{ .byte_length = self.mapped_bytes, .adapter_id = self.adapter,
            .device_generation = self.space.epoch, .access = 4, .dma_mask = dma_mask }, &self.dma);
        self.dma_stamp = self.dma;
        if (acquired != a.gfx_buffer_result_ok and self.dma.lease.id == 0) return error.Map;
        if (!self.deviceValid(self.dma, 4, 0) or self.dma.dma_mask != dma_mask) return error.Descriptor;
        if (acquired != a.gfx_buffer_result_ok) return error.Map;
        self.prepared = true;
    }
    fn deviceValid(self: *const Owner, value: a.GfxDeviceLease, access: u32, address: u64) bool {
        return value.version == 1 and value.size >= @sizeOf(a.GfxDeviceLease) and handleValid(value.lease) and
            value.byte_offset == 0 and value.byte_length == self.mapped_bytes and value.gpu_virtual_address == address and
            value.device_generation == self.space.epoch and value.adapter_id == self.adapter and value.driver_owner != 0 and
            value.access == access and value.address_space == @as(u32, if (access == 3) 1 else 0);
    }
    fn gather(self: *Owner, index: u16) Error!bool {
        const extent = self.part(index);
        const count: usize = @intCast(extent.byte_length / 4096);
        const end = @min(count, self.loaded_pages + page_batch);
        while (self.loaded_pages < end) : (self.loaded_pages += 1) {
            const offset = extent.offset + self.loaded_pages * 4096;
            var segment: a.GfxDmaSegment = .{};
            if (self.memory.deviceSegment(&self.dma, offset, &segment) != a.gfx_buffer_result_ok) return error.Map;
            if (segment.version != 1 or segment.size < @sizeOf(a.GfxDmaSegment) or segment.dma_address == 0 or
                segment.dma_address & 4095 != 0 or segment.dma_address > dma_mask - 4095 or
                segment.byte_length != 4096 or segment.next_offset != offset + 4096) return error.Descriptor;
            self.pages()[self.loaded_pages] = segment.dma_address;
        }
        return self.loaded_pages == count;
    }
    pub fn poll(self: *Owner) Error!?exchange.Dispatch {
        try self.stable();
        if (self.state != .creating and self.state != .unwinding and self.state != .destroying) return error.State;
        self.self_address = @intFromPtr(self);
        return self.advance() catch |err| {
            if (err == error.Pending) return err;
            return self.fail(err);
        };
    }
    fn advance(self: *Owner) Error!?exchange.Dispatch {
        try self.exchange.guard(self.deadline);
        if (self.exchange.pending != null) return error.Pending;
        if (self.operation == null) {
            if (self.state == .creating and !self.prepared) {
                self.prepare() catch |err| {
                    // An invalid returned ownership descriptor cannot be used
                    // to release a possibly unrelated allocation or lease.
                    if (err == error.Descriptor) return err;
                    self.host_rejected = err; self.state = .unwinding;
                };
                return null;
            }
            var index: u16 = 0;
            const operation: wire.Operation = if (self.state == .creating) blk: {
                if (!self.allocated) break :blk .allocate;
                if (self.registered == self.mapped) {
                    index = self.registered;
                    const gathered = self.gather(index) catch |err| {
                        self.host_rejected = err; self.state = .unwinding;
                        return null;
                    };
                    if (!gathered) return null;
                    break :blk .register;
                }
                index = self.mapped;
                break :blk .map;
            } else if (self.mapped != 0) blk: {
                index = self.mapped - 1;
                break :blk .unmap;
            } else if (self.allocated) .free_virtual else if (self.registered != 0) blk: {
                index = self.registered - 1;
                break :blk .free_memory;
            } else {
                try self.closeBacking();
                self.state = if (self.state == .unwinding) .ready else .closed;
                return null;
            };
            const extent = self.part(index);
            const list = if (operation == .register) self.pages()[0..@intCast(extent.byte_length / 4096)] else &.{};
            const encoded = try wire.encodePart(try self.binding(index), extent, operation, list, self.address, self.request());
            try self.exchange.begin(encoded.function, encoded.bytes, self.deadline);
            self.operation = operation;
            self.operation_part = index;
            self.request_bytes = encoded.bytes.len;
        }
        const dispatch = (try self.exchange.poll(self.deadline)) orelse return null;
        if (!dispatch.response) return dispatch;
        const operation = self.operation.?;
        const reply = try wire.decodePart(try self.binding(self.operation_part), self.part(self.operation_part), operation,
            self.request()[0..self.request_bytes], dispatch.record, self.address);
        try self.exchange.complete(dispatch.ticket);
        if (reply == .rejected) {
            if (self.state != .creating) return error.FirmwareResult;
            self.rejected = reply.rejected;
            self.state = .unwinding;
        } else switch (operation) {
            .allocate => { self.allocated = true; self.address = reply.ok; },
            .register => { self.registered += 1; self.loaded_pages = 0; },
            .map => {
                self.mapped += 1;
                if (self.mapped == self.parts) {
                    self.state = .ready;
                    self.retainGpu() catch |err| {
                        if (err == error.Descriptor) return err;
                        self.host_rejected = err; self.state = .unwinding;
                    };
                }
            },
            .unmap => self.mapped -= 1,
            .free_virtual => { self.allocated = false; self.address = 0; },
            .free_memory => self.registered -= 1,
        }
        self.operation = null;
        return null;
    }
    fn retainGpu(self: *Owner) Error!void {
        const acquired = self.memory.deviceAcquire(&self.source.reference, &.{ .byte_length = self.mapped_bytes, .gpu_virtual_address = self.address,
            .adapter_id = self.adapter, .device_generation = self.space.epoch, .access = 3, .address_space = 1 }, &self.gpu);
        self.gpu_stamp = self.gpu;
        if (acquired != a.gfx_buffer_result_ok and self.gpu.lease.id == 0) return error.Map;
        if (!self.deviceValid(self.gpu, 3, self.address) or self.gpu.driver_owner != self.dma.driver_owner) return error.Descriptor;
        if (acquired != a.gfx_buffer_result_ok) return error.Map;
    }
    fn closeBacking(self: *Owner) Error!void {
        if (self.allocated or self.registered != 0 or self.mapped != 0 or self.operation != null or self.exchange.pending != null) return error.Retained;
        if (self.gpu.lease.id != 0) {
            if (self.memory.deviceRelease(&self.gpu, 1) != a.gfx_buffer_result_ok) return error.Retained;
            self.gpu = .{}; self.gpu_stamp = .{};
        }
        if (self.dma.lease.id != 0) {
            if (self.memory.deviceRelease(&self.dma, 1) != a.gfx_buffer_result_ok) return error.Retained;
            self.dma = .{}; self.dma_stamp = .{};
        }
        if (self.source.reference.id != 0) {
            if (self.memory.bufferRelease(&self.source.reference) != a.gfx_buffer_result_ok) return error.Retained;
            self.source = .{}; self.source_stamp = .{};
        }
        if (self.memory.collect() != a.gfx_buffer_result_ok) return error.Retained;
        if (self.allocation.handle != 0) {
            if (self.heap.release(self.allocation.handle) != a.driver_heap_ok) return error.Retained;
            self.allocation = .{}; self.allocation_stamp = .{};
        }
        if (self.namespace_live) {
            try self.exchange.session.rm_names.retireChildren(self.reservation);
            self.namespace_live = false;
        }
        self.prepared = false;
    }
    pub fn handoff(self: *Owner, deadline: u64) Error!boot.Handoff {
        try self.stable();
        if (self.state != .ready and self.state != .closed) return error.State;
        // Only an active registration needs the large page-list scratch.
        // All later destroy requests fit in this resident owner's small
        // buffer; live BO count therefore does not multiply 128KB scratch.
        if (self.allocation.handle != 0) {
            if (self.heap.release(self.allocation.handle) != a.driver_heap_ok) return error.Retained;
            self.allocation = .{}; self.allocation_stamp = .{};
        }
        const token = try self.exchange.handoff(deadline);
        self.state = if (self.state == .ready) .handed_off else .finished;
        return token;
    }
    /// Execution quiescence is supplied by the real engine/queue owner.
    /// Cancellation or CPU callback completion cannot substitute for it.
    pub fn beginDestroy(self: *Owner, token: *boot.Handoff, deadline: u64, quiesced: bool) Error!void {
        try self.stable();
        if (!quiesced) return error.Busy;
        if (self.state != .handed_off or token.session != self.exchange.session) return error.State;
        self.exchange = try exchange.Exchange.init(token, deadline);
        self.deadline = deadline;
        self.state = .destroying;
    }
    pub fn matches(self: *const Owner, current: *const exchange.Exchange, deadline: u64) bool {
        self.stable() catch return false;
        const operation = self.operation orelse return false;
        return self.self_address == @intFromPtr(self) and self.failure == null and self.namespace_live and
            (self.state == .creating or self.state == .unwinding or self.state == .destroying) and
            current == &self.exchange and current.phase == .prepared and current.pending == null and
            current.deadline == deadline and self.deadline == deadline and current.session.epoch == self.space.epoch and
            current.request.ptr == self.request().ptr and current.request.len == self.request_bytes and current.function == wire.function(operation);
    }
};
fn handleValid(value: a.GfxBufferHandle) bool {
    return value.id != 0 and value.generation != 0 and value.reserved0 == 0;
}
