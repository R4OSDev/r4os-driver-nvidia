//! Small driver-owned shader/descriptor/vertex uploads over the existing CE.
//! Uses the graph staging BO with a real read lease after its CPU map closes.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const cache = @import("gsp_render_cache.zig");
const control = @import("gsp_control_buffer.zig");
const storage = @import("gsp_native_backing.zig");
const copy = @import("gsp_push_ring.zig");
const render = @import("r4nv_render");
pub const Owner = struct {
    self_address: usize = 0,
    cache_owner: ?*cache.Owner = null,
    kind: cache.Kind = .programs,
    source: ?*control.Owner = null,
    source_stamp: ?control.Info = null,
    target: ?*storage.Use = null,
    target_stamp: ?storage.Source = null,
    cpu: a.GfxBufferMap = .{},
    cpu_stamp: a.GfxBufferMap = .{},
    gpu: a.GfxDeviceLease = .{},
    gpu_stamp: a.GfxDeviceLease = .{},
    bytes: u64 = 0,
    deadline: u64 = 0,
    ticket: ?copy.Ticket = null,
    submitted: bool = false,
    failed: bool = false,
    failure: ?anyerror = null,

    pub fn open(self: *Owner, programs: *cache.Owner, source: *control.Owner, kind: cache.Kind, draw: ?render.Draw, deadline: u64) !void {
        if (self.self_address != 0 or !programs.valid() or programs.borrowed or programs.uploading != null) return error.Busy;
        const src = source.info() orelse return error.Stale;
        const target = programs.buffer(kind);
        const dst = target.info() orelse return error.Stale;
        const bytes: u64 = if (kind == .programs) render.shader_bytes else render.packet_bytes;
        if (src.epoch != programs.epoch or dst.epoch != programs.epoch or src.bytes < bytes or dst.bytes < bytes or
            source.adapter != dst.adapter or deadline == 0 or deadline == std.math.maxInt(u64) or
            render.Range.overlaps(.{ .address = src.address, .bytes = src.bytes }, .{ .address = dst.address, .bytes = dst.bytes })) return error.Bounds;
        self.* = .{ .self_address = @intFromPtr(self), .cache_owner = programs, .kind = kind, .source = source, .source_stamp = src,
            .target = target, .target_stamp = dst, .bytes = bytes, .deadline = deadline };
        self.prepare(draw) catch |err| {
            self.failure = err;
            if (err == error.Descriptor or err == error.Retained or !self.release()) { self.failed = true; return error.Retained; }
            if (programs.uploading != null) try programs.cancelUpload();
            self.* = .{}; return err;
        };
    }
    fn prepare(self: *Owner, draw: ?render.Draw) !void {
        const memory = self.source.?.backing.memory.?;
        const reference = self.source.?.backing.reference.reference;
        const mapped = memory.bufferMap(&reference, a.gfx_buffer_map_write, 0, self.source_stamp.?.bytes, &self.cpu);
        self.cpu_stamp = self.cpu;
        if (mapped != a.gfx_buffer_result_ok and self.cpu.lease.id == 0) return error.Map;
        const cpu = self.cpu;
        if (cpu.version != 1 or cpu.size < @sizeOf(a.GfxBufferMap) or !valid(cpu.lease) or cpu.cpu_address == 0 or
            cpu.cpu_address & 4095 != 0 or cpu.byte_length != self.source_stamp.?.bytes or cpu.cpu_address > std.math.maxInt(u64) - cpu.byte_length or
            cpu.cache_policy != a.gfx_buffer_cache_write_back or cpu.reserved0 != 0) return error.Descriptor;
        if (mapped != a.gfx_buffer_result_ok) return error.Map;
        const ptr: [*]u8 = @ptrFromInt(cpu.cpu_address);
        try self.cache_owner.?.beginUpload(self.kind,draw,ptr[0..@intCast(self.bytes)]);
        if (memory.bufferUnmap(&cpu.lease) != a.gfx_buffer_result_ok) return error.Retained;
        self.cpu = .{}; self.cpu_stamp = .{};
        const acquired = memory.deviceAcquire(&reference, &.{ .byte_length = self.bytes, .gpu_virtual_address = self.source_stamp.?.address,
            .adapter_id = self.source.?.adapter, .device_generation = self.cache_owner.?.epoch, .access = 0, .address_space = 1 }, &self.gpu);
        self.gpu_stamp = self.gpu;
        if (acquired != a.gfx_buffer_result_ok and self.gpu.lease.id == 0) return error.Memory;
        const gpu = self.gpu;
        if (gpu.version != 1 or gpu.size < @sizeOf(a.GfxDeviceLease) or !valid(gpu.lease) or gpu.byte_offset != 0 or gpu.byte_length != self.bytes or
            gpu.gpu_virtual_address != self.source_stamp.?.address or gpu.adapter_id != self.source.?.adapter or gpu.device_generation != self.cache_owner.?.epoch or
            gpu.driver_owner != self.target_stamp.?.driver_owner or gpu.access != 0 or gpu.address_space != 1 or gpu.dma_mask != std.math.maxInt(u64)) return error.Descriptor;
        if (acquired != a.gfx_buffer_result_ok) return error.Memory;
    }
    pub fn validState(self: *const Owner) bool {
        return self.self_address == @intFromPtr(self) and !self.failed and self.cache_owner != null and self.cache_owner.?.valid() and
            self.cache_owner.?.uploading == self.kind and !self.cache_owner.?.borrowed and self.source != null and self.target != null and
            std.meta.eql(self.source.?.info(),self.source_stamp) and std.meta.eql(self.target.?.info(),self.target_stamp) and
            self.cpu.lease.id == 0 and self.gpu.lease.id != 0 and std.meta.eql(self.gpu,self.gpu_stamp);
    }
    pub fn transfer(self: *const Owner) !copy.wire.Transfer {
        if (!self.validState()) return error.Stale;
        return .{ .source = self.source_stamp.?.address, .target = self.target_stamp.?.address, .bytes = self.bytes };
    }
    pub fn matches(self: *const Owner, ticket: copy.Ticket, deadline: u64) bool {
        return self.validState() and !self.submitted and self.deadline == deadline and self.ticket != null and std.meta.eql(self.ticket.?,ticket);
    }
    pub fn complete(self: *Owner, point: u32) !void {
        if (!self.validState() or !self.submitted or self.ticket == null or point < self.ticket.?.point) return error.State;
        if (!self.release()) { self.failed = true; return error.Retained; }
        try self.cache_owner.?.completeUpload(self.kind,self.ticket.?.point);
        self.* = .{};
    }
    pub fn cancel(self: *Owner) !void {
        if (!self.validState() or self.submitted or self.ticket != null) return error.State;
        if (!self.release()) { self.failed = true; return error.Retained; }
        try self.cache_owner.?.cancelUpload(); self.* = .{};
    }
    fn release(self: *Owner) bool {
        if (!std.meta.eql(self.gpu,self.gpu_stamp) or !std.meta.eql(self.cpu,self.cpu_stamp)) return false;
        const memory = self.source.?.backing.memory.?;
        if (self.gpu.lease.id != 0) {
            if (memory.deviceRelease(&self.gpu,1) != a.gfx_buffer_result_ok) return false;
            self.gpu = .{}; self.gpu_stamp = .{};
        }
        if (self.cpu.lease.id != 0) {
            if (memory.bufferUnmap(&self.cpu.lease) != a.gfx_buffer_result_ok) return false;
            self.cpu = .{}; self.cpu_stamp = .{};
        }
        return true;
    }
};
fn valid(h: a.GfxBufferHandle) bool { return h.id != 0 and h.generation != 0 and h.reserved0 == 0; }
