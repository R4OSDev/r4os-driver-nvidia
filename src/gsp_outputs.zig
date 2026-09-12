//! Resident topology and receiver acquisition on the one live RM graph.
//! All storage stays with the serialized driver. A completed inventory is
//! neither a modeset nor a platform connector publication; callers inspect
//! the explicit rejection/EDID status and must not retain borrowed pointers.
const std = @import("std");
const graph = @import("gsp_rm_graph.zig");
const topology = @import("gsp_topology.zig");
const receiver = @import("gsp_receiver.zig");
const display = @import("gsp_display_rpc.zig");
const exchange = @import("gsp_exchange.zig");
pub const State = enum { detached, topology, receivers, final_check, final_drain, complete, obsolete, failed, returned };
pub const Snapshot = struct {
    generation: u64 = 0,
    captured_at_ns: u64 = 0,
    coherent: bool = false,
    final_receipt_serial: u64 = 0,
    final_rejection: ?topology.Rejection = null,
    topology: topology.Catalog = .{},
    count: usize = 0,
    receivers: [topology.max_routes]receiver.Capture = @splat(.{}),
};
pub const Owner = struct {
    self_address: usize = 0,
    graph: ?*graph.Owner = null,
    board: ?*const @import("vbios.zig").Result = null, // Resident Device-owned CPU copy.
    state: State = .detached,
    deadline: u64 = 0,
    invalidated: bool = false,
    probe: ?topology.Discovery = null,
    refresh: ?receiver.Refresh = null,
    verification: ?display.Channel = null,
    data: Snapshot = .{},
    failure: ?anyerror = null,

    pub fn begin(self: *Owner, parent: *graph.Owner, generation: u64, deadline: u64) !void {
        if ((self.self_address != 0 and self.self_address != @intFromPtr(self)) or
            (self.state != .detached and self.state != .returned) or generation == 0 or
            parent.state != .ready or self.failure != null) return error.State;
        self.self_address = @intFromPtr(self);
        self.graph = parent;
        self.deadline = deadline;
        self.invalidated = false;
        self.refresh = null;
        self.probe = null;
        self.verification = null;
        self.data.generation = generation;
        self.data.captured_at_ns = 0;
        self.data.coherent = false;
        self.data.final_receipt_serial = 0;
        self.data.final_rejection = null;
        self.data.count = 0;
        for (&self.data.receivers) |*capture| capture.* = .{};
        self.probe = try topology.Discovery.init(parent, &self.data.topology, deadline);
        self.state = .topology;
    }
    pub fn active(self: *const Owner) bool {
        return self.state != .detached and self.state != .returned;
    }
    /// Include a failed child's retained receipt; never select an old loan.
    pub fn channel(self: *Owner) ?*display.Channel {
        if (self.verification) |*value| if (value.exchange.phase != .handed_off) return value;
        if (self.refresh) |*value| if (value.channel.exchange.phase != .handed_off) return &value.channel;
        if (self.probe) |*value| if (value.channel.exchange.phase != .handed_off) return &value.channel;
        return null;
    }
    pub fn matches(self: *Owner, current: *const exchange.Exchange, deadline: u64) bool {
        if (self.self_address != @intFromPtr(self) or self.failure != null or
            self.deadline != deadline) return false;
        return switch (self.state) {
            .topology => if (self.probe) |*probe| probe.matches(current, deadline) else false,
            .receivers => if (self.refresh) |*refresh| refresh.matches(current, deadline) else false,
            .final_check => if (self.verification) |*verify| verify.matches(current, .supported, deadline) else false,
            else => false,
        };
    }
    /// Invalidate the whole generation, including previously completed
    /// receivers. Outstanding replies must still drain through their owner.
    pub fn invalidate(self: *Owner) !void {
        if (self.state == .detached) return;
        if (self.self_address != @intFromPtr(self) or self.failure != null) return error.State;
        self.invalidated = true;
        self.data.coherent = false;
        switch (self.state) {
            .topology => try self.probe.?.invalidate(),
            .receivers => if (self.refresh) |*refresh| try refresh.invalidate(),
            else => {},
        }
    }
    pub fn poll(self: *Owner) !?display.Dispatch {
        if (self.self_address != @intFromPtr(self) or self.failure != null or
            (self.state != .topology and self.state != .receivers and self.state != .final_check and self.state != .final_drain)) return error.State;
        errdefer |err| {
            self.failure = err;
            self.data.coherent = false;
            self.state = .failed;
        }
        switch (self.state) {
            .topology => {
                const probe = &self.probe.?;
                if (probe.state != .complete and probe.state != .obsolete) return try probe.poll();
                if (probe.state == .obsolete) self.invalidated = true else _ = try probe.borrow(self.deadline);
                try probe.release(self.deadline);
                if (!self.invalidated) topology.correlate(&self.data.topology, self.board);
                self.state = if (self.invalidated) .obsolete else if (self.data.topology.count == 0) .complete else .receivers;
            },
            .receivers => {
                if (self.refresh) |*refresh| {
                    if (refresh.state != .complete and refresh.state != .obsolete) return try refresh.poll();
                    if (refresh.state == .obsolete) self.invalidated = true else _ = try refresh.borrow(self.deadline);
                    if (refresh.channel.supported) |supported| {
                        if (!std.meta.eql(supported, self.data.topology.supported.?)) self.invalidated = true;
                    }
                    if (refresh.capture.buses) |buses| {
                        if (self.data.topology.routes[self.data.count].buses) |observed|
                            if (!std.meta.eql(buses, observed)) { self.invalidated = true; };
                    }
                    if (refresh.capture.resource) |resource| {
                        if (self.data.topology.routes[self.data.count].resource) |observed|
                            if (!std.meta.eql(resource, observed)) { self.invalidated = true; };
                    }
                    try refresh.release(self.deadline);
                    if (self.invalidated) {
                        self.state = .obsolete;
                    } else {
                        self.data.count += 1;
                        if (self.data.count == self.data.topology.count) self.state = .final_check;
                    }
                    self.refresh = null;
                } else if (self.invalidated) {
                    self.state = .obsolete;
                } else {
                    const index = self.data.count;
                    if (index >= self.data.topology.count or index >= self.data.receivers.len) return error.Bounds;
                    self.refresh = try receiver.Refresh.init(self.graph.?, self.data.topology.routes[index].id,
                        &self.data.receivers[index], self.deadline);
                }
            },
            .final_check, .final_drain => {
                if (self.verification == null) {
                    var loan = try self.graph.?.loan(self.deadline);
                    self.verification = try display.Channel.init(&loan.runtime, loan.object, self.deadline);
                    try self.verification.?.begin(.supported, self.deadline);
                }
                const verify = &self.verification.?;
                if (try verify.poll(self.deadline)) |dispatch| {
                    if (dispatch.value == .notification) return dispatch;
                    const reply = dispatch.value.reply;
                    switch (reply) {
                        .supported => |supported| {
                            if (!std.meta.eql(supported, self.data.topology.supported.?)) self.invalidated = true;
                        },
                        .rpc_error, .control_error => {
                            self.data.final_rejection = .{ .command = .supported,
                                .rpc = if (reply == .rpc_error) reply.rpc_error else null,
                                .control = if (reply == .control_error) reply.control_error else null };
                            self.invalidated = true;
                        },
                        .obsolete => self.invalidated = true,
                        else => return error.Unexpected,
                    }
                    try verify.complete(dispatch.ticket);
                    self.data.final_receipt_serial = dispatch.ticket.serial;
                    self.state = .final_drain;
                } else if (self.state == .final_drain) {
                    var token = try verify.handoff(self.deadline);
                    try self.graph.?.reclaim(&token, self.deadline);
                    self.state = if (self.invalidated) .obsolete else .complete;
                }
            },
            else => unreachable,
        }
        return null;
    }
    /// Called only after the runtime has reclaimed the exact graph token.
    pub fn returned(self: *Owner, now: u64) !void {
        if (self.self_address != @intFromPtr(self) or self.failure != null or
            (self.state != .complete and self.state != .obsolete) or self.graph.?.state != .loaned or
            self.channel() != null or now >= self.deadline) return error.State;
        self.data.coherent = self.state == .complete and !self.invalidated;
        self.data.captured_at_ns = now;
        self.state = .returned;
    }
    pub fn snapshot(self: *const Owner) ?*const Snapshot {
        if (self.self_address != @intFromPtr(self) or self.failure != null or self.state != .returned or
            self.invalidated or !self.data.coherent) return null;
        return &self.data;
    }
};
