//! Physical-root MST link intent. Whole payload tables and their revision
//! live in Root.transaction; retaining a completed image must not snapshot
//! or freeze the allocation positions of its sibling streams.
const std = @import("std");
const boot = @import("gsp_boot_mode.zig");
const outputs = @import("gsp_outputs.zig");
const display = @import("gsp_display_rpc.zig");
const binding = @import("gsp_mst_binding.zig");
const caps = @import("gsp_link_caps.zig");
const color = @import("gsp_color_signal.zig");
const budget = @import("gsp_mst_budget.zig");
const dp = @import("gsp_dp_link.zig");
const control = @import("gsp_mst_control.zig");
const exchange = @import("gsp_exchange.zig");
pub const max_bytes = 108;
pub const Plan = struct {
    object: display.Object,
    mode: boot.Plan,
    root_resource: display.Resource,
    root_source: caps.DpSource,
    root_dpcd: [16]u8,
    root_guid: [16]u8,
    receiver: color.Receiver,
    pub fn root(self: Plan) u32 { return self.mode.signal.mst.?.root; }
};
pub fn derive(mode: boot.Plan, object: display.Object, snapshot: *const outputs.Snapshot) !Plan {
    if (object.epoch == 0 or object.epoch != mode.epoch or object.client == 0 or object.display == 0 or
        object.client != snapshot.topology.client) return error.Stale;
    const stamp = mode.signal.mst orelse return error.Descriptor;
    _ = try @import("gsp_mst_mode.zig").admit(mode, snapshot);
    const view = try binding.derive(snapshot, stamp.display_id);
    return .{ .object = object, .mode = mode, .root_resource = view.root.resource.?,
        .root_source = view.root.source.?, .root_dpcd = view.root.dpcd, .root_guid = view.slot.key.root_guid,
        .receiver = color.Receiver.capture(view.sink.report) };
}
pub const Result = struct {
    stamp: binding.Stamp,
    training: budget.Training,
    payload_id: u8,
    demand: budget.payload.Demand,
    revision: u64,
    core_point: u64,
    window_point: u64,
    source_receipt: u64,
    table_receipt: u64,
    act_receipt: u64,
    packet_receipt: u64,
    branch_receipt: u64,
    rate_receipt: u64,
    pub fn complete(self: Result, plan: Plan) bool {
        const mode = plan.mode;
        const expected = mode.signal.mst orelse return false;
        if (!std.meta.eql(expected, self.stamp) or self.revision == 0 or self.core_point == 0 or self.window_point == 0 or
            self.training.receipt == 0 or self.payload_id != mode.head + 1 or
            self.source_receipt <= self.training.receipt or self.table_receipt <= self.source_receipt or
            self.act_receipt <= self.table_receipt or self.packet_receipt <= self.act_receipt or self.branch_receipt <= self.packet_receipt or self.rate_receipt <= self.branch_receipt or
            !std.meta.eql(self.training.source, plan.root_source) or !std.mem.eql(u8, &self.training.dpcd, &plan.root_dpcd) or
            !dp.trained(self.training.lanes, self.training.link.lanes)) return false;
        const sink = dp.receiverCaps(self.training.dpcd) catch return false;
        if (!self.training.source.mst or !sink.enhanced or self.training.link.rate > @min(sink.rate, self.training.source.rate) or
            self.training.link.lanes > sink.lanes) return false;
        const demand = budget.payload.demand(self.training.link, .{ .clock = color.links.Clock.nvidia(mode.signal.clock),
            .width = mode.width, .total = mode.signal.total & 0xffff, .bpc = mode.signal.bpc }) catch return false;
        return std.meta.eql(demand, self.demand);
    }
};

