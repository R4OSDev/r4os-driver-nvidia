//! Display DMA contexts keep native storage alive independently of its
//! creator. The enclosing Device owns this heap allocation and instance.
const std = @import("std");
const vram = @import("gsp_vram.zig");
const names = @import("gsp_rm_names.zig");
const transport = @import("gsp_transport.zig");
const console = @import("boot_console.zig");
const wire = @import("gsp_display_engine_wire.zig");
pub const notifier = @import("gsp_display_notifier.zig");
const r4os = @import("r4os");
const a = r4os.abi;
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
    consoles: [layout.capacity]?*console.Owner = @splat(null),
    surface_stamps: [layout.capacity]u64 = @splat(0),
    dynamic_names: [layout.capacity]?names.Children = @splat(null),
    last_window_use: [layout.capacity]?struct { point: u64, offset: u16 } = @splat(null),
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
                if (self.dynamic_names[i]) |lease| {
                    self.session.?.rm_names.validateChildren(lease) catch return false;
                    if ((lease.object(0) catch return false) != descriptor.handle or
                        !std.meta.eql(lease.parent, self.reservation.?.parent)) return false;
                }
                if (descriptor.target == .vram) {
                    if (self.consoles[i]) |held| {
                        const value = held.imageInfo(self.table.epoch, descriptor.handle, descriptor.channel) catch return false;
                        if (!descriptor.reserved_console or held.consumer != @intFromPtr(self) or descriptor.physical != held.physical or descriptor.bytes != value.bytes or
                            use.self_address != 0 or self.surfaces[i] != null or self.surface_stamps[i] != 0) return false;
                        continue;
                    }
                    const value = use.info() orelse return false;
                    if (descriptor.reserved_console) return false;
                    if (value.epoch != self.table.epoch or descriptor.physical != value.physical.base or descriptor.bytes != value.bytes) return false;
                    if (self.surfaces[i]) |plan| {
                        if (surfaceHash(plan) != self.surface_stamps[i] or plan.descriptor.byte_length != value.bytes or
                            plan.descriptor.adapter_id != value.adapter or plan.descriptor.device_generation != value.epoch) return false;
                        _ = image.create(plan, descriptor.handle, descriptor.channel) catch return false;
                    } else if (self.surface_stamps[i] != 0) return false;
                } else {
                    if (descriptor.reserved_console or descriptor.channel >= self.notifiers.len or use.self_address != 0 or self.consoles[i] != null or self.surfaces[i] != null or self.surface_stamps[i] != 0) return false;
                    const note = &self.notifiers[descriptor.channel];
                    if (!note.valid() or !note.backing.retained or note.handle != descriptor.handle or note.epoch != self.table.epoch or
                        note.channel != descriptor.channel or note.physical_stamp != descriptor.physical or descriptor.bytes != 4096) return false;
                }
            } else if (use.self_address != 0 or self.consoles[i] != null or self.surfaces[i] != null or self.surface_stamps[i] != 0 or self.dynamic_names[i] != null or self.last_window_use[i] != null) return false;
        }
        return true;
    }
    pub fn bindNative(self: *Owner, channel: u32, source: *vram.Owner) Error!u32 {
        return self.bindSource(channel, source, source.info() orelse return error.Stale, false);
    }
    /// Original reserved console memory is not a native allocation alias.
    /// Install only into a fresh table; the enclosing Device keeps its owner
    /// and the boot reservation until a later proven GPU stop.
    pub fn bindConsole(self: *Owner, channel: u32, source: *console.Owner) !u32 {
        if (!self.valid() or source.consumer != 0) return error.Stale;
        if (self.table.uploading or self.table.uploaded_revision != 0 or self.table.change != null) return error.Busy;
        const index = self.table.freeIndex() orelse return error.Exhausted;
        const handle = try self.reservation.?.object(@intCast(index));
        const value = try source.imageInfo(self.table.epoch, handle, channel);
        try self.table.add(.{ .channel = channel, .handle = handle, .target = .vram, .physical = source.physical, .bytes = value.bytes, .reserved_console = true });
        self.consoles[index] = source;
        source.consumer = @intFromPtr(self);
        return handle;
    }
    pub fn bindScanout(self: *Owner, channel: u32, source: *vram.Owner, reference: a.GfxBufferReference) Error!u32 {
        return self.bindSource(channel, source, source.scanoutInfo(reference) orelse return error.Stale, true);
    }
    fn bindSource(self: *Owner, channel: u32, source: *vram.Owner, src: vram.Info, scanout: bool) Error!u32 {
        if (!self.valid()) return error.Stale;
        if (self.table.uploading or self.table.change != null) return error.Busy;
        if (self.table.count >= layout.capacity or self.table.revision == std.math.maxInt(u64)) return error.Exhausted;
        try src.surface.validate(source.adapter, source.binding.space);
        if (src.surface.scanout()) _ = try image.create(src.surface, 1, channel);
        const physical = src.physical orelse return error.Unsupported;
        if (src.epoch != self.binding.?.epoch or source.binding.space.client != self.binding.?.client or
            source.binding.space.device != self.binding.?.device or source.adapter != self.instance_stamp.?.adapter) return error.Stale;
        const index = self.table.freeIndex() orelse return error.Exhausted;
        // Fresh wire names, reusable storage slots: repeated mode switches do
        // not exhaust a boot-sized table or recycle a cached DMA identity.
        const dynamic = if (self.table.uploaded_revision != 0)
            try self.session.?.rm_names.reserveChildren(self.reservation.?.parent, 1) else null;
        errdefer if (dynamic) |lease| self.session.?.rm_names.retireChildren(lease) catch {};
        const handle = if (dynamic) |lease| try lease.object(0) else try self.reservation.?.object(@intCast(index));
        const entry: layout.Descriptor = .{ .channel = channel, .handle = handle, .target = .vram, .physical = physical.base, .bytes = src.logical_bytes };
        try layout.validate(entry);
        if (scanout) try self.storage[index].acquireScanout(source.memory, .{ .reference = src.reference,
            .physical = physical, .address = src.address, .bytes = src.logical_bytes, .epoch = src.epoch,
            .adapter = source.adapter, .driver_owner = source.reservation.driver_owner })
        else try source.retainStorage(&self.storage[index]);
        self.table.add(entry) catch |err| {
            // No upload could start between the two worker-owned operations.
            if (!self.storage[index].close(true)) { self.quarantine(); return error.Retained; }
            return err;
        };
        self.surfaces[index] = if (src.surface.scanout()) src.surface else null;
        self.surface_stamps[index] = if (self.surfaces[index]) |plan| surfaceHash(plan) else 0;
        self.dynamic_names[index] = dynamic;
        return handle;
    }
    pub fn removeImage(self: *Owner, channel: u32, handle: u32) Error!void {
        if (self.publishedImage(channel, handle) == null) return error.Stale;
        if (self.consoles[self.table.indexOf(channel, handle).?] != null) return error.Retained;
        if (!try self.imageFinished(channel, handle)) return error.Busy;
        try self.table.remove(channel, handle);
    }
    pub fn recordImageUse(self: *Owner, channel: u32, handle: u32, point: u64, offset: u16) Error!void {
        if (self.publishedImage(channel, handle) == null or channel == 0 or channel >= self.notifiers.len or (offset != 0 and offset != 16)) return error.Stale;
        const note = &self.notifiers[channel];
        if (!note.valid() or note.phase != .armed or note.point != point or note.offset != offset or note.window_points[offset / 16] != point) return error.Stale;
        const index = self.table.indexOf(channel, handle) orelse return error.Stale;
        self.last_window_use[index] = .{ .point = point, .offset = offset };
    }
    pub fn imageFinished(self: *Owner, channel: u32, handle: u32) Error!bool {
        if (!self.valid() or channel == 0 or channel >= self.notifiers.len) return error.Stale;
        const index = self.table.indexOf(channel, handle) orelse return error.Stale;
        const used = self.last_window_use[index] orelse return true;
        return self.notifiers[channel].windowFinished(used.point, used.offset);
    }
    /// Called by Runtime only after the actual final CE receipt and a second
    /// check that no display or copy consumer names the retiring image.
    pub fn finishRemoval(self: *Owner) Error!void {
        if (!self.valid()) return error.Stale;
        const change = self.table.change orelse return;
        if (!change.remove or self.table.uploading or self.table.revision != self.table.uploaded_revision) return error.Busy;
        const index = change.index;
        const descriptor = self.table.entries[index].?;
        if (!try self.imageFinished(descriptor.channel, descriptor.handle)) return error.Busy;
        if (!self.storage[index].close(true)) { self.quarantine(); return error.Retained; }
        if (self.dynamic_names[index]) |lease| self.session.?.rm_names.retireChildren(lease) catch |err| {
            self.quarantine(); return err;
        };
        _ = try self.table.finishRemove();
        self.surfaces[index] = null; self.surface_stamps[index] = 0; self.dynamic_names[index] = null; self.last_window_use[index] = null;
    }
    pub fn publishedImage(self: *Owner, channel: u32, handle: u32) ?image.Image {
        if (!self.valid() or !self.table.published(channel, handle)) return null;
        for (&self.table.entries, 0..) |*entry, i| if (entry.*) |descriptor| {
            if (descriptor.channel == channel and descriptor.handle == handle) {
                if (self.consoles[i]) |held| return held.imageInfo(self.table.epoch, handle, channel) catch null;
                const plan = self.surfaces[i] orelse return null;
                return image.create(plan, handle, channel) catch null;
            }
        };
        return null;
    }
    pub fn publishedStorage(self: *Owner, channel: u32, handle: u32) ?*vram.storage.Use {
        if (self.publishedImage(channel, handle) == null) return null;
        for (&self.table.entries, 0..) |*entry, i| if (entry.*) |descriptor| {
            if (descriptor.channel == channel and descriptor.handle == handle) return if (self.consoles[i] == null) &self.storage[i] else null;
        };
        return null;
    }
    pub fn publishedCursorStorage(self: *Owner, handle: u32) ?*vram.storage.Use {
        if (!self.valid() or !self.table.published(0, handle)) return null;
        const index = self.table.indexOf(0, handle) orelse return null;
        if (self.table.entries[index].?.target != .vram or self.consoles[index] != null or self.surfaces[index] != null) return null;
        return &self.storage[index];
    }
    pub fn createNotifier(self: *Owner, ctx: *const r4os.r4dev.DriverContext, channel: u32) Error!u32 {
        if (!self.valid()) return error.Stale;
        if (channel >= self.notifiers.len) return error.Bounds;
        if (self.table.uploading or self.table.change != null or self.notifiers[channel].self_address != 0) return error.Busy;
        if (self.table.count >= layout.capacity or self.table.revision == std.math.maxInt(u64)) return error.Exhausted;
        const index = self.table.freeIndex() orelse return error.Exhausted;
        const dynamic = if (self.table.uploaded_revision != 0)
            try self.session.?.rm_names.reserveChildren(self.reservation.?.parent, 1) else null;
        errdefer if (dynamic) |lease| self.session.?.rm_names.retireChildren(lease) catch {};
        const handle = if (dynamic) |lease| try lease.object(0) else try self.reservation.?.object(@intCast(index));
        const note = &self.notifiers[channel];
        note.open(ctx, self.instance_stamp.?.adapter, self.table.epoch, channel, handle) catch |err| {
            if (note.failed) self.quarantine(); return err;
        };
        self.table.add(.{ .channel = channel, .handle = handle, .physical = note.physical_stamp, .bytes = 4096, .target = .coherent_system }) catch |err| {
            if (!note.closeUnpublished()) { self.quarantine(); return error.Retained; } return err;
        };
        self.dynamic_names[index] = dynamic;
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
        for (&self.dynamic_names) |lease| if (lease) |held| self.session.?.rm_names.retainChildren(held) catch {};
        if (self.reservation) |reservation| self.session.?.rm_names.retainChildren(reservation) catch {};
    }
    pub fn closeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence) Error!void {
        if (self.self_address == 0) return;
        if (self.self_address != @intFromPtr(self) or self.session == null or self.binding == null or
            !std.meta.eql(self.binding, self.binding_stamp) or !proof.valid(self.binding.?.epoch) or
            self.session.?.epoch != self.binding.?.epoch) return error.Stale;
        if (self.reservation) |held| try self.session.?.rm_names.validateChildrenAfterReset(held, proof);
        for (&self.storage) |*use| if (!use.closeAfterReset(proof)) return error.Retained;
        for (&self.consoles) |*slot| if (slot.*) |held| {
            if (held.consumer != @intFromPtr(self) or held.epoch != self.binding.?.epoch) return error.Stale;
            held.invalidate(); held.consumer = 0; slot.* = null;
        };
        for (&self.notifiers) |*note| if (!note.closeAfterReset(proof)) return error.Retained;
        for (&self.dynamic_names) |*lease| if (lease.*) |held| {
            try self.session.?.rm_names.retireChildrenAfterReset(held, proof); lease.* = null;
        };
        if (self.reservation) |held| try self.session.?.rm_names.retireChildrenAfterReset(held, proof);
        self.* = .{};
    }
    // No ordinary close: a freed command channel does not prove its last
    // scanout image stopped being fetched. A later display recovery/handoff
    // owner must establish physical resource retirement before release.
};
fn surfaceHash(plan: vram.surface.Plan) u64 {
    var digest = std.hash.Wyhash.init(0); std.hash.autoHash(&digest, plan); return digest.final();
}
