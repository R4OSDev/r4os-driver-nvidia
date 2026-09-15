//! Restore one exclusively owned MST root after a known link failure. All
//! sibling IDs remain leased. Actual rate governing and source stop precede
//! the root-wide clear; unrelated physical SORs are never touched.
const std = @import("std");
const link = @import("gsp_mst_link.zig");
const budget = @import("gsp_mst_budget.zig");
const control = @import("gsp_mst_control.zig");
const journal = @import("gsp_mst_transaction.zig");
const discovery = @import("gsp_mst_discovery.zig");
const registry = @import("gsp_mst_registry.zig");
const display = @import("gsp_display_rpc.zig");
const exchange = @import("gsp_exchange.zig");
const wire = @import("gsp_mst_wire.zig");
const down = @import("gsp_mst_transport.zig");
const upstream = @import("gsp_mst_upstream.zig");
const dp = @import("gsp_dp_link.zig");
const aux = display.aux_wire;
pub const Stage = enum { connected, resource, guid, branches, link_config, link_status,
    heads, active, active_resource, rate_on, rate_on_check, scanout, verify_active,
    stop_source, clear_status, clear_table, clear_updated, clear_branches, clear_verify,
    source, payload_clear, payload, updated, trigger, act, act_handled, verify_table,
    clear_vsc, clear_hdr, allocate, query, rate_off, rate_off_check,
    loss_source, loss_rate_off, loss_rate_check, complete };
