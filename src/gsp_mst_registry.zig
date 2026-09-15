//! Resident RM display-ID ownership across MST recaptures. Catalog changes
//! never free a referenced ID; only real detached images and RM Free ACKs do.
const std = @import("std");
const topology = @import("gsp_mst_topology.zig");
const wire = @import("gsp_mst_wire.zig");
const control = @import("gsp_mst_control.zig");
pub const Handle = struct { epoch: u64, serial: u64, slot: u8 };
pub const StreamLease = struct { epoch: u64, root: u32, serial: u64 };
pub const Key = struct { root: u32 = 0, root_guid: wire.Guid = @splat(0), branch_guid: wire.Guid = @splat(0), route: wire.Route = .{}, port: u4 = 0 };
pub const State = enum { vacant, reserved, allocated, verified, unavailable, retiring };
pub const Image = struct { head: u32, window: u32, dma: u32, core_point: u64, window_point: u64 };
pub const RouteHold = struct { head: u32, window: u32 };
pub const Slot = struct {
    serial: u64 = 0,
    key: Key = .{},
    state: State = .vacant,
    generation: u64 = 0,
    source_receipt: u64 = 0,
    sink: u8 = 0,
    sor: u32 = 0,
    link: u32 = 0,
    display_id: u32 = 0,
    allocation_receipt: u64 = 0,
    resource_receipt: u64 = 0,
    detach_receipt: u64 = 0,
    pending: enum { none, allocate, free } = .none,
    published: bool = false,
    image: ?Image = null,
    stream_lease: ?StreamLease = null,
    route_hold: ?RouteHold = null,
};
const Root = struct { id: u32 = 0, generation: u64 = 0, receipt: u64 = 0 };
pub const Registry = struct {
    epoch: u64 = 0,
    next_serial: u64 = 0,
    physical_mask: u32 = 0,
    roots: [8]Root = @splat(.{}),
    slots: [32]Slot = @splat(.{}),
    fn key(graph: *const topology.Graph, index: usize) !Key {
        if (index >= graph.sink_count) return error.Bounds;
        const sink = &graph.sinks[index];
        if (sink.edge >= graph.edge_count) return error.Descriptor;
        const edge = &graph.edges[sink.edge];
        if (edge.branch >= graph.branch_count or edge.port.input or (!edge.port.connected and !edge.port.legacy_connected)) return error.Descriptor;
        const branch = &graph.branches[edge.branch];
        const guid = (branch.descriptor orelse return error.Descriptor).guid;
        const root_guid = (graph.branches[0].descriptor orelse return error.Descriptor).guid;
        if (!branch.route.valid() or std.mem.allEqual(u8, &guid, 0) or std.mem.allEqual(u8, &root_guid, 0)) return error.Descriptor;
        return .{ .root = graph.root, .root_guid = root_guid, .branch_guid = guid, .route = branch.route, .port = edge.port.number };
    }
    fn find(self: *Registry, value: Key) ?*Slot {
        for (&self.slots) |*entry| if (entry.state != .vacant and std.meta.eql(entry.key, value)) return entry;
        return null;
    }
    fn slot(self: *Registry, value: Handle) !*Slot {
        if (self.epoch == 0 or value.epoch != self.epoch or value.slot >= self.slots.len or value.serial == 0) return error.Stale;
        const current = &self.slots[value.slot];
        if (current.serial != value.serial or current.state == .vacant) return error.Stale;
        return current;
    }
    pub fn handle(self: *const Registry, index: usize) !Handle {
        if (self.epoch == 0 or index >= self.slots.len or self.slots[index].state == .vacant) return error.Stale;
        return .{ .epoch = self.epoch, .serial = self.slots[index].serial, .slot = @intCast(index) };
    }
    /// A prepared root transaction owns both old and candidate IDs, including
    /// the interval before any new image has reached Core/Window completion.
    /// Preflight the entire set before changing a single resident slot.
    pub fn holdStreams(self: *Registry, lease: StreamLease, handles: []const Handle) !void {
        if (lease.epoch == 0 or lease.epoch != self.epoch or lease.serial == 0 or lease.root == 0 or
            lease.root & (lease.root - 1) != 0 or handles.len == 0 or handles.len > 16) return error.Descriptor;
        for (handles, 0..) |handle_value, index| {
            const entry = try self.slot(handle_value);
            for (handles[0..index]) |previous| if (std.meta.eql(previous, handle_value)) return error.Duplicate;
            if (entry.key.root != lease.root or entry.display_id == 0 or entry.pending != .none or
                (entry.state != .verified and entry.state != .retiring) or entry.stream_lease != null) return error.Retained;
        }
        for (handles) |handle_value| self.slots[handle_value.slot].stream_lease = lease;
    }
    /// The transaction owner calls this only after commit, acknowledged
    /// rollback, or cancellation before its first posted hardware effect.
    pub fn releaseStreams(self: *Registry, lease: StreamLease, handles: []const Handle) !void {
        if (lease.epoch != self.epoch or lease.serial == 0 or handles.len == 0 or handles.len > 16) return error.Stale;
        for (handles, 0..) |handle_value, index| {
            const entry = try self.slot(handle_value);
            for (handles[0..index]) |previous| if (std.meta.eql(previous, handle_value)) return error.Duplicate;
            if (entry.stream_lease == null or !std.meta.eql(entry.stream_lease.?, lease)) return error.Stale;
        }
        for (handles) |handle_value| self.slots[handle_value.slot].stream_lease = null;
    }
    /// Reserve new keys atomically after capacity preflight. Missing keys
    /// remain in retiring slots until their images and RM IDs are released.
    pub fn synchronize(self: *Registry, graph: *const topology.Graph, sor: u32, link: u32, physical_mask: u32) !void {
        if (!graph.coherent or graph.epoch == 0 or graph.generation == 0 or graph.root == 0 or graph.root & (graph.root - 1) != 0 or
            graph.completion_receipt == 0 or graph.branch_count == 0 or graph.branch_count > topology.max_branches or
            graph.sink_count > topology.max_sinks or graph.edge_count > topology.max_edges or sor >= 8 or link > 1 or
            graph.root & physical_mask == 0 or (self.epoch != 0 and self.epoch != graph.epoch)) return error.Stale;
        var root: ?*Root = null;
        for (&self.roots) |*entry| if (entry.id == graph.root) {
            root = entry;
            break;
        };
        if (root) |entry| {
            if (entry.generation >= graph.generation or entry.receipt >= graph.completion_receipt) return error.Stale;
        } else for (&self.roots) |*entry| if (entry.id == 0) {
            root = entry;
            break;
        };
        if (root == null) return error.Capacity;
        var available: usize = 0;
        for (&self.slots) |*entry| {
            if (entry.pending != .none) return error.Pending;
            if (entry.state == .vacant) available += 1;
            if (entry.display_id & physical_mask != 0) return error.Descriptor;
        }
        var keys: [topology.max_sinks]Key = @splat(.{});
        var reclaim: [32]bool = @splat(false);
        var needed: usize = 0;
        for (0..graph.sink_count) |i| {
            keys[i] = try key(graph, i);
            for (keys[0..i]) |*prior| if (std.meta.eql(prior.*, keys[i])) return error.Duplicate;
            if (self.find(keys[i])) |existing| {
                if (existing.sor != sor or existing.link != link) return error.Stale;
            } else needed += 1;
        }
        for (&self.slots, 0..) |*entry, index| {
            if (entry.state == .vacant or entry.key.root != graph.root or entry.display_id != 0) continue;
            // Unallocated keys cannot pin the table after a hub recapture.
            // Allocated or displayed entries still require explicit retirement.
            if (entry.image != null or entry.published or entry.stream_lease != null or entry.route_hold != null) return error.Descriptor;
            var retained = false;
            for (keys[0..graph.sink_count]) |value| if (std.meta.eql(entry.key, value)) {
                retained = true;
                break;
            };
            if (!retained) {
                reclaim[index] = true;
                available += 1;
            }
        }
        if (needed > available or needed > std.math.maxInt(u64) - self.next_serial) return error.Capacity;
        self.epoch = graph.epoch;
        self.physical_mask |= physical_mask;
        root.?.* = .{ .id = graph.root, .generation = graph.generation, .receipt = graph.completion_receipt };
        for (&self.slots, reclaim) |*entry, release| if (release) { entry.* = .{}; };
        for (keys[0..graph.sink_count], 0..) |value, index| {
            const entry = self.find(value) orelse blk: {
                for (&self.slots) |*available_slot| if (available_slot.state == .vacant) {
                    self.next_serial += 1;
                    available_slot.* = .{ .serial = self.next_serial, .key = value, .state = .reserved, .sor = sor, .link = link };
                    break :blk available_slot;
                };
                unreachable; // Capacity was checked before the first mutation.
            };
            entry.generation = graph.generation;
            entry.source_receipt = graph.completion_receipt;
            entry.sink = @intCast(index);
            if (entry.state == .verified) entry.state = .allocated;
            if (entry.state == .retiring) entry.state = if (entry.display_id == 0) .reserved else .allocated;
            if (entry.state == .unavailable) entry.state = .reserved;
        }
        for (&self.slots) |*entry| if (entry.state != .vacant and entry.key.root == graph.root and entry.generation != graph.generation) {
            if (entry.display_id == 0) entry.* = .{} else entry.state = .retiring;
        };
    }
    pub fn allocate(self: *Registry, value: Handle) !control.Query {
        const entry = try self.slot(value);
        if (entry.state != .reserved or entry.pending != .none or entry.display_id != 0) return error.State;
        entry.pending = .allocate;
        return .{ .allocate = entry.key.root };
    }
    pub fn allocated(self: *Registry, value: Handle, id: u32, serial: u64) !void {
        const entry = try self.slot(value);
        if (entry.state != .reserved or entry.pending != .allocate or serial <= entry.source_receipt or
            id == 0 or id & (id - 1) != 0 or id & self.physical_mask != 0) return error.Stale;
        for (&self.slots) |*other| if (other.display_id == id) return error.Duplicate;
        entry.display_id = id;
        entry.allocation_receipt = serial;
        entry.pending = .none;
        entry.state = .allocated;
    }
    pub fn allocationRejected(self: *Registry, value: Handle, serial: u64) !void {
        const entry = try self.slot(value);
        if (entry.state != .reserved or entry.pending != .allocate or serial <= entry.source_receipt) return error.Stale;
        entry.pending = .none;
        entry.state = .unavailable;
    }
    /// Only after the resident Exchange cancelled an unsubmitted request.
    /// Posted requests must instead drain their allocation/free RM reply.
    pub fn cancelled(self: *Registry, value: Handle) !void {
        const entry = try self.slot(value);
        if (entry.pending == .allocate) {
            if (entry.state != .reserved or entry.display_id != 0) return error.State;
        } else if (entry.pending == .free) {
            if (entry.state != .retiring or entry.display_id == 0) return error.State;
        } else return error.State;
        entry.pending = .none;
    }
    /// Called only with GET_OUTPUT_RESOURCE_PARAMS returned for this ID.
    pub fn resource(self: *Registry, value: Handle, observed: anytype, serial: u64) !void {
        const entry = try self.slot(value);
        if (entry.state != .allocated or entry.pending != .none or serial <= entry.source_receipt or serial <= entry.allocation_receipt or
            !observed.dynamic or observed.root_port_id != entry.key.root or observed.index != entry.sor or observed.kind != 2 or
            observed.protocol != 8 + entry.link or observed.location != 0) return error.Stale;
        entry.resource_receipt = serial;
        entry.state = .verified;
    }
    pub fn publish(self: *Registry, value: Handle, generation: u64) !void {
        const entry = try self.slot(value);
        if (entry.state != .verified or entry.pending != .none or entry.generation != generation or entry.resource_receipt <= entry.source_receipt) return error.Stale;
        entry.published = true;
    }
    /// The common output retains a CPU image and a Head/Window route while
    /// unplugged. Keep its RM ID/key until that route is explicitly released;
    /// source-stop leases and physical image ownership remain independent.
    pub fn holdRoute(self: *Registry, value: Handle, route: RouteHold) !void {
        const entry = try self.slot(value);
        if (entry.state != .verified or entry.pending != .none or entry.display_id == 0 or route.head >= 8 or route.window >= 8 or
            (entry.route_hold != null and !std.meta.eql(entry.route_hold.?, route))) return error.Stale;
        for (&self.slots) |*peer| if (peer != entry and peer.route_hold != null and
            (peer.route_hold.?.head == route.head or peer.route_hold.?.window == route.window)) return error.Retained;
        entry.route_hold = route;
    }
    pub fn releaseRoute(self: *Registry, value: Handle, route: RouteHold) !void {
        const entry = try self.slot(value);
        if (entry.route_hold == null or !std.meta.eql(entry.route_hold.?, route) or entry.pending != .none or
            entry.image != null or entry.published or entry.stream_lease != null) return error.Retained;
        entry.route_hold = null;
    }
    fn image(value: anytype) !Image {
        const mode = value.boot_mode orelse return error.Descriptor;
        if (mode.head >= 8 or mode.window >= 8 or value.image.dma == 0 or value.core_point == 0 or value.window_point == 0 or
            value.link == null or !value.link.?.complete()) return error.Descriptor;
        return .{ .head = mode.head, .window = mode.window, .dma = value.image.dma, .core_point = value.core_point, .window_point = value.window_point };
    }
    /// Accept the actual completed Runtime DisplayImage, including its link
    /// proof. Call again after a flip so retirement matches the latest image.
    pub fn activated(self: *Registry, value: Handle, displayed: anytype) !void {
        const entry = try self.slot(value);
        const mode = displayed.boot_mode orelse return error.Descriptor;
        if (entry.pending != .none or mode.epoch != self.epoch or mode.signal.display_id != entry.display_id or
            mode.signal.sor != entry.sor) return error.Stale;
        if (entry.image == null) {
            // Hardware completes before common output publication. Retain
            // that real image even if the later API publication fails.
            if (entry.state != .verified or mode.output_generation != entry.generation) return error.Stale;
        } else if ((entry.state != .verified and entry.state != .allocated and entry.state != .retiring) or
            mode.output_generation > entry.generation) return error.Stale;
        const active = try image(displayed);
        if (entry.image) |prior| if (active.head != prior.head or active.window != prior.window or active.core_point < prior.core_point or active.window_point <= prior.window_point) return error.Stale;
        entry.image = active;
    }
    pub fn retire(self: *Registry, value: Handle) !void {
        const entry = try self.slot(value);
        if (entry.pending != .none) return error.Pending;
        if (entry.display_id == 0) entry.* = .{} else entry.state = .retiring;
    }
    pub fn unpublish(self: *Registry, value: Handle) !void {
        const entry = try self.slot(value);
        if (entry.state == .vacant or entry.pending != .none) return error.State;
        entry.published = false;
    }
    /// Runtime's retirement is created only after Core, NULL Window, ARM
    /// readback and link/payload stop have completed. Its saved prior image
    /// must match; an old retirement cannot release a newer flip or mode.
    pub fn detached(self: *Registry, value: Handle, retirement: anytype) !void {
        const entry = try self.slot(value);
        const active = entry.image orelse return error.State;
        const mode = retirement.image.boot_mode orelse return error.Descriptor;
        if (entry.pending != .none or retirement.epoch != self.epoch or mode.epoch != self.epoch or mode.signal.display_id != entry.display_id or
            !std.meta.eql(active, try image(retirement.image)) or retirement.core_point <= active.core_point or retirement.window_point <= active.window_point or
            retirement.observed_ns == 0 or retirement.link_stop_receipt <= entry.allocation_receipt) return error.Stale;
        entry.image = null;
        entry.detach_receipt = retirement.link_stop_receipt;
    }
    pub fn free(self: *Registry, value: Handle) !control.Query {
        const entry = try self.slot(value);
        if (entry.state != .retiring or entry.pending != .none or entry.display_id == 0 or entry.published or entry.image != null or
            entry.stream_lease != null or entry.route_hold != null) return error.Retained;
        entry.pending = .free;
        return .{ .free = entry.display_id };
    }
    pub fn freed(self: *Registry, value: Handle, serial: u64) !void {
        const entry = try self.slot(value);
        if (entry.state != .retiring or entry.pending != .free or entry.published or entry.image != null or entry.stream_lease != null or entry.route_hold != null or
            serial <= @max(entry.source_receipt, @max(entry.allocation_receipt, @max(entry.resource_receipt, entry.detach_receipt)))) return error.Stale;
        entry.* = .{};
    }
    pub fn freeRejected(self: *Registry, value: Handle, serial: u64) !void {
        const entry = try self.slot(value);
        if (entry.state != .retiring or entry.pending != .free or serial <= @max(entry.source_receipt, @max(entry.allocation_receipt, @max(entry.resource_receipt, entry.detach_receipt)))) return error.Stale;
        entry.pending = .none;
        // Keep the ID, including on RM failure; the Runtime decides whether
        // a later bounded retry or recovery is appropriate.
    }
};
