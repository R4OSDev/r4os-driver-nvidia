//! Common display shadow to the existing native scanout owner. The queue
//! protects the source read; the display's exclusive native Use protects
//! the destination. No fabricated target job reference or second Use.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const backing = @import("gsp_native_backing.zig");
const image = @import("gsp_display_image.zig");
const copy = @import("gsp_copy_wire.zig");
pub const Error = backing.Error || copy.Error || error{State, Overflow};
pub const Owner = struct {
    self_address: usize = 0,
    memory: ?r4os.driver_memory.Context = null,
    shadow: a.GfxBufferReference = .{},
    shadow_stamp: a.GfxBufferReference = .{},
    descriptor: a.GfxBufferDescriptor = .{},
    descriptor_stamp: a.GfxBufferDescriptor = .{},
    target: ?*backing.Use = null,
    target_stamp: ?backing.Source = null,
    scanout: ?image.Image = null,
    image_stamp: ?image.Image = null,
    failed: bool = false,

    pub fn open(self: *Owner, memory: r4os.driver_memory.Context, source: a.GfxBufferHandle, target: *backing.Use, scanout: image.Image) Error!void {
        if (self.self_address != 0) return error.Busy;
        try image.validate(scanout);
        const native_source = target.info() orelse return error.Stale;
        var d: a.GfxBufferDescriptor = .{};
        if (memory.bufferDescribe(&source, &d) != a.gfx_buffer_result_ok) return error.Memory;
        if (d.version != 1 or d.size < @sizeOf(a.GfxBufferDescriptor) or d.location != a.gfx_buffer_location_system or
            d.adapter_id != 0 or d.device_generation != 0 or d.modifier != 0 or d.plane_count != 1 or
            d.format != a.gfx_buffer_format_xrgb8888 or scanout.format != d.format or d.width != scanout.width or d.height != scanout.height or
            d.plane_offsets[0] != 0 or d.plane_pitches[0] != @as(u64, d.width) * 4 or
            d.byte_length != d.plane_pitches[0] * d.height or native_source.bytes != scanout.bytes or
            d.usage & (a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source) !=
                (a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source)) return error.Descriptor;
        self.* = .{ .self_address = @intFromPtr(self), .memory = memory, .descriptor = d, .descriptor_stamp = d,
            .target = target, .target_stamp = native_source, .scanout = scanout, .image_stamp = scanout };
        const status = memory.bufferImport(&source, &self.shadow);
        self.shadow_stamp = self.shadow;
        if (status != a.gfx_buffer_result_ok and self.shadow.reference.id == 0 and self.shadow.buffer.id == 0) { self.* = .{}; return error.Memory; }
        const ref = self.shadow;
        if (status != a.gfx_buffer_result_ok or ref.version != 1 or ref.size < @sizeOf(a.GfxBufferReference) or ref.flags != 0 or ref.reserved0 != 0 or
            ref.reference.id == 0 or ref.reference.generation == 0 or ref.reference.reserved0 != 0 or std.meta.eql(ref.reference, source) or
            ref.buffer.id == 0 or ref.buffer.generation == 0 or ref.buffer.reserved0 != 0) { self.failed = true; return error.Retained; }
        var actual: a.GfxBufferDescriptor = .{};
        if (memory.bufferDescribe(&ref.reference, &actual) != a.gfx_buffer_result_ok or !std.meta.eql(actual, d)) { self.failed = true; return error.Retained; }
    }
    pub fn valid(self: *const Owner) bool {
        return self.self_address == @intFromPtr(self) and !self.failed and self.memory != null and self.shadow.reference.id != 0 and
            self.target != null and std.meta.eql(self.target.?.info(), self.target_stamp) and std.meta.eql(self.shadow, self.shadow_stamp) and
            std.meta.eql(self.descriptor, self.descriptor_stamp) and self.scanout != null and std.meta.eql(self.scanout, self.image_stamp);
    }
    pub fn matches(self: *const Owner, job: a.GfxDriverJob) bool {
        return self.valid() and job.operation == a.gfx_queue_operation_upload and std.meta.eql(job.source_buffer, self.shadow.buffer) and
            std.meta.eql(job.target_buffer, a.GfxBufferHandle{}) and job.target_offset == 0;
    }
    pub fn transfer(self: *const Owner, job: a.GfxDriverJob, source_address: u64, source_bytes: u64) Error!copy.Transfer {
        if (!self.matches(job) or source_bytes != self.descriptor.byte_length) return error.Stale;
        const pitch = self.descriptor.plane_pitches[0];
        if (job.byte_length == 0 or job.source_offset >= source_bytes or job.byte_length > source_bytes - job.source_offset or
            job.source_offset & 3 != 0 or job.byte_length & 3 != 0) return error.Bounds;
        // Common display encodes (height-1)*pitch + width*4. Subtract one
        // before division so a full-width final row remains a full row.
        const y = job.source_offset / pitch; const x_bytes = job.source_offset % pitch;
        const rows = (job.byte_length - 1) / pitch + 1;
        const line = (job.byte_length - 1) % pitch + 1;
        if (line > pitch - x_bytes or rows > self.descriptor.height - y) return error.Bounds;
        const view = self.scanout.?; const destination = self.target_stamp.?;
        const target_offset = try std.math.add(u64, view.offset, try std.math.add(u64, try std.math.mul(u64, y, view.pitch), x_bytes));
        const result: copy.Transfer = .{ .source = try std.math.add(u64, source_address, job.source_offset),
            .target = try std.math.add(u64, destination.address, target_offset), .bytes = line,
            .rows = .{ .count = @intCast(rows), .source_pitch = @intCast(pitch), .target_pitch = view.pitch } };
        if (target_offset >= destination.bytes or try result.span(true) > destination.bytes - target_offset) return error.Bounds;
        return result;
    }
    pub fn closeUnregistered(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (!self.valid() or self.memory.?.bufferRelease(&self.shadow.reference) != a.gfx_buffer_result_ok) return false;
        self.* = .{}; return true;
    }
};
