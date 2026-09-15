//! Live RM graph loan for one physical MST root. The catalog provides the
//! initial identity; every AUX capability, mode change and virtual ID below
//! is acknowledged on the same retained Channel before it can be published.
const std = @import("std");
const rm = @import("gsp_rm_graph.zig");
const display = @import("gsp_display_rpc.zig");
const catalog = @import("gsp_topology.zig");
const receiver = @import("gsp_receiver.zig");
const topology = @import("gsp_mst_topology.zig");
const transport = @import("gsp_mst_transport.zig");
const upstream = @import("gsp_mst_upstream.zig");
const mailbox = @import("gsp_mst_drain.zig");
const ids = @import("gsp_mst_registry.zig");
const wire = @import("gsp_mst_wire.zig");
const caps = @import("gsp_link_caps.zig");
pub const Root = struct {
    id: u32 = 0,
    graph: topology.Graph = .{},
    sequence: u1 = 0,
    enabled_receipt: u64 = 0,
    resource: ?display.Resource = null,
    source: ?caps.DpSource = null,
    dpcd: [16]u8 = @splat(0),
    mailbox_pending: bool = false,
    mailbox_deadline: u64 = 0,
    failure: ?anyerror = null,
    live: @import("gsp_mst_budget.zig").State = .{},
    captured_table: @import("gsp_mst_budget.zig").Table = .{},
    stream_serial: u64 = 0,
    transaction: @import("gsp_mst_transaction.zig").Journal = .{},
    payload_dirty: bool = false,
};
pub const Store = struct {
    seed: wire.Guid = @splat(0),
    registry: ids.Registry = .{},
    roots: [8]Root = @splat(.{}),
    pub fn root(self: *Store, id: u32) !*Root {
        if (id == 0 or id & (id - 1) != 0) return error.Descriptor;
        for (&self.roots) |*entry| if (entry.id == id) return entry;
        for (&self.roots) |*entry| if (entry.id == 0) {
            entry.id = id;
            return entry;
        };
        return error.Capacity;
    }
    pub fn invalidate(self: *Store, id: u32) void {
        for (&self.roots) |*entry| if (entry.id == id) { entry.graph.coherent = false; };
        for (&self.registry.slots) |*entry| if (entry.key.root == id and entry.state != .vacant and entry.pending == .none) {
            if (entry.display_id == 0) entry.* = .{} else entry.state = .retiring;
        };
    }
    /// Merge only a verified virtual RM resource and a completed remote EDID
    /// from this capture. The root's optional EDID is never used for a leaf.
    pub fn capture(self: *const Store, route: *const catalog.Route, target: *receiver.Capture,
        epoch: u64, client: u32, generation: u64) bool
    {
        const resource = route.resource orelse return false;
        if (!resource.dynamic or epoch != self.registry.epoch) return false;
        for (&self.registry.slots) |*entry| {
            if (entry.display_id != route.id or entry.state != .verified or entry.generation != generation or
                entry.key.root != resource.root_port_id or entry.sor != resource.index or resource.protocol != 8 + entry.link or
                resource.kind != 2 or resource.location != 0 or entry.resource_receipt <= entry.source_receipt) continue;
            for (&self.roots) |*root_entry| {
                const graph = &root_entry.graph;
                if (root_entry.id != entry.key.root or !graph.coherent or graph.epoch != epoch or graph.generation != generation or
                    graph.completion_receipt != entry.source_receipt or entry.sink >= graph.sink_count) continue;
                const sink = &graph.sinks[entry.sink];
                target.* = .{ .epoch = epoch, .client = client, .display_id = route.id, .receipt_serial = entry.resource_receipt,
                    .status = switch (sink.state) { .valid => .valid_edid, .incomplete => .incomplete_edid, .missing => .edid_missing,
                        .invalid => .invalid_edid, .unsupported => .unsupported_data, .pending => return false },
                    .connected = true, .resource = resource, .source = .mst, .edid_bytes = sink.edid_bytes };
                @memcpy(target.bytes[0..sink.edid_bytes], sink.bytes[0..sink.edid_bytes]);
                target.report = sink.report;
                if (sink.caps) |dpcd| { target.aux_caps = dpcd; target.aux_caps_bytes = 16; }
                return true;
            }
        }
        return false;
    }
};
pub const Stage = enum { supported, connected, resource, source, dpcd, extended_dpcd, mst_caps, control, heads, active, enable, verify_enable,
    mailbox, clear_status, clear_table, clear_updated, clear_branches, clear_verify, topology, events,
    root_connected, root_resource, allocate, allocated_mask, allocated_resource, final_supported, final_connected, final_resource, drain, complete, obsolete, released };
