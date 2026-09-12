//! Display DMA contexts keep native storage alive independently of its
//! creator. The enclosing Device owns this heap allocation and instance.
const std = @import("std");
const vram = @import("gsp_vram.zig");
const names = @import("gsp_rm_names.zig");
const transport = @import("gsp_transport.zig");
const wire = @import("gsp_display_engine_wire.zig");
pub const layout = @import("gsp_display_table.zig");
pub const Error = layout.Error || vram.Error || names.Error || error{State};
pub const Owner = struct {
    self_address: usize = 0,
    session: ?*transport.Session = null,
    binding: ?wire.Binding = null,
    binding_stamp: ?wire.Binding = null,
    reservation: ?names.Children = null,
    instance: ?*vram.storage.Use = null,
    instance_stamp: ?vram.storage.Source = null,
    table: layout.Table = .{},
    storage: [layout.capacity]vram.storage.Use = @splat(.{}),
    failed: bool = false,

    pub fn open(self: *Owner, session: *transport.Session, binding: wire.Binding, parent: names.Lease, instance: *vram.storage.Use) Error!void {
        if (self.self_address != 0) return error.Busy;
        try wire.validate(binding);
        const src = instance.info() orelse return error.Stale;
        if (session.state != .active or session.epoch != binding.epoch or parent.epoch != binding.epoch or parent.client != binding.client or
            src.epoch != binding.epoch or src.bytes != 65536 or src.physical.bytes != 65536) return error.Stale;
        const reservation = try session.rm_names.reserveChildren(parent, layout.capacity);
        self.* = .{};
        self.self_address = @intFromPtr(self); self.session = session; self.binding = binding; self.binding_stamp = binding;
        self.instance = instance; self.instance_stamp = src; self.reservation = reservation;
        try self.table.init(binding.client, binding.root, binding.epoch);
    }
    pub fn valid(self: *const Owner) bool {
        if (self.self_address != @intFromPtr(self) or self.failed or self.session == null or self.session.?.state != .active or
            self.binding == null or !std.meta.eql(self.binding, self.binding_stamp) or self.instance == null or
            !std.meta.eql(self.instance.?.info(), self.instance_stamp) or !self.table.valid() or
            self.table.epoch != self.binding.?.epoch or self.table.client != self.binding.?.client or self.table.root != self.binding.?.root) return false;
        self.session.?.rm_names.validateChildren(self.reservation orelse return false) catch return false;
        for (&self.storage, &self.table.entries) |*use, *entry| {
            if (entry.*) |descriptor| {
                const value = use.info() orelse return false;
                if (value.epoch != self.table.epoch or descriptor.physical != value.physical.base or descriptor.bytes != value.bytes or
                    descriptor.target != .vram) return false;
            } else if (use.self_address != 0) return false;
        }
        return true;
    }
    pub fn bindNative(self: *Owner, channel: u32, source: *vram.Owner) Error!u32 {
        if (!self.valid()) return error.Stale;
        if (self.table.uploading) return error.Busy;
        if (self.table.count >= layout.capacity or self.table.revision == std.math.maxInt(u64)) return error.Exhausted;
        const src = source.info() orelse return error.Stale;
        const physical = src.physical orelse return error.Unsupported;
        if (src.epoch != self.binding.?.epoch or source.binding.space.client != self.binding.?.client or
            source.binding.space.device != self.binding.?.device or source.adapter != self.instance_stamp.?.adapter) return error.Stale;
        const index = self.table.count;
        const handle = try self.reservation.?.object(@intCast(index));
        const entry: layout.Descriptor = .{ .channel = channel, .handle = handle, .target = .vram, .physical = physical.base, .bytes = src.logical_bytes };
        try layout.validate(entry);
        try source.retainStorage(&self.storage[index]);
        self.table.add(entry) catch |err| {
            // No upload could start between the two worker-owned operations.
            if (!self.storage[index].close(true)) { self.quarantine(); return error.Retained; }
            return err;
        };
        return handle;
    }
    pub fn quarantine(self: *Owner) void {
        self.failed = true; self.table.failed = true;
        if (self.reservation) |reservation| self.session.?.rm_names.retainChildren(reservation) catch {};
    }
    // No ordinary close: a freed command channel does not prove its last
    // scanout image stopped being fetched. A later display recovery/handoff
    // owner must establish physical resource retirement before release.
};
