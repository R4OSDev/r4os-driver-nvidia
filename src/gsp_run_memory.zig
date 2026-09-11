//! One execution lease over the complete prepared GSP/FWSEC DMA dependency
//! chain. Borrowing prevents independent cleanup before a native boot owner
//! binds MMIO/queues; retainForDevice must precede the first possible effect.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const gsp_dma = @import("gsp_dma.zig");
const boot = @import("gsp_boot_storage.zig");
const init = @import("gsp_init_storage.zig");
const security = @import("fwsec_storage.zig");
const booters = @import("booter_storage.zig");
const booter = @import("booter.zig");
const core = @import("gsp_core.zig");
const transport = @import("gsp_transport.zig");
const map_count = gsp_dma.max_mappings + 1 + init.max_mappings + 3;
const Stamp = struct { mapping: u64, pin: u64 };
pub const Inputs = struct {
    boot: boot.Report,
    init: init.Report,
    fwsec: @import("fwsec_load.zig").Plan,
    booters: [2]struct { prepared: booter.Prepared, plan: @import("fwsec_load.zig").Plan },
    resume_args: core.Resume,
};
pub const Lease = struct {
    self_address: usize = 0,
    api: ?*const a.DriverApi = null,
    boot_storage: ?*boot.Storage = null,
    init_storage: ?*init.Storage = null,
    fwsec_storage: ?*security.Storage = null,
    booter_storage: ?*booters.Pair = null,
    queue: init.QueueLease = .{},
    allocations: [6]u64 = @splat(0),
    mappings: [map_count]Stamp = undefined,
    mapped_count: usize = 0,
    retained: bool = false,
    failed: bool = false,

    fn allocationsFor(b: *boot.Storage, i: *init.Storage, f: *security.Storage, p: *booters.Pair) [6]a.DriverHeapAllocation {
        return .{ b.image.allocation, b.allocation, i.allocation, f.allocation, p.images[0].allocation, p.images[1].allocation };
    }
    fn mapsFor(b: *boot.Storage, i: *init.Storage, f: *security.Storage, p: *booters.Pair, out: *[map_count]*const a.DmaMapping) usize {
        var count: usize = 0;
        for (b.image.pieces[0..b.image.piece_count]) |*piece| {
            out[count] = &piece.mapping;
            count += 1;
        }
        out[count] = &b.mapping;
        count += 1;
        for (i.pieces[0..i.piece_count]) |*piece| {
            out[count] = &piece.mapping;
            count += 1;
        }
        out[count] = &f.device.mapping;
        count += 1;
        for (&p.images) |*image| {
            out[count] = &image.device.mapping;
            count += 1;
        }
        return count;
    }
    fn available(b: *boot.Storage, i: *init.Storage, f: *security.Storage, p: *booters.Pair, api: *const a.DriverApi) bool {
        if (b.execution_owner != 0 or b.image.execution_owner != 0 or i.execution_owner != 0 or f.device.execution_owner != 0) return false;
        if (b.report == null or b.image.report == null or i.report == null or !f.complete or f.device.prepared_plan == null) return false;
        if (b.context == null or b.image.context == null or i.context == null or f.device.context == null) return false;
        if (b.context.?.api != api or b.image.context.?.api != api or i.context.?.api != api or f.device.context.?.api != api) return false;
        if (!bootersMatch(p, api, 0)) return false;
        return b.image.piece_count > 0 and b.image.piece_count <= gsp_dma.max_mappings and
            i.piece_count == init.max_mappings and i.queue_epoch == 0 and !i.device_access;
    }
    fn bootersMatch(p: *const booters.Pair, api: *const a.DriverApi, owner: usize) bool {
        if (!p.complete or p.context == null or p.api != api or p.generation == 0) return false;
        for (&p.images, 0..) |*image, n| {
            if (image.prepared == null or image.device.prepared_plan == null or image.device.context == null or
                image.device.context.?.api != api or image.device.execution_owner != owner or
                @intFromEnum(image.prepared.?.operation) != n) return false;
        }
        return true;
    }
    /// All source owners must already have completed their own firmware,
    /// descriptor, size and synchronization admission. This adds common owner
    /// identity, disjoint CPU/DMA spans and an exclusive queue lease. No new
    /// allocation, engine operation, DMA submission or invented GPU address.
    pub fn acquire(self: *Lease, ctx: *const r4os.r4dev.DriverContext, b: *boot.Storage, i: *init.Storage, f: *security.Storage, p: *booters.Pair) !void {
        if (self.self_address != 0) return error.Busy;
        if (!available(b, i, f, p, ctx.api)) return error.Storage;
        const allocations = allocationsFor(b, i, f, p);
        for (allocations, 0..) |allocation, n| {
            if (allocation.handle == 0 or allocation.cpu_address == 0 or allocation.byte_length == 0 or
                allocation.cpu_address > std.math.maxInt(u64) - allocation.byte_length) return error.Allocation;
            for (allocations[n + 1 ..]) |other| {
                if (allocation.handle == other.handle) return error.Allocation;
                if (overlap(allocation.cpu_address, allocation.byte_length, other.cpu_address, other.byte_length)) return error.Overlap;
            }
        }
        var maps: [map_count]*const a.DmaMapping = undefined;
        const count = mapsFor(b, i, f, p, &maps);
        for (maps[0..count], 0..) |mapping, n| {
            if (mapping.handle == 0 or mapping.pin_handle == 0 or mapping.segment_count == 0 or mapping.segment_count > a.dma_max_segments) return error.Mapping;
            for (maps[n + 1 .. count]) |other| if (mapping.handle == other.handle or mapping.pin_handle == other.pin_handle) return error.Mapping;
            for (mapping.segments[0..mapping.segment_count]) |segment| {
                if (segment.phys_addr == 0 or segment.bytes == 0 or segment.phys_addr > std.math.maxInt(u64) - @as(u64, segment.bytes)) return error.Mapping;
                for (maps[n + 1 .. count]) |other| {
                    if (other.segment_count > a.dma_max_segments) return error.Mapping;
                    for (other.segments[0..other.segment_count]) |next| {
                        if (overlap(segment.phys_addr, segment.bytes, next.phys_addr, next.bytes)) return error.Overlap;
                    }
                }
            }
        }
        // borrowQueues performs the actual Kernel range-sync/owner check. It
        // has no fallible step after publishing its unique queue epoch.
        const queue = try i.borrowQueues();
        self.* = .{ .self_address = @intFromPtr(self), .api = ctx.api, .boot_storage = b, .init_storage = i, .fwsec_storage = f, .booter_storage = p, .queue = queue, .mapped_count = count };
        for (allocations, 0..) |allocation, n| self.allocations[n] = allocation.handle;
        for (maps[0..count], 0..) |mapping, n| self.mappings[n] = .{ .mapping = mapping.handle, .pin = mapping.pin_handle };
        b.execution_owner = self.self_address;
        b.image.execution_owner = self.self_address;
        i.execution_owner = self.self_address;
        f.device.execution_owner = self.self_address;
        for (&p.images) |*image| image.device.execution_owner = self.self_address;
    }
    fn overlap(left: u64, left_bytes: u64, right: u64, right_bytes: u64) bool {
        // Difference form also handles not-yet-validated following spans
        // without an overflow in the complete admission pass.
        return if (left >= right) left - right < right_bytes else right - left < left_bytes;
    }
    fn matches(self: *const Lease) bool {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.api == null or self.mapped_count > map_count) return false;
        const b = self.boot_storage orelse return false;
        const i = self.init_storage orelse return false;
        const f = self.fwsec_storage orelse return false;
        const p = self.booter_storage orelse return false;
        if (!bootersMatch(p, self.api.?, self.self_address)) return false;
        if (b.execution_owner != self.self_address or b.image.execution_owner != self.self_address or
            i.execution_owner != self.self_address or f.device.execution_owner != self.self_address) return false;
        if (b.context == null or b.image.context == null or i.context == null or f.device.context == null or
            b.context.?.api != self.api or b.image.context.?.api != self.api or i.context.?.api != self.api or f.device.context.?.api != self.api) return false;
        if (b.report == null or b.image.report == null or i.report == null or !f.complete or f.device.prepared_plan == null or
            b.image.piece_count == 0 or b.image.piece_count > gsp_dma.max_mappings or i.piece_count != init.max_mappings) return false;
        for (allocationsFor(b, i, f, p), self.allocations) |allocation, expected| if (allocation.handle != expected) return false;
        var maps: [map_count]*const a.DmaMapping = undefined;
        if (mapsFor(b, i, f, p, &maps) != self.mapped_count) return false;
        for (maps[0..self.mapped_count], self.mappings[0..self.mapped_count]) |mapping, stamp| {
            if (mapping.handle != stamp.mapping or mapping.pin_handle != stamp.pin) return false;
        }
        return self.queue.generation() != 0;
    }
    /// Shared run identity for queues and sequencer MMIO. This is an exclusive
    /// storage/run epoch, not a claim to have observed a hardware reset counter.
    /// Native lost-device/reset handling must invalidate the run immediately.
    pub fn generation(self: *const Lease) u64 {
        return if (!self.failed and self.matches()) self.queue.epoch else 0;
    }
    pub fn inputs(self: *const Lease) !Inputs {
        if (self.generation() == 0) return error.Stale;
        const b = self.boot_storage.?.report.?;
        const i = self.init_storage.?.report.?;
        var result: Inputs = .{ .boot = b, .init = i, .fwsec = self.fwsec_storage.?.device.prepared_plan.?, .booters = undefined, .resume_args = .{ .libos_dma = i.init.libos_address, .app_version = b.app_version } };
        for (&self.booter_storage.?.images, &result.booters) |*image, *input| input.* = .{ .prepared = image.prepared.?, .plan = image.device.prepared_plan.? };
        return result;
    }
    pub fn transportPort(self: *Lease) !transport.Port {
        if (self.generation() == 0) return error.Stale;
        return .{ .context = self, .generation = portGeneration, .now_ns = portClock, .read = portRead, .publish = portPublish };
    }
    pub fn retainForDevice(self: *Lease) !void {
        if (self.generation() == 0) return error.Stale;
        self.retained = true; // Before the underlying latch, even on failure.
        if (!self.queue.retainForDevice()) {
            self.failed = true;
            return error.Queue;
        }
    }
    pub fn invalidate(self: *Lease) void {
        self.failed = true;
    }
    /// Release only an unsubmitted run. There is deliberately no post-submit
    /// clear operation: native recovery/quiescence still has to be implemented
    /// and verified. Lost-device, timeout and INIT_DONE do not authorize reuse.
    pub fn releaseBeforeSubmission(self: *Lease) bool {
        if (self.self_address == 0) return true;
        if (self.retained or !self.matches()) return false;
        if (!self.queue.releaseBeforeSubmission()) return false;
        self.boot_storage.?.execution_owner = 0;
        self.boot_storage.?.image.execution_owner = 0;
        self.init_storage.?.execution_owner = 0;
        self.fwsec_storage.?.device.execution_owner = 0;
        for (&self.booter_storage.?.images) |*image| image.device.execution_owner = 0;
        self.* = .{};
        return true;
    }
    fn from(p: *anyopaque) *Lease {
        return @ptrCast(@alignCast(p));
    }
    fn portGeneration(p: *anyopaque) u64 {
        return from(p).generation();
    }
    fn portClock(p: *anyopaque) u64 {
        const self = from(p);
        if (self.generation() == 0) return std.math.maxInt(u64);
        return self.init_storage.?.clock.?.nowNs();
    }
    fn portRead(p: *anyopaque, queue: transport.ring.Queue, offset: usize, out: []u8) anyerror!void {
        const self = from(p);
        if (self.generation() == 0) return error.Stale;
        const port = self.queue.port();
        port.read(port.context, queue, offset, out) catch |err| {
            self.failed = true;
            return err;
        };
    }
    fn portPublish(p: *anyopaque, queue: transport.ring.Queue, offset: usize, bytes: []const u8) anyerror!void {
        const self = from(p);
        if (self.generation() == 0) return error.Stale;
        const port = self.queue.port();
        port.publish(port.context, queue, offset, bytes) catch |err| {
            self.failed = true;
            return err;
        };
    }
};
