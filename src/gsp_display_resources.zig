//! Display DMA contexts keep native storage alive independently of its
//! creator. The enclosing Device owns this heap allocation and instance.
const std = @import("std");
const vram = @import("gsp_vram.zig");
const names = @import("gsp_rm_names.zig");
const transport = @import("gsp_transport.zig");
const wire = @import("gsp_display_engine_wire.zig");
pub const notifier = @import("gsp_display_notifier.zig");
const r4os = @import("r4os");
pub const layout = @import("gsp_display_table.zig");
pub const image = @import("gsp_display_image.zig");
pub const Error = layout.Error || vram.Error || names.Error || notifier.Error || error{State};
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
    surfaces: [layout.capacity]?vram.surface.Plan = @splat(null),
    surface_stamps: [layout.capacity]u64 = @splat(0),
    notifiers: [9]notifier.Owner = @splat(.{}),
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
        for (&self.storage, &self.table.entries, 0..) |*use, *entry, i| {
            if (entry.*) |descriptor| {
                if (descriptor.target == .vram) {
                    const value = use.info() orelse return false;
                    if (value.epoch != self.table.epoch or descriptor.physical != value.physical.base or descriptor.bytes != value.bytes) return false;
                    if (self.surfaces[i]) |plan| {
                        if (surfaceHash(plan) != self.surface_stamps[i] or plan.descriptor.byte_length != value.bytes or
                            plan.descriptor.adapter_id != value.adapter or plan.descriptor.device_generation != value.epoch) return false;
                        _ = image.create(plan, descriptor.handle, descriptor.channel) catch return false;
                    } else if (self.surface_stamps[i] != 0) return false;
                } else {
                    if (descriptor.channel >= self.notifiers.len or use.self_address != 0 or self.surfaces[i] != null or self.surface_stamps[i] != 0) return false;
                    const note = &self.notifiers[descriptor.channel];
                    if (!note.valid() or !note.backing.retained or note.handle != descriptor.handle or note.epoch != self.table.epoch or
                        note.channel != descriptor.channel or note.physical_stamp != descriptor.physical or descriptor.bytes != 4096) return false;
                }
            } else if (use.self_address != 0 or self.surfaces[i] != null or self.surface_stamps[i] != 0) return false;
        }
        return true;
    }
    pub fn bindNative(self: *Owner, channel: u32, source: *vram.Owner) Error!u32 {
        if (!self.valid()) return error.Stale;
        if (self.table.uploading) return error.Busy;
        if (self.table.count >= layout.capacity or self.table.revision == std.math.maxInt(u64)) return error.Exhausted;
        const src = source.info() orelse return error.Stale;
        try src.surface.validate(source.adapter, source.binding.space);
        if (src.surface.scanout()) _ = try image.create(src.surface, 1, channel);
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
        self.surfaces[index] = if (src.surface.scanout()) src.surface else null;
        self.surface_stamps[index] = if (self.surfaces[index]) |plan| surfaceHash(plan) else 0;
        return handle;
    }
    pub fn publishedImage(self: *Owner, channel: u32, handle: u32) ?image.Image {
        if (!self.valid() or !self.table.published(channel, handle)) return null;
        for (&self.table.entries, 0..) |*entry, i| if (entry.*) |descriptor| {
            if (descriptor.channel == channel and descriptor.handle == handle) {
                const plan = self.surfaces[i] orelse return null;
                return image.create(plan, handle, channel) catch null;
            }
        };
        return null;
    }
    pub fn publishedStorage(self: *Owner, channel: u32, handle: u32) ?*vram.storage.Use {
        if (self.publishedImage(channel, handle) == null) return null;
        for (&self.table.entries, 0..) |*entry, i| if (entry.*) |descriptor| {
            if (descriptor.channel == channel and descriptor.handle == handle) return &self.storage[i];
        };
        return null;
    }
    pub fn createNotifier(self: *Owner, ctx: *const r4os.r4dev.DriverContext, channel: u32) Error!u32 {
        if (!self.valid()) return error.Stale;
        if (channel >= self.notifiers.len) return error.Bounds;
        if (self.table.uploading or self.notifiers[channel].self_address != 0) return error.Busy;
        if (self.table.count >= layout.capacity or self.table.revision == std.math.maxInt(u64)) return error.Exhausted;
        const handle = try self.reservation.?.object(@intCast(self.table.count));
        const note = &self.notifiers[channel];
        note.open(ctx, self.instance_stamp.?.adapter, self.table.epoch, channel, handle) catch |err| {
            if (note.failed) self.quarantine(); return err;
        };
        self.table.add(.{ .channel = channel, .handle = handle, .physical = note.physical_stamp, .bytes = 4096, .target = .coherent_system }) catch |err| {
            if (!note.closeUnpublished()) { self.quarantine(); return error.Retained; } return err;
        };
        note.backing.retained = true; return handle;
    }
    pub fn publishedNotifier(self: *Owner, channel: u32) ?*notifier.Owner {
        if (!self.valid() or channel >= self.notifiers.len) return null;
        const note = &self.notifiers[channel];
        return if (note.valid() and self.table.published(channel, note.handle)) note else null;
    }
    pub fn quarantine(self: *Owner) void {
        self.failed = true; self.table.failed = true;
        for (&self.notifiers) |*note| if (note.self_address != 0) note.quarantine();
        if (self.reservation) |reservation| self.session.?.rm_names.retainChildren(reservation) catch {};
    }
    // No ordinary close: a freed command channel does not prove its last
    // scanout image stopped being fetched. A later display recovery/handoff
    // owner must establish physical resource retirement before release.
};
fn surfaceHash(plan: vram.surface.Plan) u64 {
    var digest = std.hash.Wyhash.init(0); std.hash.autoHash(&digest, plan); return digest.final();
}
