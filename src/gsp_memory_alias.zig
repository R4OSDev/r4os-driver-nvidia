//! Borrowed RM memory objects remain owned by their original BO owner.
//! Every use is resident and linked before a map RPC; only a confirmed unmap,
//! rejected map, or whole-device reset permits its release. Serialized worker.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const wire = @import("gsp_virtual_wire.zig");
pub const Error = wire.Error || error{ Busy, Descriptor, Retained };
pub const RetainError = Error || error{ Api, Memory, Unsupported };
pub const Source = struct {
    space: @import("gsp_vaspace.zig").Info,
    object: u32,
    allocation_bytes: u64,
    offset: u64,
    bytes: u64,
    location: wire.Location,
};
pub const Set = struct {
    self_address: usize = 0,
    first: ?*Use = null,

    pub fn empty(self: *const Set) bool {
        return (self.self_address == 0 or self.self_address == @intFromPtr(self)) and self.first == null;
    }
    pub fn acquire(self: *Set, use: *Use, source: Source) Error!void {
        if ((self.self_address != 0 and self.self_address != @intFromPtr(self)) or use.self_address != 0 or
            use.set != null or use.previous != null or use.next != null or use.source != null or use.stamp != null or
            use.memory != null or use.mapping_owner != null or use.damaged or !std.meta.eql(use.reference, a.GfxBufferReference{}) or
            !std.meta.eql(use.reference_stamp, a.GfxBufferReference{})) return error.Stale;
        if (source.space.epoch == 0 or source.object == 0 or source.bytes == 0 or
            (source.allocation_bytes | source.offset | source.bytes) & 4095 != 0 or source.bytes > source.allocation_bytes or
            source.offset > source.allocation_bytes - source.bytes) return error.Bounds;
        self.self_address = @intFromPtr(self);
        use.self_address = @intFromPtr(use);
        use.set = self;
        use.source = source;
        use.stamp = source;
        use.next = self.first;
        if (self.first) |head| head.previous = use;
        self.first = use;
    }
};
pub const Use = struct {
    self_address: usize = 0,
    set: ?*Set = null,
    previous: ?*Use = null,
    next: ?*Use = null,
    source: ?Source = null,
    stamp: ?Source = null,
    memory: ?r4os.driver_memory.Context = null,
    reference: a.GfxBufferReference = .{},
    reference_stamp: a.GfxBufferReference = .{},
    damaged: bool = false,
    mapping_owner: ?*const anyopaque = null,

    pub fn info(self: *const Use) Error!Source {
        if (self.damaged) return error.Descriptor;
        if (self.self_address != @intFromPtr(self) or self.set == null or
            self.set.?.self_address != @intFromPtr(self.set.?) or !std.meta.eql(self.source, self.stamp) or
            !std.meta.eql(self.reference, self.reference_stamp)) return error.Stale;
        if (self.previous) |previous| {
            if (previous.next != self or previous.set != self.set) return error.Stale;
        } else if (self.set.?.first != self) return error.Stale;
        if (self.next) |next| if (next.previous != self or next.set != self.set) return error.Stale;
        return self.source orelse error.Stale;
    }
    /// Native VRAM needs an independent common import as well as an RM hold:
    /// otherwise bufferTakeRelease could issue a release ticket too early.
    /// The common owner resolves the source reference. A caller's object ID
    /// is only an expected identity, never proof of its backing or access mode.
    pub fn retainReference(self: *Use, memory: r4os.driver_memory.Context, reference: a.GfxBufferHandle, expected: a.GfxBufferHandle) RetainError!void {
        _ = try self.info();
        if (self.memory != null or self.reference.reference.id != 0) return error.Busy;
        self.memory = memory;
        const result = memory.bufferImport(&reference, &self.reference);
        self.reference_stamp = self.reference;
        const v = self.reference;
        if (result != a.gfx_buffer_result_ok and v.reference.id == 0 and v.buffer.id == 0) {
            self.memory = null;
            self.reference = .{};
            self.reference_stamp = .{};
            return switch (result) {
                a.gfx_buffer_error_busy => error.Busy,
                a.gfx_buffer_error_oom, a.gfx_buffer_error_capacity, a.gfx_buffer_error_budget => error.Memory,
                a.gfx_buffer_error_stale, a.gfx_buffer_error_closed, a.gfx_buffer_error_invalid => error.Stale,
                a.gfx_buffer_error_unsupported => error.Unsupported,
                else => error.Api,
            };
        }
        if (v.version != 1 or v.size < @sizeOf(a.GfxBufferReference) or v.flags & ~@as(u32, a.gfx_buffer_reference_immutable | a.gfx_buffer_reference_mapping_only) != 0 or v.reserved0 != 0 or
            v.reference.id == 0 or v.reference.generation == 0 or v.reference.reserved0 != 0 or
            v.buffer.id == 0 or v.buffer.generation == 0 or v.buffer.reserved0 != 0) { self.damaged = true; return error.Descriptor; }
        if (result != a.gfx_buffer_result_ok) return error.Retained;
        if (v.flags != 0 or !std.meta.eql(v.buffer, expected)) {
            // A valid canonical import of an unsuitable BO is a rejected
            // request, not a damaged device. Release precisely that import.
            if (memory.bufferRelease(&v.reference) != a.gfx_buffer_result_ok) return error.Retained;
            self.memory = null;
            self.reference = .{};
            self.reference_stamp = .{};
            return if (v.flags != 0) error.Unsupported else error.Stale;
        }
    }
    pub fn close(self: *Use, quiesced: bool) Error!void {
        if (self.mapping_owner != null) return error.Busy;
        return self.release(quiesced);
    }
    pub fn closeMapping(self: *Use, owner: *const anyopaque, quiesced: bool) Error!void {
        if (self.mapping_owner != owner) return error.Stale;
        return self.release(quiesced);
    }
    fn release(self: *Use, quiesced: bool) Error!void {
        if (!quiesced) return error.Busy;
        _ = try self.info();
        if (self.reference.reference.id != 0) {
            const memory = self.memory orelse return error.Retained;
            if (memory.bufferRelease(&self.reference.reference) != a.gfx_buffer_result_ok) return error.Retained;
        }
        if (self.previous) |previous| previous.next = self.next else self.set.?.first = self.next;
        if (self.next) |next| next.previous = self.previous;
        self.* = .{};
    }
    pub fn closeAfterReset(self: *Use, proof: @import("gsp_reset.zig").Quiescence) Error!void {
        const value = try self.info();
        if (!proof.valid(value.space.epoch)) return error.Retained;
        try self.close(true);
    }
    pub fn closeMappingAfterReset(self: *Use, owner: *const anyopaque, proof: @import("gsp_reset.zig").Quiescence) Error!void {
        const value = try self.info();
        if (!proof.valid(value.space.epoch)) return error.Retained;
        try self.closeMapping(owner, true);
    }
};
