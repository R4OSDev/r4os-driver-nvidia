//! Loaded-R4D Booter inputs and retained CPU/DMA images. No GPU execution.
//! Source parts remain bound to the GSP boot resource generation. Signatures
//! are installed into private writable image storage before mapping for DMA.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const firmware = @import("firmware.zig");
const resources = @import("firmware_resources.zig");
const booter = @import("booter.zig");
const dma = @import("fwsec_dma.zig");
const Context = r4os.r4dev.DriverResourceContext;
pub const Error = booter.Error || dma.Error || resources.Error || error{ Api, Busy, Memory, Resource, Generation, ShortRead, Timeout, ClockRegression, InvalidDeadline };
pub const Image = struct {
    heap: ?r4os.r4dev.DriverHeapContext = null,
    allocation: a.DriverHeapAllocation = .{},
    device: dma.Mapping = .{},
    metadata: [booter.metadata_bytes]u8 = @splat(0),
    prepared: ?booter.Prepared = null,

    fn stage(self: *Image, owner: *Pair, ctx: *const r4os.r4dev.DriverContext, operation: booter.Operation, chip_id: u16, fuses: booter.Fuses) Error!void {
        if (self.heap != null or self.allocation.handle != 0 or self.device.context != null) return error.Busy;
        const spec = booter.specification(operation);
        self.heap = ctx.heap() orelse return error.Api;
        if (self.heap.?.allocate(spec.image.bytes, 256, &self.allocation) != a.driver_heap_ok) return error.Memory;
        if (self.allocation.version != 1 or self.allocation.size < @sizeOf(a.DriverHeapAllocation) or self.allocation.reserved != 0 or
            self.allocation.handle == 0 or self.allocation.cpu_address == 0 or self.allocation.cpu_address & 255 != 0 or
            self.allocation.byte_length != spec.image.bytes or self.allocation.alignment < 256 or
            self.allocation.cpu_address > std.math.maxInt(u64) - spec.image.bytes) return error.Memory;
        const pointer: [*]u8 = @ptrFromInt(self.allocation.cpu_address);
        const image = pointer[0..spec.image.bytes];
        try owner.read(&spec.image, image);
        var parts: booter.Parts = undefined;
        parts.image = image;
        var offset: usize = 0;
        inline for (std.meta.fields(booter.Parts)) |field| {
            if (comptime !std.mem.eql(u8, field.name, "image")) {
                const artifact = &@field(spec.*, field.name);
                if (offset > self.metadata.len or artifact.bytes > self.metadata.len - offset) return error.Capacity;
                const slice = self.metadata[offset..][0..artifact.bytes];
                try owner.read(artifact, slice);
                @field(parts, field.name) = slice;
                offset += artifact.bytes;
            }
        }
        if (offset != self.metadata.len) return error.Size;
        const prepared = try booter.prepare(operation, chip_id, fuses, parts, image);
        try owner.checkClock();
        try self.device.stageImage(ctx, image);
        self.device.prepared_plan = try booter.loadPlan(prepared, self.device.mapping.segments[0].phys_addr, self.device.mapping.segments[0].bytes);
        try owner.checkClock();
        self.prepared = prepared;
    }
    pub fn close(self: *Image) bool {
        if (self.device.execution_owner != 0) return false;
        self.prepared = null;
        if (!self.device.close()) return false;
        if (self.allocation.handle != 0) {
            const heap = self.heap orelse return false;
            if (heap.release(self.allocation.handle) != a.driver_heap_ok) return false;
        }
        self.* = .{};
        return true;
    }
};
pub const Pair = struct {
    api: ?*const a.DriverApi = null,
    context: ?Context = null,
    images: [2]Image = .{ .{}, .{} },
    license: [firmware.lock.booter_license.artifact.bytes]u8 = @splat(0),
    generation: u64 = 0,
    deadline: u64 = 0,
    last_clock: u64 = 0,
    reads: usize = 0,
    complete: bool = false,

    pub fn stage(self: *Pair, ctx: *const r4os.r4dev.DriverContext, chip_id: u16, fuses: booter.Fuses, expected_generation: u64, timeout_ns: u64) Error!void {
        if (self.context != null) return error.Busy;
        if (chip_id != 0x176 or fuses.ucode_id != 3 or expected_generation == 0) return error.Profile;
        self.context = ctx.resources() orelse return error.Api;
        self.api = ctx.api;
        self.last_clock = self.context.?.nowNs();
        self.deadline = std.math.add(u64, self.last_clock, timeout_ns) catch return error.InvalidDeadline;
        if (timeout_ns == 0 or self.last_clock == 0 or self.deadline == std.math.maxInt(u64)) return error.InvalidDeadline;
        self.generation = try resources.validateLock(self.context.?, self.deadline);
        if (self.generation != expected_generation) return error.Generation;
        try self.read(&firmware.lock.booter_license.artifact, &self.license);
        try self.images[0].stage(self, ctx, .load, chip_id, fuses);
        try self.images[1].stage(self, ctx, .unload, chip_id, fuses);
        self.complete = true;
    }
    fn checkClock(self: *Pair) Error!void {
        const now = self.context.?.nowNs();
        if (now == std.math.maxInt(u64)) return error.InvalidDeadline;
        if (now < self.last_clock) return error.ClockRegression;
        if (now >= self.deadline) return error.Timeout;
        self.last_clock = now;
    }
    fn read(self: *Pair, spec: *const firmware.Artifact, output: []u8) Error!void {
        try self.checkClock();
        if (output.len != spec.bytes) return error.Size;
        var info: a.DriverResourceInfo = .{};
        if (self.context.?.stat(spec.resource, &info) != a.driver_resource_ok) return error.Resource;
        if (info.version != 1 or info.size < @sizeOf(a.DriverResourceInfo) or info.handle == 0 or info.byte_length != spec.bytes) return error.Size;
        if (info.module_generation != self.generation) return error.Generation;
        try self.checkClock();
        self.reads += 1;
        const count = self.context.?.readAt(info.handle, 0, output, self.deadline);
        if (count < 0) return error.Resource;
        if (count != output.len) return error.ShortRead;
        try self.checkClock();
        if (!firmware.digestMatches(output, spec.sha256)) return error.Hash;
        try self.checkClock();
    }
    pub fn close(self: *Pair) bool {
        // Both execution owners must permit release before mutating either
        // report. Partial preparation has no execution lease and closes in
        // reverse order, retaining exact handles on every failed release.
        for (&self.images) |*image| if (image.device.execution_owner != 0) return false;
        self.complete = false;
        var index = self.images.len;
        while (index != 0) {
            index -= 1;
            if (!self.images[index].close()) return false;
        }
        self.* = .{};
        return true;
    }
};
