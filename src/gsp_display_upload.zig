//! Private display-table upload through the existing CE and graph staging
//! allocation. Logical table publication follows GPU release completion.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const tables = @import("gsp_display_table.zig");
const control = @import("gsp_control_buffer.zig");
const backing = @import("gsp_native_backing.zig");
const copy = @import("gsp_copy_ring.zig");
pub const Error = tables.Error || backing.Error || error{Memory, Map, Descriptor, Retained, State};
pub const Phase = enum { preparing, prepared, submitted, complete, failed };
pub const Upload = struct {
    self_address: usize = 0,
    table: ?*tables.Table = null,
    source: ?*control.Owner = null,
    source_stamp: ?control.Info = null,
    target: ?*backing.Use = null,
    target_stamp: ?backing.Source = null,
    cpu: a.GfxBufferMap = .{},
    gpu: a.GfxDeviceLease = .{},
    gpu_stamp: a.GfxDeviceLease = .{},
    revision: u64 = 0,
    change_stamp: ?tables.Change = null,
    part: u8 = 0,
    completed_parts: u8 = 0,
    deadline: u64 = 0,
    phase: Phase = .preparing,
    ticket: ?copy.Ticket = null,
    failure: ?anyerror = null,

    pub fn open(self: *Upload, table: *tables.Table, source: *control.Owner, target: *backing.Use, deadline: u64) Error!void {
        if (self.self_address != 0) return error.Busy;
        const src = source.info() orelse return error.Stale;
        const dst = target.info() orelse return error.Stale;
        if (!table.valid() or table.epoch != src.epoch or table.epoch != dst.epoch or
            source.binding.space.client != table.client or source.adapter != dst.adapter or
            src.bytes < tables.image_bytes or dst.bytes != 65536 or dst.physical.bytes != 65536 or
            deadline == 0 or deadline == std.math.maxInt(u64)) return error.Bounds;
        if (src.address < dst.address + dst.bytes and dst.address < src.address + src.bytes) return error.Bounds;
        _ = try table.beginUpload();
        self.* = .{ .self_address = @intFromPtr(self), .table = table, .source = source, .source_stamp = src,
            .target = target, .target_stamp = dst, .revision = table.revision, .change_stamp = table.change, .deadline = deadline };
        self.prepare() catch |err| {
            if (err == error.Descriptor or err == error.Retained) { self.quarantine(err); return err; }
            if (!self.release()) { self.quarantine(error.Retained); return error.Retained; }
            try table.cancelUpload(self.revision); self.* = .{}; return err;
        };
    }
    fn prepare(self: *Upload) Error!void {
        const source = self.source.?;
        const memory = source.backing.memory.?;
        const reference = source.backing.reference.reference;
        const mapped = memory.bufferMap(&reference, a.gfx_buffer_map_write, 0, self.source_stamp.?.bytes, &self.cpu);
        if (mapped != a.gfx_buffer_result_ok and self.cpu.lease.id == 0) return error.Map;
        const cpu = self.cpu;
        if (cpu.version != 1 or cpu.size < @sizeOf(a.GfxBufferMap) or !validHandle(cpu.lease) or
            cpu.cpu_address == 0 or cpu.cpu_address & 4095 != 0 or cpu.byte_length != self.source_stamp.?.bytes or
            cpu.cpu_address > std.math.maxInt(u64) - cpu.byte_length or cpu.cache_policy != a.gfx_buffer_cache_write_back or cpu.reserved0 != 0) return error.Descriptor;
        if (mapped != a.gfx_buffer_result_ok) return error.Map;
        const ptr: [*]u8 = @ptrFromInt(cpu.cpu_address);
        @memset(ptr[0..@intCast(cpu.byte_length)], 0);
        @memcpy(ptr[0..tables.image_bytes], &self.table.?.image);
        if (memory.bufferUnmap(&cpu.lease) != a.gfx_buffer_result_ok) return error.Retained;
        self.cpu = .{};
        // Real device-read use excludes later CPU writers. Mapping residency
        // alone would keep pages alive without protecting the staged bytes.
        const acquired = memory.deviceAcquire(&reference, &.{ .byte_length = tables.image_bytes,
            .gpu_virtual_address = self.source_stamp.?.address, .adapter_id = source.adapter,
            .device_generation = self.table.?.epoch, .access = 0, .address_space = 1 }, &self.gpu);
        self.gpu_stamp = self.gpu;
        if (acquired != a.gfx_buffer_result_ok and self.gpu.lease.id == 0) return error.Memory;
        const gpu = self.gpu;
        if (gpu.version != 1 or gpu.size < @sizeOf(a.GfxDeviceLease) or !validHandle(gpu.lease) or gpu.byte_offset != 0 or
            gpu.byte_length != tables.image_bytes or gpu.gpu_virtual_address != self.source_stamp.?.address or
            gpu.device_generation != self.table.?.epoch or gpu.adapter_id != source.adapter or gpu.driver_owner != self.target_stamp.?.driver_owner or
            gpu.access != 0 or gpu.address_space != 1 or gpu.dma_mask != std.math.maxInt(u64)) return error.Descriptor;
        if (acquired != a.gfx_buffer_result_ok) return error.Memory;
        self.phase = .prepared;
    }
    pub fn valid(self: *const Upload) bool {
        return self.self_address == @intFromPtr(self) and self.failure == null and self.table != null and
            self.table.?.uploadingRevision(self.revision) and self.source != null and self.target != null and
            std.meta.eql(self.table.?.change, self.change_stamp) and self.part == self.completed_parts and self.part < self.table.?.uploadParts() and
            std.meta.eql(self.source.?.info(), self.source_stamp) and std.meta.eql(self.target.?.info(), self.target_stamp) and
            self.cpu.lease.id == 0 and self.gpu.lease.id != 0 and std.meta.eql(self.gpu, self.gpu_stamp);
    }
    pub fn transfer(self: *const Upload) Error!copy.wire.Transfer {
        if (!self.valid() or self.phase != .prepared) return error.Stale;
        const range = try self.table.?.uploadRange(self.part);
        return .{ .source = self.source_stamp.?.address + range.offset, .target = self.target_stamp.?.address + range.offset, .bytes = range.bytes };
    }
    pub fn matches(self: *const Upload, ticket: copy.Ticket, deadline: u64) bool {
        return self.valid() and self.phase == .prepared and self.deadline == deadline and self.ticket != null and std.meta.eql(self.ticket.?, ticket);
    }
    pub fn submitted(self: *Upload, ticket: copy.Ticket) Error!void {
        if (!self.matches(ticket, self.deadline)) return error.Stale;
        self.phase = .submitted;
    }
    pub fn complete(self: *Upload, point: u32) Error!void {
        if (!self.valid() or self.phase != .submitted or self.ticket == null or point < self.ticket.?.point) return error.Stale;
        // Caller reads the actual CE SYS-flush/semaphore completion. Neither
        // GPGet nor a copied cursor or elapsed deadline can call this path.
        if (self.part + 1 < self.table.?.uploadParts()) {
            self.completed_parts += 1; self.part = self.completed_parts; self.ticket = null; self.phase = .prepared;
            return;
        }
        if (!self.release()) { self.quarantine(error.Retained); return error.Retained; }
        try self.table.?.completeUpload(self.revision); self.phase = .complete;
    }
    pub fn cancel(self: *Upload) Error!void {
        if (!self.valid() or self.phase != .prepared or self.ticket != null) return error.State;
        if (!self.release()) { self.quarantine(error.Retained); return error.Retained; }
        try self.table.?.cancelUpload(self.revision); self.phase = .complete;
    }
    fn release(self: *Upload) bool {
        const memory = self.source.?.backing.memory.?;
        if (self.gpu.lease.id != 0) {
            if (memory.deviceRelease(&self.gpu, 1) != a.gfx_buffer_result_ok) return false;
            self.gpu = .{}; self.gpu_stamp = .{};
        }
        if (self.cpu.lease.id != 0) {
            if (memory.bufferUnmap(&self.cpu.lease) != a.gfx_buffer_result_ok) return false;
            self.cpu = .{};
        }
        return true;
    }
    pub fn quarantine(self: *Upload, err: anyerror) void {
        self.failure = err; self.phase = .failed;
        if (self.table) |table| table.failed = true;
        // Staging, target instance and outer graph stay retained. A CPU
        // shutdown never establishes that GPU accesses have stopped.
    }
};
fn validHandle(h: a.GfxBufferHandle) bool { return h.id != 0 and h.generation != 0 and h.reserved0 == 0; }
