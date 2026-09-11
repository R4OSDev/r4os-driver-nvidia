//! Resident GSP image plus one contiguous 32-KB boot/signature/metadata pack.
//! Inputs are borrowed, already-admitted immutable firmware until stage returns.
//! Nothing is submitted to the GPU. A future execution owner must establish
//! real quiescence before close, not infer it from an expired deadline.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const boot = @import("gsp_boot.zig");
const gsp = @import("gsp_dma.zig");
const radix = @import("gsp_radix.zig");
const wpr = @import("gsp_wpr.zig");
const preflight = @import("fwsec_state.zig");
const layout = @import("gsp_layout.zig");
pub const signature_offset = boot.image.bytes;
pub const metadata_offset = signature_offset + wpr.signature_bytes;
pub const pack_bytes = metadata_offset + radix.page_bytes;
pub const Error = gsp.Error || wpr.Error || error{WrongBootSize};
pub const Sources = struct {
    chip_id: u16,
    raw: preflight.Raw,
    image: []const u8,
    boot_image: []const u8,
    descriptor: []const u8,
    signature: []const u8,
};
pub const Report = struct {
    image: gsp.Report,
    boot_address: u64,
    signature_address: u64,
    metadata_address: u64,
    metadata_bytes: usize = wpr.bytes,
    pack_bytes: usize = pack_bytes,
    pack_bounced: bool,
    app_version: u32 = 0,
};
pub const Storage = struct {
    context: ?r4os.r4dev.DriverContext = null,
    heap: ?r4os.r4dev.DriverHeapContext = null,
    clock: ?r4os.r4dev.DriverResourceContext = null,
    deadline: u64 = 0,
    last_clock: u64 = 0,
    image: gsp.Storage = .{},
    allocation: a.DriverHeapAllocation = .{},
    pin: a.DmaPinnedBuffer = .{},
    mapping: a.DmaMapping = .{},
    report: ?Report = null,
    execution_owner: usize = 0,
    vram_plan: ?layout.Plan = null,
    vram_owner: usize = 0,

    fn checkClock(self: *Storage) Error!u64 {
        const now = self.clock.?.nowNs();
        if (now == std.math.maxInt(u64)) return error.InvalidDeadline;
        if (now < self.last_clock) return error.ClockRegression;
        if (now >= self.deadline) return error.Timeout;
        self.last_clock = now;
        return now;
    }

    /// The caller admitted the complete GSP container, its selected signature
    /// and production boot image before calling this ownership layer. The small
    /// descriptor and first-boot profile are independently rechecked here.
    pub fn stageAdmitted(self: *Storage, ctx: *const r4os.r4dev.DriverContext, sources: *const Sources, timeout_ns: u64) Error!Report {
        if (self.context != null) return error.Busy;
        if (sources.boot_image.len != boot.image.bytes) return error.WrongBootSize;
        const input = wpr.Input{
            .chip_id = sources.chip_id,
            .raw = sources.raw,
            .image_bytes = sources.image.len,
            .descriptor = sources.descriptor,
            .signature_bytes = sources.signature.len,
        };
        const prepared = try wpr.prepare(&input);
        const boot_info = try boot.inspect(sources.descriptor, @intCast(sources.boot_image.len));
        if (!ctx.supportsDriverApi(19, @offsetOf(a.DriverApi, "dma_unpin_buffer") + @sizeOf(usize))) return error.Api;
        self.context = ctx.*;
        self.clock = ctx.resources() orelse return error.Api;
        self.last_clock = self.clock.?.nowNs();
        self.deadline = std.math.add(u64, self.last_clock, timeout_ns) catch return error.InvalidDeadline;
        if (timeout_ns == 0 or self.deadline == std.math.maxInt(u64)) return error.InvalidDeadline;
        self.heap = ctx.heap() orelse return error.Api;
        const now = try self.checkClock();
        const image = try self.image.stage(ctx, sources.image, self.deadline - now);
        _ = try self.checkClock();
        if (self.heap.?.allocate(pack_bytes, radix.page_bytes, &self.allocation) != a.driver_heap_ok) return error.Memory;
        const allocation = &self.allocation;
        if (allocation.handle == 0 or allocation.cpu_address == 0 or allocation.cpu_address & 4095 != 0 or
            allocation.byte_length != pack_bytes or allocation.alignment < radix.page_bytes or
            allocation.cpu_address > std.math.maxInt(u64) - pack_bytes) return error.Memory;
        _ = try self.checkClock();
        const data: [*]u8 = @ptrFromInt(allocation.cpu_address);
        const output = data[0..pack_bytes];
        @memset(output, 0);
        @memcpy(output[0..boot.image.bytes], sources.boot_image);
        @memcpy(output[signature_offset..metadata_offset], sources.signature);
        if (ctx.pinDmaConstBuffer(output, &self.pin) != 0) return error.Pin;
        if (self.pin.version != 1 or self.pin.size < @sizeOf(a.DmaPinnedBuffer) or self.pin.handle == 0 or
            self.pin.virt_addr != allocation.cpu_address or self.pin.bytes != pack_bytes or
            self.pin.page_count != pack_bytes / radix.page_bytes or self.pin.flags != 0 or self.pin.reserved != 0) return error.Descriptor;
        _ = try self.checkClock();
        const constraints = a.DmaConstraints{
            .dma_mask = radix.dma_mask,
            .alignment = radix.page_bytes,
            .max_segment_bytes = pack_bytes,
            .max_segments = 1,
            .flags = a.dma_flag_coherent | a.dma_flag_allow_bounce,
        };
        if (ctx.mapDmaPinned(&self.pin, &constraints, a.dma_direction_to_device, &self.mapping) != 0) return error.Map;
        const map = &self.mapping;
        if (map.version != 1 or map.size < @sizeOf(a.DmaMapping) or map.handle == 0 or map.pin_handle != self.pin.handle or
            map.requested_bytes != pack_bytes or map.mapped_bytes != pack_bytes or map.direction != a.dma_direction_to_device or
            map.segment_count != 1 or map.reserved0 != 0 or map.reserved1 != 0 or
            (map.flags & ~a.dma_mapping_flag_bounced) != constraints.flags or
            map.segments[0].reserved != 0 or map.segments[0].bytes != pack_bytes) return error.Descriptor;
        const address = map.segments[0].phys_addr;
        if (address == 0 or address > radix.dma_mask or pack_bytes - 1 > radix.dma_mask - address) return error.Address;
        if (address & (radix.page_bytes - 1) != 0) return error.Alignment;
        _ = try self.checkClock();
        // The metadata occupies the final page. Its span must also be disjoint
        // from every GSP data/table span, not just the boot/signature subranges.
        for (self.image.segments[0..self.image.segment_count]) |segment| {
            if (address < segment.address + segment.bytes and segment.address < address + pack_bytes) return error.Overlap;
        }
        const metadata = try wpr.encode(&input, &.{
            .gsp_segments = self.image.segments[0..self.image.segment_count],
            .boot_image = .{ .address = address, .bytes = boot.image.bytes },
            .signature = .{ .address = address + signature_offset, .bytes = wpr.signature_bytes },
        });
        @memcpy(output[metadata_offset..][0..metadata.len], &metadata);
        // Initial map may have copied the still-zero metadata page to bounce
        // backing. Explicit final synchronization must precede publication.
        if (ctx.syncDmaForDevice(map) != 0) return error.Synchronization;
        _ = try self.checkClock();
        self.report = .{
            .image = image,
            .boot_address = address,
            .signature_address = address + signature_offset,
            .metadata_address = address + metadata_offset,
            .pack_bounced = map.flags & a.dma_mapping_flag_bounced != 0,
            .app_version = boot_info.app_version,
        };
        self.vram_plan = prepared.plan;
        return self.report.?;
    }

    pub fn close(self: *Storage) bool {
        if (self.execution_owner != 0 or self.image.execution_owner != 0 or self.vram_owner != 0) return false;
        self.report = null;
        self.vram_plan = null;
        const ctx = self.context orelse return self.allocation.handle == 0 and self.image.context == null;
        // Close the pack that points at GSP first. Each allocation retains its
        // exact mapping/pin/CPU lifetime; partial failure prevents later release.
        if (self.mapping.handle != 0) {
            var descriptor = self.mapping;
            if (ctx.unmapDma(&descriptor) != 0) return false;
            self.mapping = .{};
        }
        if (self.pin.handle != 0) {
            var descriptor = self.pin;
            if (ctx.unpinDmaBuffer(&descriptor) != 0) return false;
            self.pin = .{};
        }
        if (self.allocation.handle != 0) {
            const heap = self.heap orelse return false;
            if (heap.release(self.allocation.handle) != a.driver_heap_ok) return false;
            self.allocation = .{};
        }
        if (!self.image.close()) return false;
        self.* = .{};
        return true;
    }
};