pub const Core = struct { attached: bool, core_point: u64, window_point: u64 };
const Branch = struct { guid: wire.Guid = @splat(0), route: wire.Route = .{} };
const Paths = struct {
    branches: [8]Branch = @splat(.{}),
    count: u8 = 1,
    fn collect(table: *const budget.Table, root_guid: wire.Guid) !Paths {
        var result: Paths = .{};
        result.branches[0].guid = root_guid;
        for (table.entries[0..table.count]) |*entry| {
            if (!std.mem.eql(u8, &entry.key.root_guid, &root_guid)) return error.Stale;
            for (entry.path[0..entry.path_count], 0..) |edge, index| {
                if (index == 0 and (edge.route.depth != 0 or !std.mem.eql(u8, &edge.guid, &root_guid))) return error.Stale;
                if (index != 0 and !std.meta.eql(edge.route, try entry.path[index - 1].route.child(entry.path[index - 1].port))) return error.Stale;
                var found = false;
                for (result.branches[0..result.count]) |branch| if (std.meta.eql(branch.route, edge.route)) {
                    if (!std.mem.eql(u8, &branch.guid, &edge.guid)) return error.Stale;
                    found = true;
                };
                if (!found) {
                    if (result.count == result.branches.len) return error.Capacity;
                    result.branches[result.count] = .{ .guid = edge.guid, .route = edge.route };
                    result.count += 1;
                }
            }
        }
        return result;
    }
    fn verify(self: *const Paths, index: u8, observed: wire.Branch, table: *const budget.Table) !void {
        if (index >= self.count or !std.mem.eql(u8, &observed.guid, &self.branches[index].guid)) return error.Stale;
        const branch = self.branches[index];
        // Only surviving streams constrain the new descriptor. An unplugged
        // leaf or an unrelated port is allowed to change while retiring it.
        for (table.entries[0..table.count]) |*entry| for (entry.path[0..entry.path_count], 0..) |edge, hop| {
            if (!std.meta.eql(edge.route, branch.route)) continue;
            var found = false;
            for (observed.ports[0..observed.count]) |port| if (port.number == edge.port) {
                if (port.input or (!port.connected and !port.legacy_connected)) return error.Stale;
                if (hop + 1 < entry.path_count) {
                    if (!port.connected or port.peer != .branch or !port.messaging or
                        !std.mem.eql(u8, &port.guid, &entry.path[hop + 1].guid)) return error.Stale;
                } else if (port.peer == .none or (port.peer == .branch and port.messaging)) return error.Stale;
                found = true;
            };
            if (!found) return error.Stale;
        };
    }
};
pub const Work = struct {
    self_address: usize = 0,
    plan: link.Plan,
    root: *discovery.Root,
    ids: *registry.Registry,
    token: journal.Token,
    deadline: u64,
    candidate_core: u64,
    candidate_window: u64,
    stop_only: bool = false,
    disconnected: bool = false,
    previous_image: ?registry.Image = null,
    paths: ?Paths = null,
    stage: Stage = .connected,
    request: ?link.Request = null,
    sideband: ?down.Work = null,
    up: ?upstream.Work = null,
    events_seen: u8 = 0,
    request_serial: u64 = 0,
    posted: bool = false,
    last_receipt: u64 = 0,
    not_before: u64 = 0,
    retries: u8 = 0,
    polls: u16 = 0,
    cursor: u8 = 0,
    head_count: u32 = 0,
    active_id: u32 = 0,
    active_heads: u8 = 0,
    core: ?Core = null,
    training: ?budget.Training = null,
    source_stop: u64 = 0,
    source_receipt: u64 = 0,
    table_receipt: u64 = 0,
    clear_receipt: u64 = 0,
    act_receipt: u64 = 0,
    packet_receipt: u64 = 0,
    branch_receipt: u64 = 0,
    completion_receipt: u64 = 0,
    revision: u64 = 0,
    failure: ?anyerror = null,
    pub fn init(failed: *const link.Work, deadline: u64) !Work {
        if (failed.failure == null or failed.request != null or failed.sideband != null or failed.root.mailbox_pending or
            failed.result != null or deadline == 0) return error.Retained;
        try failed.root.transaction.validate(failed.token, &failed.root.live);
        try failed.root.transaction.restoring(failed.token);
        return .{ .plan = failed.plan, .root = failed.root, .ids = failed.ids, .token = failed.token, .deadline = deadline,
            .candidate_core = failed.core_point, .candidate_window = failed.window_point, .request_serial = failed.request_serial,
            .last_receipt = failed.last_receipt };
    }
    /// Remove a retained image after the common owner has started its Core
    /// detach. The capture may already be invalidated by HPD. Fresh branch
    /// replies must prove every surviving path before rebuilding that root.
    pub fn initStop(plan: link.Plan, proof: link.Result, image: registry.Image, store: *discovery.Store, deadline: u64) !Work {
        if (deadline == 0 or !proof.complete(plan) or image.head != plan.mode.head or image.window != plan.mode.window or
            image.dma == 0 or image.core_point < proof.core_point or image.window_point < proof.window_point) return error.Stale;
        const stamp = plan.mode.signal.mst orelse return error.Stale;
        const root = try store.root(stamp.root);
        if (root.live.epoch != plan.object.epoch or plan.mode.output_generation == 0 or
            root.live.training == null or root.resource == null or root.source == null or root.mailbox_pending or
            !std.meta.eql(root.resource.?, plan.root_resource) or !std.meta.eql(root.source.?, plan.root_source) or
            !std.mem.eql(u8, &root.dpcd, &plan.root_dpcd) or
            !std.meta.eql(root.live.training.?.link, proof.training.link) or !std.meta.eql(stamp.handle, try store.registry.handle(stamp.handle.slot))) return error.Stale;
        const slot = &store.registry.slots[stamp.handle.slot];
        const entry = root.live.table.find(stamp.display_id) orelse return error.Stale;
        if (slot.image == null or !std.meta.eql(slot.image.?, image) or !std.meta.eql(slot.key, entry.key) or
            !std.meta.eql(entry.handle, stamp.handle) or entry.allocation.head != image.head or entry.window != image.window or
            !std.meta.eql(entry.allocation.demand, proof.demand)) return error.Stale;
        if (root.transaction.phase == .disconnected) {
            const token = root.transaction.token orelse return error.Stale;
            try root.transaction.validate(token, &root.live);
            if (root.transaction.stopped_heads & (@as(u8, 1) << @intCast(image.head)) != 0) return error.Stale;
            return .{ .plan = plan, .root = root, .ids = &store.registry, .token = token, .deadline = deadline,
                .candidate_core = image.core_point, .candidate_window = image.window_point, .stop_only = true,
                .disconnected = true, .previous_image = image, .last_receipt = root.transaction.last_receipt };
        }
        if (root.stream_serial == std.math.maxInt(u64)) return error.Exhausted;
        const desired: budget.Budget = .{ .link = root.live.training.?.link,
            .table = try budget.remove(&root.live.table, plan.object.epoch, stamp.root, root.live.training.?.link, stamp.display_id) };
        const paths = try Paths.collect(&desired.table, plan.root_guid);
        const serial = root.stream_serial + 1;
        const token = try root.transaction.reserve(&store.registry, plan.object.epoch, stamp.root, plan.mode.output_generation, serial, &root.live, &desired);
        root.stream_serial = serial;
        return .{ .plan = plan, .root = root, .ids = &store.registry, .token = token, .deadline = deadline,
            .candidate_core = image.core_point, .candidate_window = image.window_point, .stop_only = true,
            .previous_image = image, .paths = paths };
    }
    fn table(self: *const Work) *const budget.Table { return if (self.stop_only) &self.root.transaction.target.table else &self.root.transaction.previous.table; }
    fn unionHead(self: *const Work, head: u32) bool {
        for ([_]*const budget.Table{ &self.root.transaction.previous.table, &self.root.transaction.target.table }) |entries|
            for (entries.entries[0..entries.count]) |*entry| if (entry.allocation.head == head) return true;
        return false;
    }
    fn ownedId(self: *const Work, id: u32, head: u32) bool {
        for ([_]*const budget.Table{ &self.root.transaction.previous.table, &self.root.transaction.target.table }) |entries|
            if (entries.find(id)) |entry| if (entry.allocation.head == head) return true;
        return false;
    }
    fn guard(self: *const Work, now: u64) !void {
        if (self.self_address != 0 and self.self_address != @intFromPtr(self)) return error.Stale;
        if (self.failure != null or self.stage == .complete) return error.State;
        if (now >= self.deadline) return error.Deadline;
        try self.root.transaction.validate(self.token, &self.root.live);
        const phase_ok = if (self.disconnected) self.stop_only and self.root.transaction.phase == .disconnected else
            if (self.stop_only) self.root.transaction.phase == .reserved or self.root.transaction.phase == .posted else self.root.transaction.phase == .restoring;
        if (!phase_ok or self.root.id != self.token.root or self.ids.epoch != self.token.epoch) return error.Stale;
        if (self.stop_only) {
            if (self.previous_image == null or (!self.disconnected and self.paths == null)) return error.Stale;
        } else if (!self.root.graph.coherent or self.root.graph.epoch != self.token.epoch or
            self.root.graph.generation != self.token.generation) return error.Stale;
    }
    pub fn ready(self: *const Work, now: u64) bool {
        return self.failure == null and self.stage != .scanout and self.stage != .complete and now >= self.not_before and
            (if (self.up) |*value| now >= value.not_before else true) and
            (if (self.sideband) |*value| now >= value.not_before else true);
    }
    pub fn pendingAt(self: *const Work, deadline: u64) bool {
        self.guard(0) catch return false;
        return self.self_address == @intFromPtr(self) and self.deadline == deadline and self.request != null and !self.posted;
    }
    fn read(self: *const Work, operation: aux.Operation) link.Request {
        return .{ .query = .{ .aux = .{ .display_id = self.token.root, .operation = operation } } };
    }
    fn mst(self: *const Work, operation: aux.Mst) link.Request { return self.read(.{ .mst = operation }); }
    fn rate(self: *const Work, enable: bool, check: bool) link.Request {
        return .{ .control = .{ .rate = .{ .head = if (enable) self.cursor else self.table().entries[self.cursor].allocation.head,
            .sor = self.plan.root_resource.index, .enable = enable, .immediate = true, .check = check } } };
    }
    fn sidebandRequest(self: *const Work) !struct { route: wire.Route, request: wire.Request } {
        return switch (self.stage) {
            .branches => .{ .route = if (self.paths) |*paths| paths.branches[self.cursor].route else self.root.graph.branches[self.cursor].route, .request = .link_address },
            .clear_branches => .{ .route = .{}, .request = .clear },
            .allocate, .query => blk: {
                const item = &self.table().entries[self.cursor];
                break :blk .{ .route = item.key.route, .request = if (self.stage == .query)
                    .{ .query = .{ .port = item.key.port, .id = item.allocation.payload_id } } else
                    .{ .allocate = .{ .port = item.key.port, .id = item.allocation.payload_id, .pbn = item.allocation.demand.pbn,
                        .sink = if (item.allocation.head < 4 and item.allocation.demand.audio_48k) 0 else null } } };
            },
            else => error.State,
        };
    }
    pub fn prepare(self: *Work, now: u64) !bool {
        try self.guard(now); self.self_address = @intFromPtr(self);
        if (self.request != null) return error.Pending;
        if (!self.ready(now)) return false;
        const request: link.Request = if (self.up) |*up| blk: {
            if (up.stage == .received) {
                const notice = try up.notification(self.token.generation);
                const identity = switch (notice) { .connection => |v| .{ v.guid, v.port }, .resources => |v| .{ v.guid, v.port } };
                var matched = false;
                for (self.root.transaction.previous.table.entries[0..self.root.transaction.previous.table.count]) |*entry|
                    for (entry.path[0..entry.path_count]) |edge| {
                        if (std.meta.eql(edge.route, up.assembly.?.route) and edge.port == identity[1] and
                            std.mem.eql(u8, &edge.guid, &identity[0])) matched = true;
                    };
                if (self.events_seen == 8) return error.RetryExhausted;
                self.events_seen += 1;
                try up.respond(self.token.generation, now, matched);
            }
            if (up.stage == .complete or up.stage == .empty) {
                if (up.down_pending) return error.Retained;
                if (up.stage == .complete) self.up = try upstream.Work.init(self.token.root, self.token.generation, self.deadline)
                else { self.up = null; self.move(.guid); }
                return false; // Fresh GUID/paths after draining; never trust notice data.
            }
            break :blk .{ .query = .{ .aux = try up.prepare(self.token.generation, now) orelse return false } };
        } else switch (self.stage) {
            .connected => .{ .query = .{ .connected = self.token.root } },
            .resource => .{ .query = .{ .resource = self.token.root } }, .guid => self.mst(.guid),
            .link_config => self.read(.link_config), .link_status => self.read(.link_status),
            .heads => .{ .query = .heads }, .active => .{ .query = .{ .active = self.cursor } },
            .active_resource => .{ .query = .{ .resource = self.active_id } },
            .branches, .clear_branches, .allocate, .query => blk: {
                if (self.sideband == null) {
                    if (self.root.mailbox_pending) return error.Retained;
                    const action = try self.sidebandRequest();
                    self.sideband = try down.Work.init(self.token.root, self.token.generation, self.deadline, action.route, self.root.sequence, action.request);
                }
                break :blk .{ .query = .{ .aux = try self.sideband.?.prepare(self.token.generation, now) orelse return false } };
            },
            .rate_on => self.rate(true, false), .rate_on_check => self.rate(true, true),
            .verify_active => .{ .query = .{ .active = self.plan.mode.head } },
            .stop_source => .{ .control = .{ .stream = .{ .head = self.cursor, .sor = self.plan.root_resource.index,
                .link = self.plan.root_resource.protocol - 8, .hblank = 0, .vblank = 0, .start = 1, .end = 0, .pbn = 0, .timeslice_pbn = 0 } } },
            .loss_source => .{ .control = .{ .stream = .{ .head = self.plan.mode.head, .sor = self.plan.root_resource.index,
                .link = self.plan.root_resource.protocol - 8, .hblank = 0, .vblank = 0, .start = 1, .end = 0, .pbn = 0, .timeslice_pbn = 0 } } },
            .loss_rate_off, .loss_rate_check => .{ .control = .{ .rate = .{ .head = self.plan.mode.head,
                .sor = self.plan.root_resource.index, .enable = false, .immediate = true, .check = self.stage == .loss_rate_check } } },
            .clear_status, .payload_clear => self.mst(.{ .payload_status = true }),
            .clear_table => self.mst(.{ .payload = .{ .id = 0, .start = 0, .count = 63 } }),
            .clear_updated, .updated, .act_handled => self.mst(.{ .payload_status = false }),
            .clear_verify, .verify_table => self.mst(.{ .payload_table = @intCast(self.cursor) }),
            .source => blk: {
                const item = self.table().entries[self.cursor].allocation;
                break :blk .{ .control = .{ .stream = .{ .head = item.head, .sor = self.plan.root_resource.index,
                    .link = self.plan.root_resource.protocol - 8, .hblank = item.demand.hblank, .vblank = item.demand.vblank,
                    .start = item.start, .end = @as(u32, item.start) + item.demand.slots - 1, .pbn = item.demand.pbn, .timeslice_pbn = item.demand.timeslice_pbn } } };
            },
            .payload => blk: {
                const item = self.table().entries[self.cursor].allocation;
                break :blk self.mst(.{ .payload = .{ .id = item.payload_id, .start = item.start, .count = item.demand.slots } });
            },
            .trigger => .{ .control = .{ .trigger = .{ .head = self.table().entries[0].allocation.head, .sor = self.plan.root_resource.index } } },
            .act => .{ .control = .{ .act = self.token.root } },
            .clear_vsc => .{ .control = .{ .clear_vsc = self.table().entries[self.cursor].allocation.display_id } },
            .clear_hdr => .{ .control = .{ .clear_hdr = self.table().entries[self.cursor].allocation.display_id } },
            .rate_off => self.rate(false, false), .rate_off_check => self.rate(false, true),
            .scanout, .complete => return error.State,
        };
        if (self.request_serial == std.math.maxInt(u64)) return error.Exhausted;
        self.request_serial += 1; self.request = request; self.posted = false;
        return true;
    }
    pub fn encode(self: *const Work, bytes: []u8) !usize { return (self.request orelse return error.Pending).encode(self.plan.object, bytes); }
    pub fn submitted(self: *Work) !void {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self)) return error.Stale;
        const request = self.request orelse return error.Pending;
        if (self.posted) return;
        try self.root.transaction.posted(self.token, self.request_serial); self.posted = true;
        if (request == .query and request.query == .aux and request.query.aux.operation == .mst and request.query.aux.operation.mst == .mailbox and self.sideband != null) {
            const sent = request.query.aux.operation.mst.mailbox;
            if (sent.box == .down_request and @as(usize, sent.offset) + sent.count == self.sideband.?.packet_count) {
                self.root.mailbox_pending = true; self.root.mailbox_deadline = self.deadline;
            }
        }
    }
    fn move(self: *Work, stage: Stage) void { self.stage = stage; self.cursor = 0; self.polls = 0; self.retries = 0; self.not_before = 0; }
    fn retry(self: *Work, now: u64, ms: u32) !void {
        if (ms == 0 or ms > 500 or self.retries == 7) return error.RetryExhausted;
        self.retries += 1; self.not_before = now +| @as(u64, ms) * std.time.ns_per_ms;
    }
    fn pollLater(self: *Work, now: u64) !void {
        if (self.polls == 1000) return error.LinkTraining;
        self.polls += 1; self.not_before = now +| std.time.ns_per_ms;
    }
    fn nextHead(self: *Work) !void {
        self.cursor += 1;
        if (self.cursor < self.head_count) { self.stage = .active; return; }
        if (self.disconnected) { self.move(.scanout); return; }
        // The previous table is owned only if every sibling's actual head
        // still belongs to it. The failed candidate may already be attached.
        for (self.table().entries[0..self.table().count]) |entry|
            if (self.active_heads & (@as(u8, 1) << @intCast(entry.allocation.head)) == 0) return error.Retained;
        self.move(.rate_on);
        while (self.cursor < 8 and self.active_heads & (@as(u8, 1) << @intCast(self.cursor)) == 0) self.cursor += 1;
        if (self.cursor == 8) self.move(.scanout);
    }
    fn finish(self: *Work, serial: u64) !void {
        const core = self.core orelse return error.State;
        if (self.disconnected) {
            _ = try self.root.transaction.disconnectedHead(self.ids, self.token, &self.root.live, self.plan.mode.signal.display_id,
                self.previous_image.?, core.core_point, core.window_point, self.source_stop, serial);
            self.revision = self.root.live.revision;
            self.completion_receipt = serial; self.move(.complete);
            return;
        }
        self.revision = if (self.stop_only) try self.root.transaction.stopped(self.ids, self.token, &self.root.live, self.training,
            self.source_stop, self.clear_receipt, self.act_receipt, self.branch_receipt, serial) else
            try self.root.transaction.restored(self.ids, self.token, &self.root.live, self.training,
                self.source_stop, self.clear_receipt, self.act_receipt, self.branch_receipt, serial);
        self.completion_receipt = serial; self.move(.complete);
    }
    pub fn consume(self: *Work, record: exchange.message.Record, serial: u64, now: u64) !void {
        const request = self.request orelse return error.Pending;
        if (!self.posted or serial == 0 or serial <= self.last_receipt) return error.Stale;
        self.request = null; self.last_receipt = serial;
        errdefer |err| { self.failure = err; self.root.transaction.retain(); }
        try self.root.transaction.receipt(self.token, serial); try self.guard(now);
        const response = try request.decode(self.plan.object, record);
        if (self.up) |*up| {
            if (response != .query or response.query != .aux) return error.Unexpected;
            try up.consume(self.token.generation, response.query.aux, serial, now);
            return;
        }
        if (self.sideband) |*value| {
            if (response != .query or response.query != .aux) return error.Unexpected;
            try value.consume(self.token.generation, response.query.aux, serial, now);
            if (value.stage != .complete) return;
            const reply = try wire.reply(value.request, try value.assembly.body());
            self.root.mailbox_pending = false; self.root.mailbox_deadline = 0; self.root.sequence ^= 1;
            defer self.sideband = null;
            if (value.up_pending and (!self.stop_only or self.stage != .branches)) return error.Stale;
            if (reply == .nack) return error.BranchRejected;
            switch (self.stage) {
                .branches => {
                    if (reply != .branch) return error.Stale;
                    if (self.paths) |*paths| try paths.verify(self.cursor, reply.branch, self.table())
                    else if (!std.meta.eql(reply.branch, self.root.graph.branches[self.cursor].descriptor.?)) return error.Stale;
                    self.cursor += 1;
                    if (self.cursor == (if (self.paths) |*paths| paths.count else self.root.graph.branch_count))
                        self.move(if (self.table().count == 0) .heads else .link_config);
                    if (value.up_pending) self.up = try upstream.Work.init(self.token.root, self.token.generation, self.deadline);
                },
                .clear_branches => { if (reply != .ack or reply.ack != .clear) return error.Unexpected; self.move(.clear_verify); },
                .allocate => { if (reply != .allocated) return error.Unexpected; self.stage = .query; },
                .query => {
                    if (reply != .queried or reply.queried.pbn != self.table().entries[self.cursor].allocation.demand.pbn) return error.Stale;
                    self.cursor += 1;
                    if (self.cursor == self.table().count) { self.branch_receipt = serial; self.move(.rate_off); } else self.stage = .clear_vsc;
                },
                else => return error.State,
            }
            return;
        }
        if (response == .rate_pending) return self.pollLater(now);
        if (response == .query and response.query == .aux) {
            const observation = response.query.aux;
            if (observation.status == 3 or observation.status == 0x66) return self.retry(now, observation.retry_ms);
            if (observation.status != 0) return error.RmRejected;
            if (observation.kind == .defer_reply) return self.retry(now, 1);
            if (observation.kind != .ack or observation.count != aux.length(request.query.aux.operation)) return error.Aux;
            self.retries = 0; self.not_before = 0;
            const data = observation.data;
            switch (self.stage) {
                .guid => { if (!std.mem.eql(u8, &data, &self.plan.root_guid)) return error.Stale; self.move(.branches); },
                .link_config => {
                    const previous = self.root.transaction.previous.training.?;
                    if (data[0] != previous.link.rate or data[1] & 31 != previous.link.lanes or data[1] & 0x80 == 0) return error.LinkTraining;
                    self.move(.link_status);
                },
                .link_status => {
                    var previous = self.root.transaction.previous.training.?;
                    if (!dp.trained(data[0..8].*, previous.link.lanes)) return error.LinkTraining;
                    previous.lanes = data[0..8].*; previous.receipt = serial; self.training = previous; self.move(.heads);
                },
                .clear_status => self.move(.clear_table), .clear_table => self.move(.clear_updated),
                .clear_updated => { if (data[0] & 1 == 0) return self.pollLater(now); self.move(.clear_branches); },
                .clear_verify, .verify_table => {
                    for (data, 0..) |value, i| {
                        const offset = self.cursor * 16 + @as(u8, @intCast(i));
                        if (offset == 0) { if (self.stage == .verify_table and value & 2 == 0) return error.Stale; continue; }
                        var expected: u8 = 0;
                        if (self.stage == .verify_table) for (self.table().entries[0..self.table().count]) |entry| {
                            if (offset >= entry.allocation.start and offset < @as(u16, entry.allocation.start) + entry.allocation.demand.slots)
                                expected = entry.allocation.payload_id;
                        };
                        if (value != expected) return error.Stale;
                    }
                    self.cursor += 1;
                    if (self.cursor == 4) {
                        if (self.stage == .clear_verify) {
                            self.clear_receipt = serial;
                            if (self.table().count == 0) try self.finish(serial) else self.move(.source);
                        } else { self.act_receipt = serial; self.move(.clear_vsc); }
                    }
                },
                .payload_clear => self.stage = .payload,
                .payload => self.stage = .updated,
                .updated => {
                    if (data[0] & 1 == 0) return self.pollLater(now);
                    self.polls = 0; self.cursor += 1;
                    if (self.cursor == self.table().count) { self.table_receipt = serial; self.move(.trigger); } else self.stage = .payload_clear;
                },
                .act_handled => { if (data[0] & 2 == 0) return self.pollLater(now); self.move(.verify_table); },
                else => return error.State,
            }
            return;
        }
        switch (self.stage) {
            .connected => {
                if (response != .query or response.query != .connected) return error.Stale;
                if (response.query.connected == 0 and self.stop_only) {
                    if (!self.disconnected) self.token = try self.root.transaction.disconnected(self.token, &self.root.live, serial);
                    self.disconnected = true; self.root.payload_dirty = true;
                } else if (response.query.connected != self.token.root) return error.Stale;
                // A rapid return cannot interrupt retirement or reuse these
                // source slots. The returning receiver is cleared on capture.
                self.move(.resource);
            },
            .resource => {
                if (response != .query or response.query != .resource or !std.meta.eql(response.query.resource, self.plan.root_resource)) return error.Stale;
                self.move(if (self.disconnected) .heads else .guid);
            },
            .heads => {
                if (response != .query or response.query != .heads or response.query.heads == 0 or response.query.heads > 8 or self.plan.mode.head >= response.query.heads) return error.Stale;
                self.head_count = response.query.heads; self.move(.active);
            },
            .active => {
                if (response != .query or response.query != .active) return error.Unexpected;
                self.active_id = response.query.active;
                if (self.active_id == 0) try self.nextHead() else {
                    if (self.active_id & (self.active_id - 1) != 0) return error.Unsupported;
                    self.stage = .active_resource;
                }
            },
            .active_resource => {
                if (response != .query or response.query != .resource) return error.Unexpected;
                const value = response.query.resource;
                if (value.kind == 2 and value.index == self.plan.root_resource.index) {
                    if (!value.dynamic or value.root_port_id != self.token.root or value.protocol != self.plan.root_resource.protocol or !self.ownedId(self.active_id, self.cursor)) return error.Retained;
                    if (self.disconnected and self.root.transaction.stopped_heads & (@as(u8, 1) << @intCast(self.cursor)) != 0) return error.Retained;
                    self.active_heads |= @as(u8, 1) << @intCast(self.cursor);
                } else if (self.unionHead(self.cursor)) return error.Retained;
                try self.nextHead();
            },
            .rate_on => { if (response != .control) return error.Unexpected; self.stage = .rate_on_check; },
            .rate_on_check => {
                if (response != .control) return error.Unexpected;
                self.polls = 0; self.cursor += 1;
                while (self.cursor < 8 and self.active_heads & (@as(u8, 1) << @intCast(self.cursor)) == 0) self.cursor += 1;
                if (self.cursor == 8) self.move(.scanout) else self.stage = .rate_on;
            },
            .verify_active => {
                if (response != .query or response.query != .active or response.query.active !=
                    @as(u32, if (self.core.?.attached) self.plan.mode.signal.display_id else 0)) return error.Stale;
                if (self.disconnected) { self.move(.loss_source); return; }
                self.move(.stop_source); while (self.cursor < 8 and !self.unionHead(self.cursor)) self.cursor += 1;
                if (self.cursor == 8) return error.State;
            },
            .stop_source => {
                if (response != .control) return error.Unexpected;
                self.source_stop = serial; self.cursor += 1;
                while (self.cursor < 8 and !self.unionHead(self.cursor)) self.cursor += 1;
                if (self.cursor == 8) self.move(.clear_status);
            },
            .source => {
                if (response != .control) return error.Unexpected;
                self.source_receipt = serial;
                self.cursor += 1; if (self.cursor == self.table().count) self.move(.payload_clear);
            },
            .trigger => { if (response != .control) return error.Unexpected; self.move(.act); },
            .act => { if (response != .control) return error.Unexpected; self.move(.act_handled); },
            .clear_vsc => { if (response != .control) return error.Unexpected; self.stage = .clear_hdr; },
            .clear_hdr => { if (response != .control) return error.Unexpected; self.packet_receipt = serial; self.stage = .allocate; },
            .rate_off => { if (response != .control) return error.Unexpected; self.stage = .rate_off_check; },
            .rate_off_check => {
                if (response != .control) return error.Unexpected;
                self.polls = 0; self.cursor += 1;
                if (self.cursor == self.table().count) try self.finish(serial) else self.stage = .rate_off;
            },
            .loss_source => { if (response != .control) return error.Unexpected; self.source_stop = serial; self.move(.loss_rate_off); },
            .loss_rate_off => { if (response != .control) return error.Unexpected; self.move(.loss_rate_check); },
            .loss_rate_check => { if (response != .control) return error.Unexpected; try self.finish(serial); },
            else => return error.State,
        }
    }
    /// The common display owner restored the old candidate image (or retired
    /// a new head) and verified Core/Window/ARM. Posted candidate points must
    /// be superseded; unsubmitted candidates must preserve the exact old image.
    pub fn scanoutRestored(self: *Work, core: Core) !void {
        if (self.stage != .scanout or self.failure != null or self.request != null or self.core != null) return error.State;
        const previous = self.table().find(self.plan.mode.signal.display_id);
        if (core.attached != (!self.disconnected and previous != null)) return error.Stale;
        if (self.candidate_core != 0 or self.candidate_window != 0) {
            if (core.core_point <= self.candidate_core or core.window_point <= self.candidate_window) return error.Stale;
        } else if (previous) |entry| {
            const image = self.ids.slots[entry.handle.slot].image orelse return error.Stale;
            if (core.core_point != image.core_point or core.window_point != image.window_point) return error.Stale;
        } else if (core.core_point != 0 or core.window_point != 0) return error.Stale;
        self.core = core; self.move(.verify_active);
    }
    pub fn retainAmbiguous(self: *Work, reason: anyerror) void { self.failure = reason; self.root.transaction.retain(); }
    /// Rebind the restored root receipt to an actual unchanged/restored image.
    /// All heads share the source/table transaction; their Core/Window points
    /// remain those independently verified by the common display owner.
    pub fn restoredImage(self: *const Work, plan: link.Plan, core_point: u64, window_point: u64) !link.Result {
        if (self.stage != .complete or self.failure != null or self.completion_receipt == 0 or self.training == null or
            self.root.live.revision != self.revision or self.root.live.completion_receipt != self.completion_receipt or
            !std.meta.eql(plan.object, self.plan.object) or plan.root() != self.token.root or
            !std.meta.eql(plan.root_resource, self.plan.root_resource) or !std.mem.eql(u8, &plan.root_guid, &self.plan.root_guid)) return error.Stale;
        const entry = self.root.live.table.find(plan.mode.signal.display_id) orelse return error.Stale;
        if (!std.meta.eql(entry.handle, plan.mode.signal.mst.?.handle) or entry.allocation.head != plan.mode.head or entry.window != plan.mode.window) return error.Stale;
        const result: link.Result = .{ .stamp = plan.mode.signal.mst.?, .training = self.training.?, .payload_id = entry.allocation.payload_id,
            .demand = entry.allocation.demand, .revision = self.revision, .core_point = core_point, .window_point = window_point,
            .source_receipt = self.source_receipt, .table_receipt = self.table_receipt, .act_receipt = self.act_receipt,
            .packet_receipt = self.packet_receipt, .branch_receipt = self.branch_receipt, .rate_receipt = self.completion_receipt };
        if (!result.complete(plan)) return error.Completion;
        return result;
    }
};