/// These are private serialized display operations. No caller-selected
/// command number, arbitrary AUX address or device ID escapes this owner.
pub const Request = union(enum) {
    query: display.Query,
    control: control.Query,
    pub fn encode(self: Request, object: display.Object, output: []u8) !usize {
        switch (self) {
            .query => |query| {
                switch (query) {
                    .connected, .resource, .heads, .active, .dp_source, .aux => {},
                    else => return error.Unsupported,
                }
                return (try display.encode(object, query, output)).len;
            },
            .control => |query| {
                if (query == .allocate or query == .free) return error.Unsupported;
                if (object.epoch == 0 or object.client == 0 or object.display == 0 or output.len < 24 + query.size()) return error.Descriptor;
                @memset(output[0..24], 0);
                put(output, 0, object.client); put(output, 4, object.display); put(output, 8, query.command());
                put(output, 16, @intCast(query.size())); put(output, 20, if (query == .train) 1 else 0);
                return 24 + try query.encode(output[24..]);
            },
        }
    }
    /// The caller has already acknowledged the actual exchange ticket.
    /// Retry and pending status remain observations; they are not completion.
    pub fn decode(self: Request, object: display.Object, record: exchange.message.Record) !Reply {
        switch (self) {
            .query => |query| return .{ .query = try display.decode(object, query, record) },
            .control => |query| {
                var expected: [max_bytes]u8 = undefined;
                const count = try self.encode(object, &expected);
                if (record.rpc.function != 76 or record.rpc.cpu_rm_gfid != 0) return error.Unexpected;
                if (record.rpc.result != 0) return error.RmRejected;
                const bytes = record.payload;
                if (bytes.len != count or !std.mem.eql(u8, bytes[0..12], expected[0..12]) or
                    !std.mem.eql(u8, bytes[16..24], expected[16..24])) return error.Unexpected;
                const status = word(bytes, 12);
                if (query == .train) return .{ .training = try query.training(status, bytes[24..]) };
                _ = query.decode(status, bytes[24..]) catch |err| {
                    if (err == error.Pending) return .{ .rate_pending = {} };
                    return err;
                };
                return .{ .control = {} };
            },
        }
    }
};
pub const Reply = union(enum) { query: display.Reply, control: void, training: control.Training, rate_pending: void };
fn put(bytes: []u8, at: usize, value: u32) void { std.mem.writeInt(u32, bytes[at..][0..4], value, .little); }
fn word(bytes: []const u8, at: usize) u32 { return std.mem.readInt(u32, bytes[at..][0..4], .little); }

