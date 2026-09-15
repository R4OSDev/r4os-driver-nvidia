//! Release retired virtual IDs using the ordinary RM graph, including when
//! their physical root is disconnected. A catalog removal alone is never
//! permission to release a displayed or published ID.
const std = @import("std");
const rm = @import("gsp_rm_graph.zig");
const display = @import("gsp_display_rpc.zig");
const catalog = @import("gsp_topology.zig");
const ids = @import("gsp_mst_registry.zig");
pub const Stage = enum { supported, heads, active, free, drain, complete, obsolete };
pub const Work = struct {
    self_address: usize = 0,
    parent: *rm.Owner,
    channel: display.Channel,
    registry: *ids.Registry,
    deadline: u64,
    stage: Stage = .supported,
    heads: [8]u32 = @splat(0),
    head_count: u32,
    head_cursor: u32 = 0,
    slot_cursor: usize = 0,
    current: ?ids.Handle = null,
    query: ?display.Query = null,
    invalidated: bool = false,
    failure: ?anyerror = null,
    released: u8 = 0,
    fn eligible(entry: *const ids.Slot) bool {
        return entry.state == .retiring and entry.pending == .none and entry.display_id != 0 and !entry.published and
            entry.image == null and entry.stream_lease == null and entry.route_hold == null;
    }
    pub fn needed(registry: *const ids.Registry) bool {
        for (&registry.slots) |*entry| if (eligible(entry)) return true;
        return false;
    }
    pub fn init(parent: *rm.Owner, registry: *ids.Registry, observed: *const catalog.Catalog, deadline: u64) !Work {
        const count = observed.head_count orelse return error.Descriptor;
        if (parent.state != .ready or observed.epoch != registry.epoch or count > 8 or !needed(registry)) return error.Descriptor;
        var heads: [8]u32 = @splat(0);
        for (observed.heads[0..count], 0..) |head, index| heads[index] = head.display_id orelse return error.Descriptor;
        var loan = try parent.loan(deadline);
        return .{ .parent = parent, .channel = try display.Channel.init(&loan.runtime, loan.object, deadline),
            .registry = registry, .deadline = deadline, .heads = heads, .head_count = count };
    }
    pub fn invalidate(self: *Work) !void {
        self.invalidated = true;
        try self.channel.invalidate();
    }
    pub fn matches(self: *const Work, exchange: *const @import("gsp_exchange.zig").Exchange, deadline: u64) bool {
        return self.self_address == @intFromPtr(self) and self.query != null and self.channel.matches(exchange, self.query.?, deadline);
    }
    fn next(self: *Work) !void {
        while (self.slot_cursor < self.registry.slots.len) : (self.slot_cursor += 1) {
            const entry = &self.registry.slots[self.slot_cursor];
            if (!eligible(entry)) continue;
            var active = false;
            for (self.heads[0..self.head_count]) |id| active = active or id == entry.display_id;
            if (active) continue;
            self.current = try self.registry.handle(self.slot_cursor);
            self.slot_cursor += 1;
            self.stage = .free;
            return;
        }
        self.current = null;
        self.stage = .drain;
    }
    fn consume(self: *Work, reply: display.Reply, serial: u64) !void {
        if (self.stage == .free) {
            if (reply == .mst_free) {
                try self.registry.freed(self.current.?, serial);
                self.released += 1;
            } else if (reply == .rpc_error or reply == .control_error) {
                try self.registry.freeRejected(self.current.?, serial);
                self.failure = error.RmRejected;
            } else return error.Unexpected;
            // A late reply still owns its effect. Never submit another free
            // from this old capture after HPD or an intervening RM sequence.
            if (self.invalidated) self.stage = .drain else try self.next();
            return;
        }
        if (self.invalidated or reply == .obsolete) return error.Stale;
        if (reply == .rpc_error or reply == .control_error) return error.RmRejected;
        switch (self.stage) {
            .supported => {
                if (reply != .supported) return error.Unexpected;
                self.stage = .heads;
            },
            .heads => {
                if (reply != .heads or reply.heads != self.head_count) return error.Stale;
                if (self.head_count == 0) try self.next() else self.stage = .active;
            },
            .active => {
                if (reply != .active or reply.active != self.heads[self.head_cursor]) return error.Stale;
                self.head_cursor += 1;
                if (self.head_cursor == self.head_count) try self.next();
            },
            else => return error.State,
        }
    }
    pub fn poll(self: *Work) !?display.Dispatch {
        if ((self.self_address != 0 and self.self_address != @intFromPtr(self)) or self.stage == .complete or self.stage == .obsolete) return error.State;
        self.self_address = @intFromPtr(self);
        try self.channel.exchange.guard(self.deadline);
        if (self.query != null) {
            const dispatch = self.channel.poll(self.deadline) catch |err| {
                if (err != error.Obsolete) return err;
                if (self.query.? == .mst_free) try self.registry.cancelled(self.current.?);
                self.query = null;
                self.failure = err;
                self.stage = .drain;
                return null;
            } orelse return null;
            if (dispatch.value == .notification) return dispatch;
            self.consume(dispatch.value.reply, dispatch.ticket.serial) catch |err| {
                self.failure = err;
                self.stage = .drain;
            };
            try self.channel.complete(dispatch.ticket);
            self.query = null;
            return null;
        }
        if (self.invalidated) self.stage = .drain;
        if (self.stage == .drain) {
            var token = try self.channel.handoff(self.deadline);
            try self.parent.reclaim(&token, self.deadline);
            self.stage = if (self.invalidated) .obsolete else .complete;
            return null;
        }
        const query: display.Query = switch (self.stage) {
            .supported => .supported,
            .heads => .heads,
            .active => .{ .active = self.head_cursor },
            .free => .{ .mst_free = (try self.registry.free(self.current.?)).free },
            else => return error.State,
        };
        try self.channel.begin(query, self.deadline);
        self.query = query;
        return null;
    }
};
