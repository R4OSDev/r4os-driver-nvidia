//! Resident staging for one canonical full BO import. No caller pointer or
//! DMA lease is retained here. A malformed result stays owned for diagnosis.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub const Error = error{ Busy, Stale, Descriptor, Retained, Memory, Unsupported, Api };
pub const Owner = struct {
    self_address: usize = 0,
    memory: ?r4os.driver_memory.Context = null,
    epoch: u64 = 0,
    reference: a.GfxBufferReference = .{},
    stamp: a.GfxBufferReference = .{},
    damaged: bool = false,

    pub fn empty(self: *const Owner) bool { return self.self_address == 0 and self.memory == null and self.reference.reference.id == 0 and self.reference.buffer.id == 0; }
    pub fn acquire(self: *Owner, memory: r4os.driver_memory.Context, epoch: u64, borrowed: a.GfxBufferReference) Error!void {
        if (!self.empty()) return error.Busy;
        if (epoch == 0) return error.Stale;
        self.* = .{ .self_address = @intFromPtr(self), .memory = memory, .epoch = epoch };
        const rc = memory.bufferImport(&borrowed.reference, &self.reference);
        self.stamp = self.reference;
        const value = self.reference;
        if (rc != 1 and value.reference.id == 0 and value.buffer.id == 0) {
            self.* = .{};
            return switch (rc) {
                a.gfx_buffer_error_busy => error.Busy,
                a.gfx_buffer_error_oom, a.gfx_buffer_error_capacity, a.gfx_buffer_error_budget => error.Memory,
                a.gfx_buffer_error_stale, a.gfx_buffer_error_closed, a.gfx_buffer_error_invalid => error.Stale,
                a.gfx_buffer_error_unsupported, a.err_no_fn, a.err_no_group => error.Unsupported,
                else => error.Api,
            };
        }
        if (value.version != 1 or value.size < @sizeOf(a.GfxBufferReference) or value.reserved0 != 0 or
            value.flags & ~@as(u32, a.gfx_buffer_reference_immutable | a.gfx_buffer_reference_mapping_only) != 0 or
            value.reference.id == 0 or value.reference.generation == 0 or value.reference.reserved0 != 0 or
            value.buffer.id == 0 or value.buffer.generation == 0 or value.buffer.reserved0 != 0) {
            self.damaged = true; return error.Descriptor;
        }
        if (rc != 1) return error.Retained;
        if (value.flags != 0 or !std.meta.eql(value.buffer, borrowed.buffer)) {
            try self.close();
            return if (value.flags != 0) error.Unsupported else error.Stale;
        }
    }
    fn stable(self: *const Owner) Error!void {
        if (self.self_address != @intFromPtr(self) or self.memory == null or self.epoch == 0 or
            !std.meta.eql(self.reference, self.stamp)) return error.Stale;
        if (self.damaged) return error.Descriptor;
    }
    pub fn close(self: *Owner) Error!void {
        if (self.empty()) return;
        try self.stable();
        if (self.memory.?.bufferRelease(&self.reference.reference) != 1) return error.Retained;
        self.* = .{};
    }
    /// The receiver becomes responsible before any asynchronous operation.
    pub fn take(self: *Owner) Error!a.GfxBufferReference {
        try self.stable();
        const value = self.reference;
        self.* = .{};
        return value;
    }
    pub fn closeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence) Error!void {
        if (self.empty()) return;
        if (!proof.valid(self.epoch)) return error.Retained;
        try self.close();
    }
};
