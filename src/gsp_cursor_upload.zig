//! Cursor image upload uses the existing graph staging BO and CE channel.
//! Each part has its own real device-read lease and CE completion. The source
//! CPU-read map/import remains owned until all parts finish or safe cancel.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const image = @import("gsp_cursor_image.zig");
const control = @import("gsp_control_buffer.zig");
const backing = @import("gsp_native_backing.zig");
const copy = @import("gsp_copy_ring.zig");
pub const Phase = enum { preparing, prepared, submitted, complete, failed };
pub const Upload = struct {
    self_address: usize = 0,
    source: ?*control.Owner = null,
    source_stamp: ?control.Info = null,
    target: ?*backing.Use = null,
    target_stamp: ?backing.Source = null,
    input_memory: ?r4os.driver_memory.Context = null,
    input: a.GfxBufferReference = .{},
    input_stamp: a.GfxBufferReference = .{},
    pixels: a.GfxBufferMap = .{},
    pixels_stamp: a.GfxBufferMap = .{},
    cpu: a.GfxBufferMap = .{},
    gpu: a.GfxDeviceLease = .{},
    gpu_stamp: a.GfxDeviceLease = .{},
    plan: image.Plan = undefined,
    plan_stamp: image.Plan = undefined,
    target_offset: u64 = 0,
    target_offset_stamp: u64 = 0,
    completed_bytes: u64 = 0,
    part_bytes: u64 = 0,
    deadline: u64 = 0,
    phase: Phase = .preparing,
    ticket: ?copy.Ticket = null,
    last_point: u32 = 0,
    failure: ?anyerror = null,

    pub fn open(self: *Upload, memory: r4os.driver_memory.Context, reference: a.GfxBufferHandle, plan: image.Plan, source: *control.Owner,
        target: *backing.Use, offset: u64, deadline: u64) !void
    {
        if (self.self_address != 0) return error.Busy;
        const src = source.info() orelse return error.Stale;
        const dst = target.info() orelse return error.Stale;
        if (!plan.valid() or src.bytes < 4096 or src.bytes & 3 != 0 or src.epoch != dst.epoch or source.adapter != dst.adapter or
            src.address > std.math.maxInt(u64) - src.bytes or dst.address > std.math.maxInt(u64) - dst.bytes or
            offset & 255 != 0 or offset >= dst.bytes or plan.bytes() > dst.bytes - offset or
            src.address < dst.address + dst.bytes and dst.address < src.address + src.bytes or
            deadline == 0 or deadline == std.math.maxInt(u64)) return error.Bounds;
        self.* = .{ .self_address = @intFromPtr(self), .source = source, .source_stamp = src, .target = target, .target_stamp = dst, .input_memory = memory,
            .plan = plan, .plan_stamp = plan, .target_offset = offset, .target_offset_stamp = offset, .deadline = deadline };
        self.acquireInput(reference) catch |err| {
            if (err == error.Descriptor) { self.quarantine(err); return err; }
            if (!self.release()) { self.quarantine(error.Retained); return error.Retained; }
            self.* = .{}; return err;
        };
    }
    fn acquireInput(self: *Upload, reference: a.GfxBufferHandle) !void {
        const memory = self.input_memory.?;
        const result = memory.bufferImport(&reference, &self.input);
        self.input_stamp = self.input;
        if (result != a.gfx_buffer_result_ok) return error.Memory;
        if (self.input.version != 1 or self.input.size < @sizeOf(a.GfxBufferReference) or self.input.flags & ~a.gfx_buffer_reference_immutable != 0 or self.input.reserved0 != 0 or
            !validHandle(self.input.reference) or !validHandle(self.input.buffer) or std.meta.eql(self.input.reference, reference)) return error.Descriptor;
        var d: a.GfxBufferDescriptor = .{};
        if (memory.bufferDescribe(&self.input.reference, &d) != a.gfx_buffer_result_ok) return error.Memory;
        if (d.version != 1 or d.size < @sizeOf(a.GfxBufferDescriptor) or d.location != a.gfx_buffer_location_system or
            d.adapter_id != 0 or d.device_generation != 0 or d.modifier != 0 or d.plane_count != 1 or d.plane_offsets[0] != 0 or
            d.format != a.gfx_buffer_format_argb8888 or d.width != self.plan.width or d.height != self.plan.height or
            d.plane_pitches[0] != self.plan.pitch or d.byte_length != self.plan.source_bytes or d.usage & a.gfx_buffer_usage_cpu_read == 0) return error.Descriptor;
        const mapped = memory.bufferMap(&self.input.reference, a.gfx_buffer_map_read, 0, d.byte_length, &self.pixels);
        self.pixels_stamp = self.pixels;
        if (mapped != a.gfx_buffer_result_ok) return error.Map;
        try validateMap(self.pixels, d.byte_length, 4);
    }
    pub fn valid(self: *const Upload) bool {
        return self.self_address == @intFromPtr(self) and self.failure == null and self.source != null and self.target != null and
            std.meta.eql(self.source.?.info(), self.source_stamp) and std.meta.eql(self.target.?.info(), self.target_stamp) and
            std.meta.eql(self.input, self.input_stamp) and validHandle(self.input.reference) and
            std.meta.eql(self.pixels, self.pixels_stamp) and validHandle(self.pixels.lease) and
            self.plan.valid() and std.meta.eql(self.plan, self.plan_stamp) and self.target_offset == self.target_offset_stamp and
            self.completed_bytes < self.plan.bytes() and self.completed_bytes & 3 == 0 and std.meta.eql(self.gpu, self.gpu_stamp);
    }
    pub fn prepare(self: *Upload) !void {
        if (!self.valid() or self.phase != .preparing or self.ticket != null or self.cpu.lease.id != 0 or self.gpu.lease.id != 0) return error.State;
        const memory = self.source.?.backing.memory.?;
        const reference = self.source.?.backing.reference.reference;
        self.part_bytes = @min(self.source_stamp.?.bytes, self.plan.bytes() - self.completed_bytes);
        const mapped = memory.bufferMap(&reference, a.gfx_buffer_map_write, 0, self.source_stamp.?.bytes, &self.cpu);
        if (mapped != a.gfx_buffer_result_ok) return error.Map;
        try validateMap(self.cpu, self.source_stamp.?.bytes, 4096);
        const src: [*]const u8 = @ptrFromInt(self.pixels.cpu_address);
        const dst: [*]u8 = @ptrFromInt(self.cpu.cpu_address);
        try image.pack(self.plan, src[0..@intCast(self.pixels.byte_length)], self.completed_bytes, dst[0..@intCast(self.part_bytes)]);
        if (memory.bufferUnmap(&self.cpu.lease) != a.gfx_buffer_result_ok) return error.Retained;
        self.cpu = .{};
        const acquired = memory.deviceAcquire(&reference, &.{ .byte_length = self.part_bytes,
            .gpu_virtual_address = self.source_stamp.?.address, .adapter_id = self.source.?.adapter,
            .device_generation = self.source_stamp.?.epoch, .access = 0, .address_space = 1 }, &self.gpu);
        self.gpu_stamp = self.gpu;
        if (acquired != a.gfx_buffer_result_ok) return error.Memory;
        const gpu = self.gpu;
        if (gpu.version != 1 or gpu.size < @sizeOf(a.GfxDeviceLease) or !validHandle(gpu.lease) or gpu.byte_offset != 0 or
            gpu.byte_length != self.part_bytes or gpu.gpu_virtual_address != self.source_stamp.?.address or
            gpu.device_generation != self.source_stamp.?.epoch or gpu.adapter_id != self.source.?.adapter or gpu.driver_owner != self.target_stamp.?.driver_owner or
            gpu.access != 0 or gpu.address_space != 1 or gpu.dma_mask != std.math.maxInt(u64)) return error.Descriptor;
        self.phase = .prepared;
    }
    pub fn transfer(self: *const Upload) !copy.wire.Transfer {
        if (!self.valid() or self.phase != .prepared or self.cpu.lease.id != 0 or !validHandle(self.gpu.lease) or
            self.part_bytes != @min(self.source_stamp.?.bytes, self.plan.bytes() - self.completed_bytes)) return error.Stale;
        return .{ .source = self.source_stamp.?.address, .target = self.target_stamp.?.address + self.target_offset + self.completed_bytes, .bytes = self.part_bytes };
    }
    pub fn matches(self: *const Upload, ticket: copy.Ticket, deadline: u64) bool {
        return self.valid() and self.phase == .prepared and self.deadline == deadline and self.ticket != null and std.meta.eql(self.ticket.?, ticket);
    }
    pub fn submitted(self: *Upload, ticket: copy.Ticket) !void {
        if (!self.matches(ticket, self.deadline)) return error.Stale;
        self.phase = .submitted;
    }
    pub fn complete(self: *Upload, point: u32) !void {
        if (!self.valid() or self.phase != .submitted or self.ticket == null or point < self.ticket.?.point) return error.Stale;
        if (self.source.?.backing.memory.?.deviceRelease(&self.gpu, 1) != a.gfx_buffer_result_ok) return error.Retained;
        self.gpu = .{}; self.gpu_stamp = .{};
        self.completed_bytes += self.part_bytes; self.last_point = self.ticket.?.point; self.ticket = null; self.part_bytes = 0;
        if (self.completed_bytes == self.plan.bytes()) {
            if (!self.release()) return error.Retained;
            self.phase = .complete;
        } else self.phase = .preparing;
    }
    pub fn cancel(self: *Upload) !void {
        if (self.phase == .submitted or self.ticket != null) return error.State;
        if (!self.release()) return error.Retained;
        self.phase = .complete;
    }
    fn release(self: *Upload) bool {
        const memory = self.source.?.backing.memory.?;
        if (self.gpu.lease.id != 0) { if (memory.deviceRelease(&self.gpu, 1) != a.gfx_buffer_result_ok) return false; self.gpu = .{}; self.gpu_stamp = .{}; }
        if (self.cpu.lease.id != 0) { if (memory.bufferUnmap(&self.cpu.lease) != a.gfx_buffer_result_ok) return false; self.cpu = .{}; }
        if (self.pixels.lease.id != 0) { if (self.input_memory.?.bufferUnmap(&self.pixels.lease) != a.gfx_buffer_result_ok) return false; self.pixels = .{}; self.pixels_stamp = .{}; }
        if (self.input.reference.id != 0) { if (self.input_memory.?.bufferRelease(&self.input.reference) != a.gfx_buffer_result_ok) return false; self.input = .{}; self.input_stamp = .{}; }
        return true;
    }
    pub fn quarantine(self: *Upload, err: anyerror) void { self.failure = err; self.phase = .failed; }
};
fn validHandle(h: a.GfxBufferHandle) bool { return h.id != 0 and h.generation != 0 and h.reserved0 == 0; }
fn validateMap(cpu: a.GfxBufferMap, bytes: u64, alignment: u64) !void {
    if (cpu.version != 1 or cpu.size < @sizeOf(a.GfxBufferMap) or !validHandle(cpu.lease) or cpu.cpu_address == 0 or
        cpu.cpu_address % alignment != 0 or cpu.byte_length != bytes or cpu.cpu_address > std.math.maxInt(u64) - bytes or
        cpu.cache_policy != a.gfx_buffer_cache_write_back or cpu.reserved0 != 0) return error.Descriptor;
}
