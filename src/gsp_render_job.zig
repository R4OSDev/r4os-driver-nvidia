//! Retained image uses for one immutable graphics command. Storage remains
//! alive after producer close and until physical GR completion is observed.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const render = @import("r4nv_render");
const vram = @import("gsp_vram.zig");
const cache = @import("gsp_render_cache.zig");
pub const Resource = struct { info: vram.Info, driver_owner: u32 };
pub fn image(resource: Resource, target: bool) !render.image.Image {
    const info = resource.info;
    const descriptor = info.surface.descriptor;
    const request = info.surface.request orelse return error.Unsupported;
    try info.surface.validateView(descriptor.adapter_id, info.epoch);
    if (info.allocation_bytes != info.surface.allocation_bytes) return error.Descriptor;
    // Direct rendering into a displayed image needs the presentation owner's
    // inactive-image lease. This initial job path accepts offscreen images.
    if (target and descriptor.usage & a.gfx_buffer_usage_scanout != 0) return error.Unsupported;
    if (resource.driver_owner == 0 or info.epoch == 0 or info.epoch != descriptor.device_generation or descriptor.location != a.gfx_buffer_location_device_local or
        descriptor.plane_count != 1 or descriptor.plane_offsets[0] != 0 or descriptor.plane_pitches[0] > std.math.maxInt(u32) or descriptor.byte_length != info.logical_bytes or
        descriptor.usage & (if (target) a.gfx_buffer_usage_render else (a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_render)) == 0) return error.Unsupported;
    const format: render.image.Format = switch (descriptor.format) {
        0x34325258 => .xrgb8888, 0x34325241 => .argb8888, 0x20203852 => .r8, else => return error.Unsupported,
    };
    const result: render.image.Image = .{ .address = info.address, .bytes = info.logical_bytes, .width = descriptor.width,
        .height = descriptor.height, .pitch = @intCast(descriptor.plane_pitches[0]), .format = format,
        .layout = if (request.layout == .linear) .linear else .blocklinear, .log2_gobs = info.surface.log2_gobs };
    if (target) { _ = try render.image.target(result); } else { _ = try render.image.texture(result); }
    return result;
}
const Use = struct {
    reference: a.GfxBufferReference = .{},
    reference_stamp: a.GfxBufferReference = .{},
    gpu: a.GfxDeviceLease = .{},
    gpu_stamp: a.GfxDeviceLease = .{},
    ready: bool = false,
    fn borrowQueued(self: *Use, resource: Resource) !void {
        const ref = resource.info.reference;
        if (ref.version != 1 or ref.size < @sizeOf(a.GfxBufferReference) or ref.flags != a.gfx_buffer_reference_mapping_only or
            ref.reserved0 != 0 or !valid(ref.reference) or !valid(ref.buffer)) return error.Descriptor;
        // The canonical job owns execution. Its separate mapping-only
        // reference is held by the queue-render owner through upload and GR.
        self.reference = ref; self.reference_stamp = ref; self.ready = true;
    }
    fn open(self: *Use, memory: r4os.driver_memory.Context, resource: Resource, write: bool) !void {
        const info = resource.info;
        const imported = memory.bufferImport(&info.reference.reference, &self.reference);
        self.reference_stamp = self.reference;
        if (imported != a.gfx_buffer_result_ok and self.reference.reference.id == 0 and self.reference.buffer.id == 0) return error.Memory;
        const ref = self.reference;
        if (ref.version != 1 or ref.size < @sizeOf(a.GfxBufferReference) or ref.flags != 0 or ref.reserved0 != 0 or
            !valid(ref.reference) or std.meta.eql(ref.reference, info.reference.reference) or !std.meta.eql(ref.buffer, info.reference.buffer)) return error.Descriptor;
        if (imported != a.gfx_buffer_result_ok) return error.Memory;
        const access: u32 = @intFromBool(write);
        const acquired = memory.deviceAcquire(&ref.reference, &.{ .byte_length = info.logical_bytes, .gpu_virtual_address = info.address,
            .adapter_id = info.surface.descriptor.adapter_id, .device_generation = info.epoch, .access = access, .address_space = 1 }, &self.gpu);
        self.gpu_stamp = self.gpu;
        if (acquired != a.gfx_buffer_result_ok and self.gpu.lease.id == 0) return error.Memory;
        const gpu = self.gpu;
        if (gpu.version != 1 or gpu.size < @sizeOf(a.GfxDeviceLease) or !valid(gpu.lease) or gpu.byte_offset != 0 or
            gpu.byte_length != info.logical_bytes or gpu.gpu_virtual_address != info.address or gpu.device_generation != info.epoch or
            gpu.adapter_id != info.surface.descriptor.adapter_id or gpu.driver_owner != resource.driver_owner or gpu.access != access or
            gpu.address_space != 1 or gpu.dma_mask != std.math.maxInt(u64)) return error.Descriptor;
        if (acquired != a.gfx_buffer_result_ok) return error.Memory;
        self.ready = true;
    }
    fn stable(self: *const Use) bool { return std.meta.eql(self.reference,self.reference_stamp) and std.meta.eql(self.gpu,self.gpu_stamp); }
    fn close(self: *Use, memory: r4os.driver_memory.Context) bool {
        if (!self.stable()) return false;
        if (self.reference.flags == a.gfx_buffer_reference_mapping_only) {
            if (self.gpu.lease.id != 0) return false;
            self.* = .{};
            return true;
        }
        if (self.gpu.lease.id != 0) {
            if (memory.deviceRelease(&self.gpu,1) != a.gfx_buffer_result_ok) return false;
            self.gpu = .{}; self.gpu_stamp = .{};
        }
        if (self.reference.reference.id != 0) {
            if (memory.bufferRelease(&self.reference.reference) != a.gfx_buffer_result_ok) return false;
            self.reference = .{}; self.reference_stamp = .{};
        }
        self.ready = false; return true;
    }
};
pub const Owner = struct {
    self_address: usize = 0,
    memory: ?r4os.driver_memory.Context = null,
    cache_owner: ?*cache.Owner = null,
    command: ?render.Binding = null,
    target: Use = .{},
    source: Use = .{},
    failed: bool = false,
    failure: ?anyerror = null,
    pub fn open(self: *Owner, memory: r4os.driver_memory.Context, programs: *cache.Owner, target: Resource, source: ?Resource) !void {
        return self.openResources(memory, programs, target, source, false);
    }
    pub fn openQueued(self: *Owner, memory: r4os.driver_memory.Context, programs: *cache.Owner, target: Resource, source: ?Resource) !void {
        return self.openResources(memory, programs, target, source, true);
    }
    fn openResources(self: *Owner, memory: r4os.driver_memory.Context, programs: *cache.Owner, target: Resource, source: ?Resource, queued: bool) !void {
        if (self.self_address != 0) return error.Busy;
        const binding = try programs.binding();
        if (!std.meta.eql(binding.draw.target, try image(target,true)) or (binding.draw.source != null) != (source != null) or
            target.info.epoch != programs.epoch or target.driver_owner != programs.programs.info().?.driver_owner) return error.Descriptor;
        if (source) |value| if (!std.meta.eql(binding.draw.source.?,try image(value,false)) or value.info.epoch != programs.epoch or value.driver_owner != target.driver_owner) return error.Descriptor;
        self.* = .{ .self_address = @intFromPtr(self), .memory = memory };
        self.acquire(programs,target,source,queued) catch |err| {
            self.failure = err;
            if (err == error.Descriptor or !self.close(true)) { self.failed = true; return error.Retained; }
            return err;
        };
    }
    fn acquire(self: *Owner, programs: *cache.Owner, target: Resource, source: ?Resource, queued: bool) !void {
        self.command = try programs.acquire();
        self.cache_owner = programs;
        if (queued) {
            try self.target.borrowQueued(target);
            if (source) |value| try self.source.borrowQueued(value);
        } else {
            try self.target.open(self.memory.?,target,true);
            if (source) |value| try self.source.open(self.memory.?,value,false);
        }
    }
    pub fn valid(self: *const Owner) bool {
        if (self.self_address != @intFromPtr(self) or self.failed or self.cache_owner == null or self.command == null or
            !self.target.ready or !self.target.stable() or !self.source.stable() or
            (self.command.?.draw.source != null and !self.source.ready) or !self.cache_owner.?.borrowed) return false;
        return std.meta.eql(self.command.?, self.cache_owner.?.binding() catch return false);
    }
    pub fn close(self: *Owner, quiesced: bool) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.failed or !quiesced) return false;
        if (!self.source.close(self.memory.?) or !self.target.close(self.memory.?)) return false;
        if (self.cache_owner) |programs| programs.release() catch return false;
        self.* = .{}; return true;
    }
};
fn valid(h: a.GfxBufferHandle) bool { return h.id != 0 and h.generation != 0 and h.reserved0 == 0; }
