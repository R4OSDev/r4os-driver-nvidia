//! Private display-table upload through the existing CE and graph staging
//! allocation. Logical table publication follows GPU release completion.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const tables = @import("gsp_display_table.zig");
const control = @import("gsp_control_buffer.zig");
const backing = @import("gsp_native_backing.zig");
const identity = @import("gsp_display_identity_lut.zig");
const copy = @import("gsp_push_ring.zig");
pub const Error = tables.Error || backing.Error || error{ Memory, Map, Descriptor, Retained, State, DiagnosticReadback };
pub const Phase = enum { preparing, prepared, submitted, complete, failed };
pub const Upload = struct {
    self_address: usize = 0,
    purpose: enum { table, identity_lut } = .table,
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
    // Temporary N265 diagnosis: read the exact device instance into the
    // existing poisoned staging range before publishing a new cursor DMA.
    // Uses the same CE, original deadline and explicit write lease.
    readback_requested: bool = false,
    readback_started: bool = false,
    readback_verified: bool = false,
    readback_actual_crc: u32 = 0,
    readback_expected_crc: u32 = 0,
    readback_difference: ?u32 = null,

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
        self.* = .{ .self_address = @intFromPtr(self), .table = table, .source = source, .source_stamp = src, .target = target, .target_stamp = dst, .revision = table.revision, .change_stamp = table.change, .deadline = deadline };
        self.prepare() catch |err| {
            if (err == error.Descriptor or err == error.Retained) {
                self.quarantine(err);
                return err;
            }
            if (!self.release()) {
                self.quarantine(error.Retained);
                return error.Retained;
            }
            try table.cancelUpload(self.revision);
            self.* = .{};
            return err;
        };
    }
    pub fn openIdentity(self: *Upload, source: *control.Owner, target: *backing.Use, deadline: u64) Error!void {
        if (self.self_address != 0) return error.Busy;
        const src = source.info() orelse return error.Stale;
        const dst = target.info() orelse return error.Stale;
        if (src.epoch != dst.epoch or source.adapter != dst.adapter or src.bytes < identity.bytes or
            dst.bytes != identity.allocation_bytes or dst.physical.bytes != identity.allocation_bytes or
            deadline == 0 or deadline == std.math.maxInt(u64)) return error.Bounds;
        if (src.address < dst.address + dst.bytes and dst.address < src.address + src.bytes) return error.Bounds;
        self.* = .{ .self_address = @intFromPtr(self), .purpose = .identity_lut,
            .source = source, .source_stamp = src, .target = target, .target_stamp = dst,
            .deadline = deadline, .readback_requested = true };
        self.prepare() catch |err| {
            if (err == error.Descriptor or err == error.Retained) { self.quarantine(err); return err; }
            if (!self.release()) { self.quarantine(error.Retained); return error.Retained; }
            self.* = .{}; return err;
        };
    }
    pub fn payloadBytes(self: *const Upload) usize {
        return if (self.purpose == .identity_lut) identity.bytes else tables.image_bytes;
    }
    fn parts(self: *const Upload) u8 {
        return if (self.purpose == .identity_lut) 1 else self.table.?.uploadParts();
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
        if (self.purpose == .identity_lut) {
            try identity.fill(ptr[0..@intCast(cpu.byte_length)]);
            self.readback_expected_crc = std.hash.Crc32.hash(ptr[0..identity.bytes]);
        } else @memcpy(ptr[0..tables.image_bytes], &self.table.?.image);
        if (memory.bufferUnmap(&cpu.lease) != a.gfx_buffer_result_ok) return error.Retained;
        self.cpu = .{};
        try self.acquire(0);
        self.phase = .prepared;
    }
    fn acquire(self: *Upload, access: u32) Error!void {
        const source = self.source.?;
        const memory = source.backing.memory.?;
        const reference = source.backing.reference.reference;
        // Real device use excludes incompatible CPU or execution writers.
        // Mapping residency alone does not protect the staged bytes.
        const acquired = memory.deviceAcquire(&reference, &.{ .byte_length = self.payloadBytes(), .gpu_virtual_address = self.source_stamp.?.address, .adapter_id = source.adapter, .device_generation = self.source_stamp.?.epoch, .access = access, .address_space = 1 }, &self.gpu);
        self.gpu_stamp = self.gpu;
        if (acquired != a.gfx_buffer_result_ok and self.gpu.lease.id == 0) return error.Memory;
        const gpu = self.gpu;
        if (gpu.version != 1 or gpu.size < @sizeOf(a.GfxDeviceLease) or !validHandle(gpu.lease) or gpu.byte_offset != 0 or
            gpu.byte_length != self.payloadBytes() or gpu.gpu_virtual_address != self.source_stamp.?.address or
            gpu.device_generation != self.source_stamp.?.epoch or gpu.adapter_id != source.adapter or gpu.driver_owner != self.target_stamp.?.driver_owner or
            gpu.access != access or gpu.address_space != 1 or gpu.dma_mask != std.math.maxInt(u64)) return error.Descriptor;
        if (acquired != a.gfx_buffer_result_ok) return error.Memory;
    }
    pub fn valid(self: *const Upload) bool {
        const payload_valid = if (self.purpose == .table) self.table != null and
            self.table.?.uploadingRevision(self.revision) and std.meta.eql(self.table.?.change, self.change_stamp)
            else self.table == null and self.revision == 0 and self.change_stamp == null and self.readback_requested;
        return self.self_address == @intFromPtr(self) and self.failure == null and payload_valid and
            self.source != null and self.target != null and self.part == self.completed_parts and self.part < self.parts() and
            (!self.readback_started or (self.readback_requested and self.part + 1 == self.parts())) and
            std.meta.eql(self.source.?.info(), self.source_stamp) and std.meta.eql(self.target.?.info(), self.target_stamp) and
            self.cpu.lease.id == 0 and self.gpu.lease.id != 0 and std.meta.eql(self.gpu, self.gpu_stamp);
    }
    pub fn transfer(self: *const Upload) Error!copy.wire.Transfer {
        if (!self.valid() or self.phase != .prepared) return error.Stale;
        if (self.readback_started) return .{ .source = self.target_stamp.?.address, .target = self.source_stamp.?.address, .bytes = self.payloadBytes() };
        if (self.purpose == .identity_lut) return .{ .source = self.source_stamp.?.address, .target = self.target_stamp.?.address, .bytes = identity.bytes };
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
        if (self.part + 1 < self.parts()) {
            self.completed_parts += 1;
            self.part = self.completed_parts;
            self.ticket = null;
            self.phase = .prepared;
            return;
        }
        if (self.readback_requested and !self.readback_started) {
            if (!self.release()) {
                self.quarantine(error.Retained);
                return error.Retained;
            }
            try self.prepareReadback();
            self.readback_started = true;
            self.ticket = null;
            self.phase = .prepared;
            return;
        }
        if (!self.release()) {
            self.quarantine(error.Retained);
            return error.Retained;
        }
        if (self.readback_started) try self.verifyReadback();
        if (self.table) |table| try table.completeUpload(self.revision);
        self.phase = .complete;
    }
    fn mapDiagnosis(self: *Upload, flags: u32) Error![*]u8 {
        const memory = self.source.?.backing.memory.?;
        const mapped = memory.bufferMap(&self.source.?.backing.reference.reference, flags, 0, self.source_stamp.?.bytes, &self.cpu);
        if (mapped != a.gfx_buffer_result_ok and self.cpu.lease.id == 0) return error.Map;
        const cpu = self.cpu;
        if (cpu.version != 1 or cpu.size < @sizeOf(a.GfxBufferMap) or !validHandle(cpu.lease) or
            cpu.cpu_address == 0 or cpu.cpu_address & 4095 != 0 or cpu.byte_length != self.source_stamp.?.bytes or
            cpu.cpu_address > std.math.maxInt(u64) - cpu.byte_length or cpu.cache_policy != a.gfx_buffer_cache_write_back or cpu.reserved0 != 0) return error.Descriptor;
        if (mapped != a.gfx_buffer_result_ok) return error.Map;
        return @ptrFromInt(cpu.cpu_address);
    }
    fn unmapDiagnosis(self: *Upload) Error!void {
        if (self.source.?.backing.memory.?.bufferUnmap(&self.cpu.lease) != a.gfx_buffer_result_ok) return error.Retained;
        self.cpu = .{};
    }
    fn prepareReadback(self: *Upload) Error!void {
        const bytes = try self.mapDiagnosis(a.gfx_buffer_map_write);
        // No previous expected bytes may satisfy the comparison if CE fails
        // to write. The independent resident table retains the expectation.
        @memset(bytes[0..self.payloadBytes()], 0xa5);
        try self.unmapDiagnosis();
        try self.acquire(1);
    }
    fn verifyReadback(self: *Upload) Error!void {
        const bytes = try self.mapDiagnosis(a.gfx_buffer_map_read);
        self.readback_actual_crc = std.hash.Crc32.hash(bytes[0..self.payloadBytes()]);
        if (self.purpose == .identity_lut) {
            self.readback_difference = try identity.firstDifference(bytes[0..identity.bytes]);
            try self.unmapDiagnosis();
            if (self.readback_difference != null or self.readback_actual_crc != self.readback_expected_crc) return error.DiagnosticReadback;
            self.readback_verified = true;
            return;
        }
        self.readback_expected_crc = std.hash.Crc32.hash(&self.table.?.image);
        // A finished removal withdraws only its RAMHT bucket; unreferenced
        // descriptor bytes may remain in VRAM. Compare the whole RAMHT and
        // every live exact descriptor, including its padding. No live byte
        // or pointer is excluded. The whole-image CRCs may differ only in
        // those legally retired, unreferenced descriptor slots.
        for (bytes[0..tables.image_bytes], &self.table.?.image, 0..) |actual, expected, index| {
            const live = index < tables.ramht_bytes or
                self.table.?.entries[(index - tables.ramht_bytes) / tables.descriptor_bytes] != null;
            if (live and actual != expected) {
                self.readback_difference = @intCast(index);
                break;
            }
        }
        try self.unmapDiagnosis();
        if (self.readback_difference != null) return error.DiagnosticReadback;
        self.readback_verified = true;
    }
    pub fn cancel(self: *Upload) Error!void {
        if (!self.valid() or self.phase != .prepared or self.ticket != null) return error.State;
        if (!self.release()) {
            self.quarantine(error.Retained);
            return error.Retained;
        }
        if (self.table) |table| try table.cancelUpload(self.revision);
        self.phase = .complete;
    }
    fn release(self: *Upload) bool {
        const memory = self.source.?.backing.memory.?;
        if (self.gpu.lease.id != 0) {
            if (memory.deviceRelease(&self.gpu, 1) != a.gfx_buffer_result_ok) return false;
            self.gpu = .{};
            self.gpu_stamp = .{};
        }
        if (self.cpu.lease.id != 0) {
            if (memory.bufferUnmap(&self.cpu.lease) != a.gfx_buffer_result_ok) return false;
            self.cpu = .{};
        }
        return true;
    }
    pub fn quarantine(self: *Upload, err: anyerror) void {
        self.failure = err;
        self.phase = .failed;
        if (self.table) |table| table.failed = true;
        // Staging, target instance and outer graph stay retained. A CPU
        // shutdown never establishes that GPU accesses have stopped.
    }
    pub fn closeAfterReset(self: *Upload, proof: @import("gsp_reset.zig").Quiescence) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.source == null or self.source_stamp == null or
            !proof.valid(self.source_stamp.?.epoch) or !std.meta.eql(self.gpu, self.gpu_stamp) or
            (self.failure != null and self.failure.? == error.Descriptor)) return false;
        if (!self.release()) return false;
        self.* = .{};
        return true;
    }
};
fn validHandle(h: a.GfxBufferHandle) bool {
    return h.id != 0 and h.generation != 0 and h.reserved0 == 0;
}