pub const Work = struct {
    self_address: usize = 0,
    parent: *rm.Owner,
    channel: display.Channel,
    store: *Store,
    root: *Root,
    generation: u64,
    deadline: u64,
    resource: display.Resource,
    source: caps.DpSource,
    dpcd: [16]u8,
    physical_mask: u32,
    expected_mask: display.Supported,
    heads: [8]u32 = @splat(0),
    head_count: u32,
    head_cursor: u32 = 0,
    occupied: bool = false,
    owned: bool = true,
    stage: Stage = .supported,
    invalidated: bool = false,
    last_receipt: u64 = 0,
    builder: ?topology.Builder = null,
    down: ?transport.Work = null,
    up: ?upstream.Work = null,
    mailbox: ?mailbox.Work = null,
    action: ?topology.Action = null,
    query: ?display.Query = null,
    current: ?ids.Handle = null,
    slot_cursor: usize = 0,
    events_seen: u8 = 0,
    restart: bool = false,
    enable_needed: bool = false,
    clear_required: bool = false,
    clear_complete: bool = false,
    clear_part: u8 = 0,
    clear_polls: u16 = 0,
    after_events: Stage = .topology,
    retry_query: ?display.Query = null,
    not_before: u64 = 0,
    retries: u8 = 0,
    revision: u64,

    pub fn capable(value: *const receiver.Capture) bool {
        const resource = value.resource orelse return false;
        const source = value.dp.source orelse return false;
        return value.connected == true and display.nativeDp(resource) and resource.location == 0 and resource.index < 8 and
            value.dp.source_state == .complete and source.mst and value.dp.dpcd_state == .complete and
            value.dp.receiver.mst_state == .complete and value.dp.receiver.mst;
    }
    pub fn init(parent: *rm.Owner, store: *Store, observed: *const catalog.Catalog, capture: *const receiver.Capture,
        generation: u64, deadline: u64) !Work
    {
        if (parent.state != .ready or !capable(capture) or generation == 0 or capture.epoch != observed.epoch or
            capture.client != observed.client or observed.rejected != null or capture.receipt_serial == 0 or
            std.mem.allEqual(u8, &store.seed, 0)) return error.Descriptor;
        const head_count = observed.head_count orelse return error.Descriptor;
        if (head_count > 8) return error.Unsupported;
        var physical_port = false;
        for (observed.routes[0..observed.count]) |*route| if (route.id == capture.display_id) {
            const connectors = route.connectors orelse return error.Unsupported;
            if (!connectors.present() or connectors.count != 1 or
                (connectors.data[0].kind != 0x46 and connectors.data[0].kind != 0x48)) return error.Unsupported;
            physical_port = true;
        };
        if (!physical_port) return error.Descriptor;
        const resource = capture.resource.?;
        var physical: u32 = 0;
        var occupied = false;
        var owned = true;
        var heads: [8]u32 = @splat(0);
        for (observed.routes[0..observed.count]) |*route| if (route.resource) |value| {
            if (!value.dynamic) physical |= route.id;
        };
        if (capture.display_id & physical == 0) return error.Descriptor;
        for (observed.heads[0..head_count], 0..) |head, index| {
            const id = head.display_id orelse return error.Descriptor;
            heads[index] = id;
            if (id == 0) continue;
            var resolved = false;
            for (observed.routes[0..observed.count]) |*route| if (route.id == id) {
                const current_resource = route.resource orelse return error.Descriptor;
                resolved = true;
                if (current_resource.index != resource.index) break;
                occupied = true;
                var ours = false;
                for (&store.registry.slots) |*entry| if (entry.display_id == id and entry.key.root == capture.display_id and
                    entry.state != .vacant and entry.image != null and entry.image.?.head == index) { ours = true; };
                owned = owned and ours;
                break;
            };
            if (!resolved) return error.Descriptor;
        }
        const expected_mask = observed.supported orelse return error.Descriptor;
        const root = try store.root(capture.display_id);
        // A returning hub cannot reuse an incompletely retired source table.
        // Its heads still own all RM IDs until their last source-stop ACK.
        if (root.transaction.phase != .vacant) return error.Busy;
        if ((!occupied and root.live.table.count != 0) or (occupied and root.payload_dirty)) return error.Busy;
        root.failure = null;
        root.graph.coherent = false;
        var loan = try parent.loan(deadline);
        const channel = try display.Channel.init(&loan.runtime, loan.object, deadline);
        return .{ .parent = parent, .channel = channel, .store = store, .root = root, .generation = generation, .deadline = deadline,
            .resource = resource, .source = capture.dp.source.?, .dpcd = capture.dp.dpcd, .physical_mask = physical,
            .expected_mask = expected_mask, .head_count = head_count, .heads = heads,
            .occupied = occupied, .owned = owned, .clear_required = !occupied, .revision = channel.exchange.revision };
    }
    pub fn invalidate(self: *Work) !void {
        self.invalidated = true;
        self.root.graph.coherent = false;
        if (self.builder) |*builder| builder.invalidate();
        if (self.down) |*down| down.invalidate();
        if (self.up) |*up| up.invalidate();
        if (self.mailbox) |*drain| drain.stage = .cancelled;
        try self.channel.invalidate();
    }
    pub fn matches(self: *const Work, current: *const @import("gsp_exchange.zig").Exchange, deadline: u64) bool {
        return self.self_address == @intFromPtr(self) and self.query != null and self.channel.matches(current, self.query.?, deadline);
    }
    fn failed(self: *Work, reason: anyerror) void {
        self.root.failure = reason;
        self.store.invalidate(self.root.id);
        self.stage = .drain;
    }
    fn mst(self: *const Work, operation: display.aux_wire.Mst) display.Query {
        return .{ .aux = .{ .display_id = self.root.id, .operation = .{ .mst = operation } } };
    }
    fn prepare(self: *Work, now: u64) !?display.Query {
        if (now < self.not_before) return null;
        if (self.retry_query) |query| return query;
        return switch (self.stage) {
            .supported, .allocated_mask, .final_supported => .supported,
            .connected, .root_connected, .final_connected => .{ .connected = self.root.id },
            .resource, .root_resource, .final_resource => .{ .resource = self.root.id },
            .source => .{ .dp_source = .{ .display_id = self.root.id, .sor = self.resource.index } },
            .dpcd => .{ .aux = .{ .display_id = self.root.id, .operation = .caps } },
            .extended_dpcd => .{ .aux = .{ .display_id = self.root.id, .operation = .extended_caps } },
            .mst_caps => .{ .aux = .{ .display_id = self.root.id, .operation = .mst_caps } },
            .control, .verify_enable => self.mst(.{ .control = null }),
            .heads => .heads,
            .active => .{ .active = self.head_cursor },
            .enable => self.mst(.{ .control = 7 }),
            .clear_status => self.mst(.{ .payload_status = true }),
            .clear_table => self.mst(.{ .payload = .{ .id = 0, .start = 0, .count = 63 } }),
            .clear_updated => self.mst(.{ .payload_status = false }),
            .clear_verify => self.mst(.{ .payload_table = @intCast(self.clear_part) }),
            .clear_branches => blk: {
                if (self.down == null) {
                    self.root.sequence ^= 1;
                    self.down = try transport.Work.init(self.root.id, self.generation, self.deadline, .{}, self.root.sequence, .clear);
                }
                const work = &self.down.?;
                if (work.stage == .complete) {
                    const reply = try work.result(self.generation);
                    self.root.mailbox_pending = false; self.root.mailbox_deadline = 0;
                    if (reply != .ack or reply.ack != .clear) return error.BranchRejected;
                    const up_pending = work.up_pending;
                    self.down = null; self.clear_part = 0;
                    if (up_pending) {
                        self.up = try upstream.Work.init(self.root.id, self.generation, self.deadline);
                        self.after_events = .clear_verify; self.stage = .events;
                    } else self.stage = .clear_verify;
                    break :blk null;
                }
                break :blk if (try work.prepare(self.generation, now)) |query| .{ .aux = query } else null;
            },
            .allocated_resource => .{ .resource = self.store.registry.slots[self.current.?.slot].display_id },
            .allocate => blk: {
                const query = try self.store.registry.allocate(self.current.?);
                break :blk .{ .mst_allocate = query.allocate };
            },
            .mailbox => blk: {
                const drain = &self.mailbox.?;
                if (drain.stage == .complete) {
                    self.root.mailbox_pending = false;
                    self.root.mailbox_deadline = 0;
                    if (drain.up_pending) {
                        self.up = try upstream.Work.init(self.root.id, self.generation, self.deadline);
                        self.stage = .events;
                    } else self.stage = .topology;
                    self.mailbox = null;
                    break :blk null;
                }
                break :blk if (try drain.prepare(self.generation, now)) |query| .{ .aux = query } else null;
            },
            .topology => blk: {
                if (self.clear_required and !self.clear_complete) {
                    // All physical heads were just queried on this Channel.
                    // Clear stale sink reservations before EPR admission, and
                    // retain the dirty marker on any ambiguous write/timeout.
                    if (self.occupied or self.root.live.table.count != 0) return error.Busy;
                    self.root.payload_dirty = true;
                    self.stage = .clear_status;
                    break :blk null;
                }
                if (self.down) |*down| {
                    if (down.stage == .complete) {
                        self.root.mailbox_pending = false;
                        self.root.mailbox_deadline = 0;
                        try self.builder.?.consume(self.generation, .{ .sideband = try down.result(self.generation) }, down.completion_receipt, now);
                        const up_pending = down.up_pending;
                        self.action = null;
                        self.down = null;
                        if (up_pending) {
                            self.up = try upstream.Work.init(self.root.id, self.generation, self.deadline);
                            self.stage = .events;
                            break :blk null;
                        }
                    } else break :blk if (try down.prepare(self.generation, now)) |query| .{ .aux = query } else null;
                }
                if (try self.builder.?.prepare(self.generation, now)) |action| {
                    self.action = action;
                    switch (action) {
                        .root_aux => |query| break :blk self.mst(query),
                        .sideband => |query| {
                            self.root.sequence ^= 1;
                            self.down = try transport.Work.init(self.root.id, self.generation, self.deadline, query.route, self.root.sequence, query.request);
                            break :blk .{ .aux = (try self.down.?.prepare(self.generation, now)).? };
                        },
                    }
                }
                // No virtual IDs are allocated before a complete, rechecked tree.
                try self.store.registry.synchronize(&self.root.graph, self.resource.index, self.resource.protocol - 8, self.physical_mask);
                self.root.captured_table = self.root.live.table;
                self.slot_cursor = 0;
                try self.nextSlot();
                break :blk null;
            },
            .events => blk: {
                const up = &self.up.?;
                if (up.stage == .received) {
                    const notice = try up.notification(self.generation);
                    const identity = switch (notice) { .connection => |v| .{ v.guid, v.port }, .resources => |v| .{ v.guid, v.port } };
                    var matched = false;
                    for (self.root.graph.branches[0..self.root.graph.branch_count]) |*branch| {
                        const descriptor = branch.descriptor orelse continue;
                        if (!std.meta.eql(branch.route, up.assembly.?.route) or !std.mem.eql(u8, &descriptor.guid, &identity[0])) continue;
                        for (descriptor.ports[0..descriptor.count]) |port| if (port.number == identity[1]) { matched = true; };
                    }
                    try up.respond(self.generation, now, matched);
                    self.restart = true; // Query again; never apply notification data as a catalog.
                    self.events_seen += 1;
                }
                if (up.stage == .complete or up.stage == .empty) {
                    if (self.events_seen > 8) return error.RetryExhausted;
                    if (self.restart) {
                        self.builder = try topology.Builder.init(&self.root.graph, self.channel.object.epoch, self.generation,
                            self.root.id, self.store.seed, self.last_receipt, self.deadline);
                        self.restart = false;
                    }
                    self.up = null;
                    self.stage = self.after_events; self.after_events = .topology;
                    break :blk null;
                }
                break :blk if (try up.prepare(self.generation, now)) |query| .{ .aux = query } else null;
            },
            .drain, .complete, .obsolete, .released => null,
        };
    }
    fn nextSlot(self: *Work) !void {
        while (self.slot_cursor < self.store.registry.slots.len) : (self.slot_cursor += 1) {
            const entry = &self.store.registry.slots[self.slot_cursor];
            if (entry.key.root != self.root.id or entry.generation != self.generation or
                (entry.state != .reserved and entry.state != .allocated)) continue;
            self.current = try self.store.registry.handle(self.slot_cursor);
            self.stage = if (entry.state == .reserved) .root_connected else .allocated_resource;
            self.slot_cursor += 1;
            return;
        }
        self.current = null;
        self.stage = .final_supported;
    }
    fn auxAck(reply: display.Reply, count: usize) !display.aux_wire.Reply {
        if (reply != .aux or reply.aux.status != 0 or reply.aux.kind != .ack or reply.aux.count != count) return error.Aux;
        return reply.aux;
    }
    fn consume(self: *Work, reply: display.Reply, serial: u64, now: u64) !void {
        if (serial <= self.last_receipt) return error.Stale;
        self.last_receipt = serial;
        // These effects have to be recorded even when the surrounding capture
        // became obsolete while RM was allocating the display ID.
        if (self.stage == .allocate) {
            if (reply == .mst_allocate) {
                try self.store.registry.allocated(self.current.?, reply.mst_allocate, serial);
                self.stage = .allocated_mask;
            } else if (reply == .rpc_error or reply == .control_error) {
                try self.store.registry.allocationRejected(self.current.?, serial);
                try self.nextSlot();
            } else return error.Unexpected;
            if (self.invalidated) self.failed(error.Stale);
            return;
        }
        if (self.invalidated or reply == .obsolete) return error.Stale;
        if (reply == .rpc_error or reply == .control_error) return error.RmRejected;
        if (reply == .aux and self.down == null and self.up == null and self.mailbox == null) {
            const value = reply.aux;
            if (value.status == 3 or value.status == 0x66 or (value.status == 0 and value.kind == .defer_reply)) {
                const delay = if (value.status == 0) 1 else value.retry_ms;
                if (delay == 0 or delay > 500 or self.retries == 7) return error.RetryExhausted;
                self.retries += 1;
                self.retry_query = self.query;
                self.not_before = try std.math.add(u64, now, @as(u64, delay) * std.time.ns_per_ms);
                return;
            }
            self.retries = 0;
            self.retry_query = null;
            self.not_before = 0;
        }
        switch (self.stage) {
            .supported, .final_supported => {
                if (reply != .supported or !std.meta.eql(reply.supported, self.expected_mask)) return error.Stale;
                self.stage = if (self.stage == .supported) .connected else .final_connected;
            },
            .connected, .root_connected, .final_connected => {
                if (reply != .connected or reply.connected != self.root.id) return error.Stale;
                self.stage = switch (self.stage) { .connected => .resource, .root_connected => .root_resource, .final_connected => .final_resource, else => unreachable };
            },
            .resource, .root_resource, .final_resource => {
                if (reply != .resource or !std.meta.eql(reply.resource, self.resource)) return error.Stale;
                self.stage = switch (self.stage) { .resource => .source, .root_resource => .allocate, .final_resource => .drain, else => unreachable };
            },
            .source => {
                if (reply != .dp_source or !std.meta.eql(try caps.DpSource.decode(&reply.dp_source), self.source)) return error.Stale;
                self.stage = .dpcd;
            },
            .dpcd, .extended_dpcd => {
                const value = try auxAck(reply, 16);
                if (self.stage == .dpcd and value.data[14] & 0x80 != 0) {
                    self.stage = .extended_dpcd;
                    return;
                }
                if (!std.mem.eql(u8, &value.data, &self.dpcd)) return error.Stale;
                self.stage = .mst_caps;
            },
            .mst_caps => {
                const value = try auxAck(reply, 1);
                if (value.data[0] & 1 == 0) return error.Unsupported;
                self.stage = .control;
            },
            .control => {
                const value = try auxAck(reply, 1);
                if (value.data[0] & ~@as(u8, 7) != 0 or (self.occupied and (!self.owned or value.data[0] != 7))) return error.Busy;
                self.enable_needed = value.data[0] != 7;
                self.stage = .heads;
            },
            .heads => {
                if (reply != .heads or reply.heads != self.head_count) return error.Stale;
                self.head_cursor = 0;
                if (self.head_count == 0) {
                    if (self.enable_needed) self.stage = .enable else try self.startTree(serial);
                } else self.stage = .active;
            },
            .active => {
                if (reply != .active or reply.active != self.heads[self.head_cursor]) return error.Stale;
                self.head_cursor += 1;
                if (self.head_cursor == self.head_count) {
                    if (self.enable_needed) self.stage = .enable else try self.startTree(serial);
                }
            },
            .enable => { _ = try auxAck(reply, 1); self.stage = .verify_enable; },
            .verify_enable => {
                const value = try auxAck(reply, 1);
                if (value.data[0] != 7) return error.Stale;
                try self.startTree(serial);
            },
            .clear_status => { _ = try auxAck(reply, 1); self.stage = .clear_table; },
            .clear_table => { _ = try auxAck(reply, 3); self.stage = .clear_updated; },
            .clear_updated => {
                const value = try auxAck(reply, 1);
                if (value.data[0] & 1 == 0) {
                    if (self.clear_polls == 1000) return error.Deadline;
                    self.clear_polls += 1; self.not_before = now +| std.time.ns_per_ms;
                } else self.stage = .clear_branches;
            },
            .clear_branches => {
                if (reply != .aux) return error.Unexpected;
                try self.down.?.consume(self.generation, reply.aux, serial, now);
            },
            .clear_verify => {
                const value = try auxAck(reply, 16);
                const first: usize = if (self.clear_part == 0) 1 else 0;
                if (!std.mem.allEqual(u8, value.data[first..], 0)) return error.Stale;
                self.clear_part += 1;
                if (self.clear_part == 4) {
                    self.root.payload_dirty = false; self.clear_complete = true; self.stage = .topology;
                }
            },
            .topology => {
                if (reply != .aux) return error.Unexpected;
                if (self.down) |*down| try down.consume(self.generation, reply.aux, serial, now) else {
                    if (self.action == null or self.action.? != .root_aux) return error.State;
                    try self.builder.?.consume(self.generation, .{ .root_aux = reply.aux }, serial, now);
                    self.action = null;
                }
            },
            .events => {
                if (reply != .aux) return error.Unexpected;
                try self.up.?.consume(self.generation, reply.aux, serial, now);
            },
            .mailbox => {
                if (reply != .aux) return error.Unexpected;
                try self.mailbox.?.consume(self.generation, reply.aux, serial, now);
            },
            .allocated_mask => {
                const id = self.store.registry.slots[self.current.?.slot].display_id;
                if (reply != .supported or reply.supported.displays != self.expected_mask.displays | id or
                    reply.supported.ddc & ~id != self.expected_mask.ddc) return error.Stale;
                self.expected_mask = reply.supported;
                // SUPPORTED clears the Channel's connected/root-resource proof.
                // Reacquire those before the next allocation, never set them.
                self.stage = .allocated_resource;
            },
            .allocated_resource => {
                if (reply != .resource) return error.Unexpected;
                try self.store.registry.resource(self.current.?, reply.resource, serial);
                try self.nextSlot();
            },
            else => return error.State,
        }
    }
    fn startTree(self: *Work, serial: u64) !void {
        self.root.enabled_receipt = serial;
        self.root.resource = self.resource;
        self.root.source = self.source;
        self.root.dpcd = self.dpcd;
        self.builder = try topology.Builder.init(&self.root.graph, self.channel.object.epoch, self.generation,
            self.root.id, self.store.seed, serial, self.deadline);
        self.mailbox = .{ .root = self.root.id, .generation = self.generation, .deadline = self.deadline,
            .prior_deadline = if (self.root.mailbox_pending) self.root.mailbox_deadline else 0 };
        self.stage = .mailbox;
    }
    pub fn waiting(self: *const Work) bool {
        const now = self.channel.exchange.session.last_clock;
        if (now < self.not_before) return true;
        if (self.down) |*down| if (now < down.not_before) return true;
        if (self.up) |*up| if (now < up.not_before) return true;
        if (self.mailbox) |*drain| if (now < drain.not_before) return true;
        return false;
    }
    pub fn poll(self: *Work) !?display.Dispatch {
        if (self.stage == .released or self.stage == .complete or self.stage == .obsolete) return error.State;
        if (self.self_address != 0 and self.self_address != @intFromPtr(self)) return error.Stale;
        self.self_address = @intFromPtr(self);
        try self.channel.exchange.guard(self.deadline);
        const now = self.channel.exchange.session.last_clock;
        if (self.query != null) {
            const received = self.channel.poll(self.deadline) catch |err| {
                if (err != error.Obsolete) return err;
                if (self.query.? == .mst_allocate) try self.store.registry.cancelled(self.current.?);
                self.query = null;
                self.failed(err);
                return null;
            };
            if (self.channel.exchange.phase == .waiting and self.query.? == .aux and self.query.?.aux.operation == .mst and
                self.query.?.aux.operation.mst == .mailbox) {
                const sent = self.query.?.aux.operation.mst.mailbox;
                if (sent.box == .down_request and self.down != null and @as(usize, sent.offset) + sent.count == self.down.?.packet_count) {
                    self.root.mailbox_pending = true;
                    self.root.mailbox_deadline = self.deadline;
                }
            }
            if (received) |dispatch| {
                if (dispatch.value == .notification) return dispatch;
                // Decode borrowed sideband bytes before completing the ticket;
                // every effect still uses that actual acknowledged receipt.
                self.consume(dispatch.value.reply, dispatch.ticket.serial, now) catch |err| self.failed(err);
                try self.channel.complete(dispatch.ticket);
                self.query = null;
            }
            return null;
        }
        if (self.invalidated) self.failed(error.Stale);
        if (self.channel.exchange.revision != self.revision) self.failed(error.Stale);
        if (self.stage == .drain) {
            var token = try self.channel.handoff(self.deadline);
            try self.parent.reclaim(&token, self.deadline);
            self.stage = if (self.invalidated) .obsolete else .complete;
            return null;
        }
        const query = self.prepare(now) catch |err| { self.failed(err); return null; };
        if (query) |value| {
            // A new SUPPORTED receipt invalidates root connection metadata.
            // root_resource is preceded by a fresh CONNECTED request below.
            try self.channel.begin(value, self.deadline);
            self.query = value;
        }
        return null;
    }
};