const discovery = @import("gsp_mst_discovery.zig");
const registry = @import("gsp_mst_registry.zig");
const journal = @import("gsp_mst_transaction.zig");
const wire = @import("gsp_mst_wire.zig");
const down = @import("gsp_mst_transport.zig");
const aux = display.aux_wire;
pub const Stage = enum {
    connected, resource, source, leaf, caps, extended_caps, mst_caps, control, guid, repeaters,
    heads, active, active_resource, branches, paths, query_old, table_before,
    power, power_on, train, link_config, link_status,
    initial_clear_status, initial_clear, initial_updated, initial_branches, initial_verify,
    remove_rate, remove_rate_check, remove_branch, remove_query, remove_source,
    remove_clear, remove_payload, remove_updated, remove_act, remove_handled, remove_verify,
    trigger, source_streams, rate_on, table_clear, table_payload, table_updated,
    scanout, act, act_handled, table_final, clear_vsc, clear_hdr, branch, branch_query, rate_off, rate_check, complete,
};
/// One serialized root transaction, driven by Runtime's existing Exchange.
/// prepare/encode may never submit; submitted is called only once the real
/// request is waiting. consume follows the real ring acknowledgement.
pub const Work = struct {
    self_address: usize = 0,
    plan: Plan,
    root: *discovery.Root,
    ids: *registry.Registry,
    token: journal.Token,
    deadline: u64,
    stage: Stage = .connected,
    request: ?Request = null,
    sideband: ?down.Work = null,
    last_receipt: u64 = 0,
    request_serial: u64 = 0,
    request_posted: bool = false,
    not_before: u64 = 0,
    retries: u8 = 0,
    polls: u16 = 0,
    cursor: u8 = 0,
    path_cursor: u8 = 0,
    head_count: u32 = 0,
    active_id: u32 = 0,
    seen_heads: u8 = 0,
    power_value: u8 = 1,
    training: ?budget.Training = null,
    training_attempts: u8 = 0,
    source_receipt: u64 = 0,
    table_receipt: u64 = 0,
    act_receipt: u64 = 0,
    packet_receipt: u64 = 0,
    branch_receipt: u64 = 0,
    core_point: u64 = 0,
    window_point: u64 = 0,
    result: ?Result = null,
    failure: ?anyerror = null,

    pub fn init(plan: Plan, snapshot: *const outputs.Snapshot, store: *discovery.Store, deadline: u64) !Work {
        if (deadline == 0 or !std.meta.eql(plan, try derive(plan.mode, plan.object, snapshot))) return error.Stale;
        const root = try store.root(plan.root());
        if (root.mailbox_pending or root.stream_serial == std.math.maxInt(u64)) return error.Retained;
        const desired = try @import("gsp_mst_mode.zig").admit(plan.mode, snapshot);
        const serial = root.stream_serial + 1;
        const token = try root.transaction.reserve(&store.registry, plan.object.epoch, root.id,
            plan.mode.output_generation, serial, &root.live, &desired);
        root.stream_serial = serial;
        return .{ .plan = plan, .root = root, .ids = &store.registry, .token = token, .deadline = deadline };
    }
    fn before(self: *const Work) *const budget.Table { return &self.root.transaction.previous.table; }
    fn target(self: *const Work) *const budget.Table { return &self.root.transaction.target.table; }
    fn entry(self: *const Work) *const budget.Entry { return self.target().find(self.plan.mode.signal.display_id).?; }
    fn previousEntry(self: *const Work) ?*const budget.Entry { return self.before().find(self.plan.mode.signal.display_id); }
    fn guard(self: *const Work, now: u64) !void {
        if (self.self_address != 0 and self.self_address != @intFromPtr(self)) return error.Stale;
        if (self.failure != null or self.stage == .complete) return error.State;
        if (now >= self.deadline) return error.Deadline;
        try self.root.transaction.validate(self.token, &self.root.live);
        if (!self.root.graph.coherent or self.root.graph.epoch != self.token.epoch or self.root.graph.root != self.token.root or
            self.root.graph.generation != self.token.generation or self.root.resource == null or self.root.source == null or
            !std.meta.eql(self.root.resource.?, self.plan.root_resource) or !std.meta.eql(self.root.source.?, self.plan.root_source) or
            !std.mem.eql(u8, &self.root.dpcd, &self.plan.root_dpcd)) return error.Stale;
    }
    pub fn ready(self: *const Work, now: u64) bool {
        return self.failure == null and self.stage != .scanout and self.stage != .complete and now >= self.not_before and
            (if (self.sideband) |*value| now >= value.not_before else true);
    }
    pub fn pendingAt(self: *const Work, deadline: u64) bool {
        self.guard(0) catch return false;
        return self.self_address == @intFromPtr(self) and self.deadline == deadline and self.request != null and !self.request_posted;
    }
    fn read(self: *const Work, operation: aux.Operation) Request {
        return .{ .query = .{ .aux = .{ .display_id = self.token.root, .operation = operation } } };
    }
    fn mst(self: *const Work, operation: aux.Mst) Request { return self.read(.{ .mst = operation }); }
    fn rate(self: *const Work, enable: bool, immediate: bool, check: bool) Request {
        return .{ .control = .{ .rate = .{ .head = self.plan.mode.head, .sor = self.plan.mode.signal.sor,
            .enable = enable, .immediate = immediate, .check = check } } };
    }
    fn stream(self: *const Work, head: u32, deleting: bool) ?control.Stream {
        var selected: ?budget.Entry = null;
        const table = if (deleting) self.before() else self.target();
        const removed = self.previousEntry();
        for (table.entries[0..table.count]) |item| if (item.allocation.head == head) { selected = item; };
        var item = selected orelse return null;
        if (deleting) {
            const old = removed orelse return null;
            if (item.allocation.display_id == old.allocation.display_id) return .{ .head = head, .sor = self.plan.mode.signal.sor,
                .link = self.plan.root_resource.protocol - 8, .hblank = 0, .vblank = 0, .start = 1, .end = 0, .pbn = 0, .timeslice_pbn = 0 };
            if (item.allocation.start > old.allocation.start) item.allocation.start -= old.allocation.demand.slots;
        }
        const value = item.allocation;
        return .{ .head = head, .sor = self.plan.mode.signal.sor, .link = self.plan.root_resource.protocol - 8,
            .hblank = value.demand.hblank, .vblank = value.demand.vblank, .start = value.start,
            .end = @as(u32, value.start) + value.demand.slots - 1, .pbn = value.demand.pbn, .timeslice_pbn = value.demand.timeslice_pbn };
    }
    fn sidebandRequest(self: *const Work) !struct { route: wire.Route, request: wire.Request } {
        const graph = &self.root.graph;
        return switch (self.stage) {
            .branches => .{ .route = graph.branches[self.cursor].route, .request = .link_address },
            .paths => .{ .route = graph.branches[graph.edges[self.cursor].branch].route,
                .request = .{ .enum_path = graph.edges[self.cursor].port.number } },
            .query_old => blk: {
                const item = &self.before().entries[self.cursor];
                const edge = item.path[self.path_cursor];
                break :blk .{ .route = edge.route, .request = .{ .query = .{ .port = edge.port, .id = item.allocation.payload_id } } };
            },
            .initial_branches => .{ .route = .{}, .request = .clear },
            .remove_branch, .remove_query, .branch, .branch_query => blk: {
                const removing = self.stage == .remove_branch or self.stage == .remove_query;
                const item = if (removing) self.previousEntry().? else self.entry();
                const query = self.stage == .remove_query or self.stage == .branch_query;
                break :blk .{ .route = item.key.route, .request = if (query)
                    .{ .query = .{ .port = item.key.port, .id = item.allocation.payload_id } } else
                    .{ .allocate = .{ .port = item.key.port, .id = item.allocation.payload_id,
                        .pbn = if (removing) 0 else item.allocation.demand.pbn,
                        .sink = if (!removing and self.plan.mode.hasAudio() and item.allocation.demand.audio_48k) 0 else null } } };
            },
            else => error.State,
        };
    }
    pub fn prepare(self: *Work, now: u64) !bool {
        try self.guard(now);
        self.self_address = @intFromPtr(self);
        if (self.request != null) return error.Pending;
        if (!self.ready(now)) return false;
        const request: Request = switch (self.stage) {
            .connected => .{ .query = .{ .connected = self.token.root } },
            .resource => .{ .query = .{ .resource = self.token.root } },
            .source => .{ .query = .{ .dp_source = .{ .display_id = self.token.root, .sor = self.plan.mode.signal.sor } } },
            .leaf => .{ .query = .{ .resource = self.target().entries[self.cursor].allocation.display_id } },
            .caps => self.read(.caps), .extended_caps => self.read(.extended_caps), .mst_caps => self.read(.mst_caps),
            .control => self.mst(.{ .control = null }), .guid => self.mst(.guid), .repeaters => self.read(.repeaters),
            .heads => .{ .query = .heads }, .active => .{ .query = .{ .active = self.cursor } },
            .active_resource => .{ .query = .{ .resource = self.active_id } },
            .branches, .paths, .query_old, .initial_branches, .remove_branch, .remove_query, .branch, .branch_query => blk: {
                if (self.sideband == null) {
                    if (self.root.mailbox_pending) return error.Retained;
                    const action = try self.sidebandRequest();
                    self.sideband = try down.Work.init(self.token.root, self.token.generation, self.deadline,
                        action.route, self.root.sequence, action.request);
                }
                const action = try self.sideband.?.prepare(self.token.generation, now) orelse return false;
                break :blk .{ .query = .{ .aux = action } };
            },
            .power => self.read(.power), .power_on => self.read(.{ .power_on = self.power_value }),
            .train => .{ .control = .{ .train = .{ .root = self.token.root, .rate = self.root.transaction.target.link.rate,
                .lanes = self.root.transaction.target.link.lanes, .enhanced = true,
                .post_adjust = (try dp.receiverCaps(self.plan.root_dpcd)).post_adjust } } },
            .link_config => self.read(.link_config), .link_status => self.read(.link_status),
            .initial_clear_status, .remove_clear, .table_clear => self.mst(.{ .payload_status = true }),
            .initial_clear => self.mst(.{ .payload = .{ .id = 0, .start = 0, .count = 63 } }),
            .initial_updated, .remove_updated, .remove_handled, .table_updated, .act_handled => self.mst(.{ .payload_status = false }),
            .table_before, .initial_verify, .remove_verify, .table_final => self.mst(.{ .payload_table = @intCast(self.cursor) }),
            .remove_rate => self.rate(true, true, false), .remove_rate_check => self.rate(true, true, true),
            .remove_source, .source_streams => blk: {
                while (self.cursor < 8) : (self.cursor += 1) if (self.stream(self.cursor, self.stage == .remove_source)) |value|
                    break :blk .{ .control = .{ .stream = value } };
                return error.State;
            },
            .remove_payload => self.mst(.{ .payload = .{ .id = self.previousEntry().?.allocation.payload_id,
                .start = self.previousEntry().?.allocation.start, .count = 0 } }),
            .remove_act, .act => .{ .control = .{ .act = self.token.root } },
            .trigger => .{ .control = .{ .trigger = .{ .head = self.plan.mode.head, .sor = self.plan.mode.signal.sor } } },
            .rate_on => self.rate(true, false, false), .rate_off => self.rate(false, false, false), .rate_check => self.rate(false, false, true),
            .clear_vsc => .{ .control = .{ .clear_vsc = self.plan.mode.signal.display_id } },
            .clear_hdr => .{ .control = .{ .clear_hdr = self.plan.mode.signal.display_id } },
            .table_payload => self.mst(.{ .payload = .{ .id = self.entry().allocation.payload_id,
                .start = self.entry().allocation.start, .count = self.entry().allocation.demand.slots } }),
            .scanout, .complete => return error.State,
        };
        if (self.request_serial == std.math.maxInt(u64)) return error.Exhausted;
        self.request_serial += 1; self.request_posted = false; self.request = request;
        return true;
    }
    pub fn encode(self: *const Work, output: []u8) !usize { return (self.request orelse return error.Pending).encode(self.plan.object, output); }
    pub fn mutating(self: *const Work) bool {
        return switch (self.stage) {
            .power_on, .train, .initial_clear_status, .initial_clear, .initial_branches,
            .remove_rate, .remove_branch, .remove_source, .remove_clear, .remove_payload, .remove_act,
            .trigger, .source_streams, .rate_on, .table_clear, .table_payload, .act, .clear_vsc, .clear_hdr, .branch, .rate_off => true,
            else => false,
        };
    }
    /// A local request ordinal records exposure, not a hardware completion.
    /// Repeated waiting polls cannot count an RPC twice. Even read-only
    /// sideband queries retain their mailbox until the downstream reply ACK.
    pub fn submitted(self: *Work) !void {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self)) return error.Stale;
        const request = self.request orelse return error.Pending;
        if (self.request_posted) return;
        if (self.mutating()) try self.root.transaction.posted(self.token, self.request_serial);
        self.request_posted = true;
        if (request == .query and request.query == .aux and request.query.aux.operation == .mst and
            request.query.aux.operation.mst == .mailbox and self.sideband != null) {
            const sent = request.query.aux.operation.mst.mailbox;
            if (sent.box == .down_request and @as(usize, sent.offset) + sent.count == self.sideband.?.packet_count) {
                self.root.mailbox_pending = true; self.root.mailbox_deadline = self.deadline;
            }
        }
    }
    fn retry(self: *Work, now: u64, ms: u32) !void {
        if (ms == 0 or ms > 500 or self.retries == 7) return error.RetryExhausted;
        self.retries += 1; self.not_before = now +| @as(u64, ms) * std.time.ns_per_ms;
    }
    fn pollLater(self: *Work, now: u64) !void {
        if (self.polls == 1000) return error.LinkTraining;
        self.polls += 1; self.not_before = now +| std.time.ns_per_ms;
    }
    fn move(self: *Work, stage: Stage) void {
        self.stage = stage; self.cursor = 0; self.path_cursor = 0; self.polls = 0; self.retries = 0; self.not_before = 0;
    }
    fn nextHead(self: *Work) !void {
        self.cursor += 1;
        if (self.cursor < self.head_count) { self.stage = .active; return; }
        for (self.before().entries[0..self.before().count]) |entry_value|
            if (self.seen_heads & (@as(u8, 1) << @intCast(entry_value.allocation.head)) == 0) return error.Stale;
        self.move(.branches);
    }
    fn usage(table: *const budget.Table, edge: budget.Edge) u32 {
        var value: u32 = 0;
        for (table.entries[0..table.count]) |*item| for (item.path[0..item.path_count]) |path|
            if (std.meta.eql(path, edge)) { value += item.allocation.demand.pbn; };
        return value;
    }
    fn afterQueries(self: *Work) void { self.move(if (self.before().count == 0) .power else .table_before); }
    fn fallback(self: *Work, serial: u64) !void {
        if (self.before().count != 0 or self.target().count != 1 or self.source_receipt != 0 or self.table_receipt != 0 or
            self.core_point != 0 or self.training != null or (self.stage != .train and self.stage != .link_config and self.stage != .link_status))
            return error.LinkTraining;
        const sink = try dp.receiverCaps(self.plan.root_dpcd);
        const current = self.root.transaction.target.link;
        var passed = false;
        for ([_]u8{ 30, 20, 10, 6 }) |rate_value| for ([_]u8{ 4, 2, 1 }) |lanes| {
            if (rate_value == current.rate and lanes == current.lanes) { passed = true; continue; }
            if (!passed or rate_value > @min(sink.rate, self.plan.root_source.rate) or lanes > sink.lanes) continue;
            var next = self.root.transaction.target;
            next.link = .{ .rate = rate_value, .lanes = lanes };
            const demand = budget.payload.demand(next.link, next.table.entries[0].timing) catch continue;
            next.table.entries[0].allocation.demand = demand; next.table.slots = demand.slots; next.table.used_pbn = demand.pbn;
            self.token = try self.root.transaction.retargetTraining(self.token, &self.root.live, &next, serial);
            self.move(.train); return;
        };
        return error.LinkTraining;
    }
    fn slot(self: *const Work, offset: u8) u8 {
        if (self.stage == .initial_verify) return 0;
        const table = if (self.stage == .table_final) self.target() else self.before();
        for (table.entries[0..table.count]) |*item| {
            var start = item.allocation.start;
            if (self.stage == .remove_verify) {
                const removed = self.previousEntry().?;
                if (item.allocation.payload_id == removed.allocation.payload_id) continue;
                if (start > removed.allocation.start) start -= removed.allocation.demand.slots;
            }
            if (offset >= start and offset < @as(u16, start) + item.allocation.demand.slots) return item.allocation.payload_id;
        }
        return 0;
    }
    fn consumeSideband(self: *Work, observation: aux.Reply, serial: u64, now: u64) !void {
        const value = &self.sideband.?;
        try value.consume(self.token.generation, observation, serial, now);
        if (value.stage != .complete) return;
        // Even an explicit NAK is drained before it becomes a failed stream
        // transaction. Never let discovery consume this old DOWN_REPLY.
        const response = try wire.reply(value.request, try value.assembly.body());
        self.root.mailbox_pending = false; self.root.mailbox_deadline = 0; self.root.sequence ^= 1;
        defer self.sideband = null;
        if (value.up_pending) return error.Stale;
        if (response == .nack) return error.BranchRejected;
        switch (self.stage) {
            .branches => {
                const expected = self.root.graph.branches[self.cursor].descriptor orelse return error.Stale;
                if (response != .branch or !std.meta.eql(expected, response.branch)) return error.Stale;
                self.cursor += 1;
                if (self.cursor == self.root.graph.branch_count) self.move(.paths);
            },
            .paths => {
                if (response != .path) return error.Unexpected;
                const edge = try budget.Edge.capture(&self.root.graph, self.cursor);
                const owned = usage(self.before(), edge); const wanted = usage(self.target(), edge);
                const resources = response.path;
                const available = @as(u32, resources.free_pbn) + owned;
                if (available > resources.total_pbn) return error.Stale;
                if (wanted > available or wanted > @min(resources.total_pbn, resources.downstream_pbn orelse resources.total_pbn)) return error.Bandwidth;
                self.cursor += 1;
                if (self.cursor == self.root.graph.edge_count) {
                    if (self.before().count == 0) self.afterQueries() else self.move(.query_old);
                }
            },
            .query_old => {
                const old = &self.before().entries[self.cursor];
                if (response != .queried or response.queried.pbn != old.allocation.demand.pbn) return error.Stale;
                self.path_cursor += 1;
                if (self.path_cursor == old.path_count) { self.path_cursor = 0; self.cursor += 1; }
                if (self.cursor == self.before().count) self.afterQueries();
            },
            .initial_branches => { if (response != .ack or response.ack != .clear) return error.Unexpected; self.move(.initial_verify); },
            .remove_branch => { if (response != .allocated) return error.Unexpected; self.move(.remove_query); },
            .remove_query => {
                if (response != .queried or response.queried.pbn != 0) return error.Stale;
                self.move(.remove_source);
            },
            .branch => { if (response != .allocated) return error.Unexpected; self.move(.branch_query); },
            .branch_query => {
                if (response != .queried or response.queried.pbn != self.entry().allocation.demand.pbn) return error.Stale;
                self.branch_receipt = serial; self.move(.rate_off);
            },
            else => return error.State,
        }
    }
    pub fn consume(self: *Work, record: exchange.message.Record, serial: u64, now: u64) !void {
        const request = self.request orelse return error.Pending;
        if (!self.request_posted or serial == 0 or serial <= self.last_receipt) return error.Stale;
        self.request = null; self.last_receipt = serial;
        try self.root.transaction.receipt(self.token, serial);
        errdefer |err| { self.failure = err; }
        try self.guard(now);
        const response = try request.decode(self.plan.object, record);
        if (self.sideband != null) {
            if (response != .query or response.query != .aux) return error.Unexpected;
            return self.consumeSideband(response.query.aux, serial, now);
        }
        if (response == .rate_pending) return self.pollLater(now);
        if (response == .query and response.query == .aux) {
            const observation = response.query.aux;
            if (observation.status == 3 or observation.status == 0x66) return self.retry(now, observation.retry_ms);
            if (observation.status != 0) return error.RmRejected;
            if (observation.kind == .defer_reply) return self.retry(now, 1);
            if (self.stage == .repeaters and observation.kind == .nack) { self.move(.heads); return; }
            if (observation.kind != .ack or observation.count != aux.length(request.query.aux.operation)) return error.Aux;
            self.retries = 0; self.not_before = 0;
            const data = observation.data;
            switch (self.stage) {
                .caps => {
                    if (data[14] & 0x80 != 0) self.move(.extended_caps) else {
                        if (!std.mem.eql(u8, &data, &self.plan.root_dpcd)) return error.Stale;
                        self.move(.mst_caps);
                    }
                },
                .extended_caps => { if (!std.mem.eql(u8, &data, &self.plan.root_dpcd)) return error.Stale; self.move(.mst_caps); },
                .mst_caps => { if (data[0] & 1 == 0) return error.Stale; self.move(.control); },
                .control => { if (data[0] & 7 != 7) return error.Stale; self.move(.guid); },
                .guid => { if (!std.mem.eql(u8, &data, &self.plan.root_guid)) return error.Stale; self.move(.repeaters); },
                .repeaters => { if (data[2] != 0) return error.Unsupported; self.move(.heads); },
                .power => { self.power_value = (data[0] & ~@as(u8, 7)) | 1; self.move(.power_on); },
                .power_on => { self.move(.train); self.not_before = now +| std.time.ns_per_ms; },
                .link_config => {
                    const expected = self.root.transaction.target.link;
                    if (data[0] != expected.rate or data[1] & 31 != expected.lanes or data[1] & 0x80 == 0) return self.fallback(serial);
                    self.move(.link_status);
                },
                .link_status => {
                    const link = self.root.transaction.target.link;
                    if (!dp.trained(data[0..8].*, link.lanes)) return self.fallback(serial);
                    self.training = .{ .link = link, .source = self.plan.root_source, .dpcd = self.plan.root_dpcd,
                        .lanes = data[0..8].*, .receipt = serial };
                    self.move(if (self.before().count == 0) .initial_clear_status else if (self.previousEntry() != null) .remove_rate else .trigger);
                },
                .initial_clear_status => self.move(.initial_clear), .initial_clear => self.move(.initial_updated),
                .initial_updated => { if (data[0] & 1 == 0) return self.pollLater(now); self.move(.initial_branches); },
                .remove_clear => self.move(.remove_payload), .remove_payload => self.move(.remove_updated),
                .remove_updated => { if (data[0] & 1 == 0) return self.pollLater(now); self.move(.remove_act); },
                .remove_handled => { if (data[0] & 2 == 0) return self.pollLater(now); self.move(.remove_verify); },
                .table_clear => self.move(.table_payload), .table_payload => self.move(.table_updated),
                .table_updated => {
                    if (data[0] & 1 == 0) return self.pollLater(now);
                    self.table_receipt = serial; self.move(.scanout);
                },
                .act_handled => { if (data[0] & 2 == 0) return self.pollLater(now); self.move(.table_final); },
                .table_before, .initial_verify, .remove_verify, .table_final => {
                    for (data, 0..) |value, i| {
                        const offset = self.cursor * 16 + @as(u8, @intCast(i));
                        if (offset == 0) {
                            if ((self.stage == .table_final or self.stage == .remove_verify) and value & 2 == 0) return error.Stale;
                        } else if (value != self.slot(offset)) return error.Stale;
                    }
                    self.cursor += 1;
                    if (self.cursor == 4) switch (self.stage) {
                        .table_before => self.move(.link_config),
                        .initial_verify, .remove_verify => self.move(.trigger),
                        .table_final => { self.act_receipt = serial; self.move(.clear_vsc); },
                        else => unreachable,
                    };
                },
                else => return error.State,
            }
            return;
        }
        switch (self.stage) {
            .connected => { if (response != .query or response.query != .connected or response.query.connected != self.token.root) return error.Stale; self.move(.resource); },
            .resource => { if (response != .query or response.query != .resource or !std.meta.eql(response.query.resource, self.plan.root_resource)) return error.Stale; self.move(.source); },
            .source => {
                if (response != .query or response.query != .dp_source or !std.meta.eql(try caps.DpSource.decode(&response.query.dp_source), self.plan.root_source)) return error.Stale;
                self.move(.leaf);
            },
            .leaf => {
                const item = &self.target().entries[self.cursor];
                if (response != .query or response.query != .resource) return error.Unexpected;
                const value = response.query.resource;
                if (!value.dynamic or value.root_port_id != self.token.root or value.index != self.plan.root_resource.index or
                    value.protocol != self.plan.root_resource.protocol or value.kind != 2 or value.location != 0 or
                    !std.meta.eql(item.handle, try self.ids.handle(item.handle.slot))) return error.Stale;
                self.cursor += 1; if (self.cursor == self.target().count) self.move(.caps);
            },
            .heads => {
                if (response != .query or response.query != .heads or response.query.heads == 0 or response.query.heads > 8 or
                    self.plan.mode.head >= response.query.heads) return error.Stale;
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
                    const old = self.before().find(self.active_id) orelse return error.Retained;
                    if (!value.dynamic or value.root_port_id != self.token.root or value.protocol != self.plan.root_resource.protocol or
                        old.allocation.head != self.cursor or !std.meta.eql(old.handle, try self.ids.handle(old.handle.slot))) return error.Stale;
                    const actual = self.ids.slots[old.handle.slot].image orelse return error.Retained;
                    if (actual.head != self.cursor or actual.window != old.window or actual.core_point == 0 or actual.window_point == 0) return error.Stale;
                    self.seen_heads |= @as(u8, 1) << @intCast(self.cursor);
                } else if (self.cursor == self.plan.mode.head) return error.Busy;
                try self.nextHead();
            },
            .train => {
                if (response != .training) return error.Unexpected;
                const value = response.training;
                if (value.status == 3 or value.status == 0x66) return self.retry(now, value.retry_ms);
                if (value.status != 0) return error.RmRejected;
                self.training_attempts += 1;
                if (value.failure != 0) return self.fallback(serial);
                self.move(.link_config);
            },
            .trigger => { if (response != .control) return error.Unexpected; self.move(.source_streams); },
            .source_streams, .remove_source => {
                if (response != .control) return error.Unexpected;
                self.source_receipt = serial; self.cursor += 1;
                while (self.cursor < 8 and self.stream(self.cursor, self.stage == .remove_source) == null) self.cursor += 1;
                if (self.cursor == 8) self.move(if (self.stage == .remove_source) .remove_clear else .rate_on);
            },
            .remove_rate => { if (response != .control) return error.Unexpected; self.move(.remove_rate_check); },
            .remove_rate_check => { if (response != .control) return error.Unexpected; self.move(.remove_branch); },
            .remove_act => { if (response != .control) return error.Unexpected; self.move(.remove_handled); },
            .rate_on => { if (response != .control) return error.Unexpected; self.move(.table_clear); },
            .act => { if (response != .control) return error.Unexpected; self.move(.act_handled); },
            .clear_vsc => { if (response != .control) return error.Unexpected; self.move(.clear_hdr); },
            .clear_hdr => { if (response != .control) return error.Unexpected; self.packet_receipt = serial; self.move(.branch); },
            .rate_off => { if (response != .control) return error.Unexpected; self.move(.rate_check); },
            .rate_check => {
                if (response != .control) return error.Unexpected;
                var result: Result = .{ .stamp = self.plan.mode.signal.mst.?, .training = self.training.?,
                    .payload_id = self.entry().allocation.payload_id, .demand = self.entry().allocation.demand,
                    .revision = self.token.revision + 1, .core_point = self.core_point, .window_point = self.window_point,
                    .source_receipt = self.source_receipt, .table_receipt = self.table_receipt, .act_receipt = self.act_receipt,
                    .packet_receipt = self.packet_receipt, .branch_receipt = self.branch_receipt, .rate_receipt = serial };
                if (!result.complete(self.plan)) return error.Completion;
                result.revision = try self.root.transaction.commit(self.ids, self.token, &self.root.live, self.training.?, serial);
                self.result = result; self.move(.complete);
            },
            else => return error.State,
        }
    }
    /// Runtime has completed Core, Window, positioning and the shared SOR ARM
    /// readback. Those point namespaces are independent of RM ticket serials.
    pub fn scanoutComplete(self: *Work, core_point: u64, window_point: u64) !void {
        if (self.stage != .scanout or self.request != null or self.failure != null or self.training == null or
            core_point == 0 or window_point == 0 or self.table_receipt <= self.source_receipt or self.source_receipt <= self.training.?.receipt)
            return error.State;
        self.core_point = core_point; self.window_point = window_point; self.move(.act);
    }
    /// Call only after the actual Exchange has cancelled a prepared request,
    /// or when no request has been prepared. Posted effects retain the journal.
    pub fn cancelUnsubmitted(self: *Work) !void {
        if (self.self_address != 0 and self.self_address != @intFromPtr(self)) return error.Stale;
        if (self.root.mailbox_pending or (self.request != null and self.request_posted)) return error.Retained;
        try self.root.transaction.cancelUnsubmitted(self.ids, self.token);
        self.request = null; self.failure = error.Cancelled;
    }
    pub fn retainAmbiguous(self: *Work, reason: anyerror) void {
        self.root.transaction.retain(); self.failure = reason;
    }
};
