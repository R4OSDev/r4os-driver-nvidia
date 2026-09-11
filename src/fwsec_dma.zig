// A mapping of the immutable CPU image, never a cast of its CPU address.
// No address is submitted to hardware here. A future execution owner must
// establish quiescence before calling close after any GPU submission.
const r4os = @import("r4os");
const a = r4os.abi;
const load = @import("fwsec_load.zig");
const preparation = @import("fwsec_prepare.zig");
pub const Error = load.Error || error{ Api, Pin, Map, Descriptor, Busy };
pub const Mapping = struct {
    context: ?r4os.r4dev.DriverContext = null,
    pin: a.DmaPinnedBuffer = .{},
    mapping: a.DmaMapping = .{},
    prepared_plan: ?load.Plan = null,
    execution_owner: usize = 0,

    pub fn stage(self: *Mapping, ctx: *const r4os.r4dev.DriverContext, image: []const u8, prepared: *const preparation.Prepared) Error!load.Plan {
        if (image.len != prepared.bytes) return error.Bounds;
        try self.stageImage(ctx, image);
        self.prepared_plan = try load.plan(prepared, self.mapping.segments[0].phys_addr, self.mapping.segments[0].bytes);
        return self.prepared_plan.?;
    }

    /// Common retained Falcon image mapping for FWSEC and SEC2 Booter. The
    /// caller validates its own firmware format and assigns prepared_plan;
    /// an image mapping alone is not an executable firmware plan.
    pub fn stageImage(self: *Mapping, ctx: *const r4os.r4dev.DriverContext, image: []const u8) Error!void {
        if (self.context != null) return error.Busy;
        if (!ctx.supportsDriverApi(19, @offsetOf(a.DriverApi, "dma_unpin_buffer") + @sizeOf(usize))) return error.Api;
        if (image.len == 0 or image.len > a.dma_mapping_max_bytes) return error.Bounds;
        if (@intFromPtr(image.ptr) & 255 != 0) return error.Alignment;
        self.context = ctx.*;
        if (ctx.pinDmaConstBuffer(image, &self.pin) != 0) return error.Pin;
        if (self.pin.version != 1 or self.pin.size < @sizeOf(a.DmaPinnedBuffer) or self.pin.handle == 0 or
            self.pin.virt_addr != @intFromPtr(image.ptr) or self.pin.bytes != image.len or self.pin.flags != 0 or
            self.pin.reserved != 0 or self.pin.page_count != ((@intFromPtr(image.ptr) & 4095) + image.len + 4095) / 4096) return error.Descriptor;
        const constraints = a.DmaConstraints{
            .dma_mask = load.dma_mask,
            .alignment = load.block_bytes,
            .max_segments = 1,
            .max_segment_bytes = @intCast(image.len),
            .flags = a.dma_flag_coherent | a.dma_flag_allow_bounce,
        };
        // The API synchronizes all prepared bytes for the device, including
        // a bounded bounce copy if the underlying CPU pages are fragmented.
        if (ctx.mapDmaPinned(&self.pin, &constraints, a.dma_direction_to_device, &self.mapping) != 0) return error.Map;
        const map = &self.mapping;
        if (map.version != 1 or map.size < @sizeOf(a.DmaMapping) or map.handle == 0 or map.pin_handle != self.pin.handle or
            map.requested_bytes != image.len or map.mapped_bytes != image.len or map.direction != a.dma_direction_to_device or
            map.segment_count != 1 or map.reserved0 != 0 or map.reserved1 != 0 or
            (map.flags & ~a.dma_mapping_flag_bounced) != constraints.flags or
            map.segments[0].reserved != 0 or map.segments[0].bytes != image.len) return error.Descriptor;
    }

    pub fn close(self: *Mapping) bool {
        if (self.execution_owner != 0) return false;
        const ctx = self.context orelse return self.pin.handle == 0 and self.mapping.handle == 0;
        // Keep the exact descriptors on a failed release, even if a callback
        // changed its in/out argument. Never unpin or free a mapped backing.
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
        self.* = .{};
        return true;
    }
};
