//! One reserved RM client graph: root/device/subdevice/display plus HPD/DP
//! subscriptions. All lifetime transitions use the actual shared queue token.
//! No firmware startup, object memory, queue pump, recovery or quiescence.
const std = @import("std");
const boot = @import("gsp_boot_events.zig");
const objects = @import("gsp_objects.zig");
const events = @import("gsp_event_objects.zig");
const runtime_events = @import("gsp_runtime_events.zig");
const exchange = @import("gsp_exchange.zig");
const names = @import("gsp_rm_names.zig");
pub const Error = exchange.Error || names.Error;
pub const State = enum { base_creating, events_creating, ready, loaned, rejected, events_destroying, base_destroying, closed, finished, failed };
pub const Owner = struct {
    reservation: names.Lease,
    base: objects.Owner,
    subscriptions: ?events.Owner = null,
    state: State = .base_creating,
    self_address: usize = 0,
    failure: ?Error = null,
    deadline: u64,

    /// The handoff and session must be retained at a stable address. This
    /// value may be moved only before its first poll; no live owner copies.
    pub fn init(runtime: *boot.Handoff, process_id: u32, process_name: []const u8, deadline: u64) Error!Owner {
        if (runtime.claimed or runtime.session.state != .active or runtime.session.pending != null) return error.State;
        try runtime.session.guard(deadline);
        // Reject bad caller inputs before consuming any names or queue token.
        if (process_name.len >= 100 or std.mem.indexOfScalar(u8, process_name, 0) != null) return error.Payload;
        const reservation = try runtime.session.rm_names.reserve(5);
        errdefer runtime.session.rm_names.retire(reservation) catch {};
        const plan = try objects.Plan.init(runtime.session.epoch, .{
            .client = reservation.client,
            .device = try reservation.object(0),
            .subdevice = try reservation.object(1),
            .display = try reservation.object(2),
        }, process_id, process_name);
        return .{ .reservation = reservation, .base = try objects.Owner.init(runtime, plan, deadline), .deadline = deadline };
    }
    fn session(self: *Owner) *exchange.transport.Session {
        return self.base.exchange.session;
    }
    fn stable(self: *Owner) Error!void {
        if (self.self_address != 0 and self.self_address != @intFromPtr(self)) return error.Stale;
        if (self.session().epoch != self.reservation.epoch) return error.Stale;
        try self.session().rm_names.validate(self.reservation);
    }
    fn fail(self: *Owner, reason: Error) Error {
        // Old/copy/loaned owners must never poison a transferred live queue.
        if ((self.self_address != 0 and self.self_address != @intFromPtr(self)) or self.state == .loaned or self.state == .finished) return error.State;
        if (self.failure == null) self.failure = reason;
        self.session().rm_names.retain(self.reservation) catch {};
        self.session().stop();
        self.state = .failed;
        return reason;
    }
    /// The returned Exchange is the current semantic owner for notification
    /// dispatch, not permission to ACK object replies or drive it recursively.
    pub fn notificationOwner(self: *Owner) Error!*exchange.Exchange {
        try self.stable();
        return switch (self.state) {
            .base_creating, .base_destroying => &self.base.exchange,
            .events_creating, .events_destroying => &self.subscriptions.?.exchange,
            else => error.State,
        };
    }
    /// The actual retained semantic channel, including its failure receipt.
    /// Loaned/finished children must never shadow the current runtime owner.
    pub fn channel(self: *Owner) ?*exchange.Exchange {
        if (self.subscriptions) |*value| if (value.exchange.phase != .handed_off) return &value.exchange;
        if (self.base.exchange.phase != .handed_off) return &self.base.exchange;
        return null;
    }
    /// Pure queue-notifier admission for this graph's exact encoded request.
    /// This is not generic permission to submit RM alloc/control/free calls.
    pub fn matches(self: *Owner, current: *const exchange.Exchange, deadline: u64) bool {
        if (self.self_address != @intFromPtr(self) or self.failure != null or
            current.session.epoch != self.reservation.epoch or current.phase != .prepared or
            current.deadline != deadline or self.deadline != deadline) return false;
        switch (self.state) {
            .base_creating, .base_destroying => {
                const owner = &self.base;
                const operation = owner.outstanding orelse return false;
                const size: usize = switch (operation) { .allocate => |kind| 32 + objects.paramsSize(kind), .free => 16 };
                return current == &owner.exchange and current.request.ptr == owner.request_bytes[0..].ptr and
                    current.request.len == size and current.function == @as(u32, if (operation == .allocate) 103 else 10);
            },
            .events_creating, .events_destroying => {
                const owner = if (self.subscriptions) |*value| value else return false;
                const operation = owner.outstanding orelse return false;
                const size: usize = switch (operation) { .allocate => 56, .enable, .disable => 44, .free => 16 };
                const function: u32 = switch (operation) { .allocate => 103, .enable, .disable => 76, .free => 10 };
                return current == &owner.exchange and current.request.ptr == owner.request[0..].ptr and
                    current.request.len == size and current.function == function;
            },
            else => return false,
        }
    }
    pub fn eventSink(self: *Owner) Error!runtime_events.Sink {
        try self.stable();
        if (self.state == .failed or self.state == .closed or self.state == .finished) return error.State;
        if (self.subscriptions) |*owner| return owner.sink();
        return error.State;
    }
    /// One existing bounded owner step or one token transition per call.
    /// Notifications are returned for the appropriate real owner to handle.
    pub fn poll(self: *Owner) Error!?exchange.Dispatch {
        if (self.state != .base_creating and self.state != .events_creating and self.state != .events_destroying and self.state != .base_destroying) return error.State;
        try self.stable();
        self.self_address = @intFromPtr(self);
        self.session().guard(self.deadline) catch |err| return self.fail(err);
        switch (self.state) {
            .base_creating => {
                if (self.base.state == .objects_ready) {
                    var parent_loan = self.base.loan(self.deadline) catch |err| return self.fail(err);
                    const plan = events.Plan.init(self.base.plan, .{ .hotplug = try self.reservation.object(3), .dp_irq = try self.reservation.object(4) }) catch |err| return self.fail(err);
                    self.subscriptions = events.Owner.init(&parent_loan.runtime, plan, self.deadline) catch |err| return self.fail(err);
                    self.state = .events_creating;
                    return null;
                }
                const dispatch = self.base.poll() catch |err| {
                    if (err == error.Pending) return err;
                    return self.fail(err);
                };
                if (self.base.state == .rejected) self.state = .rejected;
                return dispatch;
            },
            .events_creating => {
                const dispatch = self.subscriptions.?.poll() catch |err| {
                    if (err == error.Pending) return err;
                    return self.fail(err);
                };
                switch (self.subscriptions.?.state) {
                    .ready => self.state = .ready,
                    .rejected => self.state = .rejected,
                    else => {},
                }
                return dispatch;
            },
            .events_destroying => {
                if (self.subscriptions.?.state == .objects_closed) {
                    var token = self.subscriptions.?.finish(self.deadline) catch |err| return self.fail(err);
                    self.base.reclaim(&token, self.deadline) catch |err| return self.fail(err);
                    self.base.beginDestroy(self.deadline) catch |err| return self.fail(err);
                    self.state = .base_destroying;
                    return null;
                }
                return self.subscriptions.?.poll() catch |err| {
                    if (err == error.Pending) return err;
                    return self.fail(err);
                };
            },
            .base_destroying => {
                const dispatch = self.base.poll() catch |err| {
                    if (err == error.Pending) return err;
                    return self.fail(err);
                };
                if (self.base.state == .objects_closed) self.state = .closed;
                return dispatch;
            },
            else => unreachable,
        }
    }
    pub fn loan(self: *Owner, deadline: u64) Error!objects.Loan {
        if (self.state != .ready) return error.State;
        try self.stable();
        const result = try self.subscriptions.?.loan(deadline);
        self.state = .loaned;
        return result;
    }
    pub fn reclaim(self: *Owner, token: *boot.Handoff, deadline: u64) Error!void {
        if (self.state != .loaned) return error.State;
        try self.stable();
        try self.subscriptions.?.reclaim(token, deadline);
        self.state = .ready;
    }
    pub fn takeChanges(self: *Owner, deadline: u64) Error!events.Changes {
        if (self.state != .ready and self.state != .loaned) return error.State;
        try self.stable();
        return self.subscriptions.?.takeChanges(deadline);
    }
    pub fn beginDestroy(self: *Owner, deadline: u64) Error!void {
        if (self.state != .ready and self.state != .rejected) return error.State;
        try self.stable();
        if (self.subscriptions) |*owner| {
            owner.beginDestroy(deadline) catch |err| return self.fail(err);
            self.state = .events_destroying;
        } else {
            self.base.beginDestroy(deadline) catch |err| return self.fail(err);
            self.state = .base_destroying;
        }
        self.deadline = deadline;
    }
    pub fn finish(self: *Owner, deadline: u64) Error!boot.Handoff {
        if (self.state != .closed) return error.State;
        try self.stable();
        // Keep the token local until retirement succeeds. Failed retirement
        // cannot expose a runtime while leaving a supposedly closed graph.
        const token = self.base.finish(deadline) catch |err| return self.fail(err);
        self.session().rm_names.retire(self.reservation) catch |err| return self.fail(err);
        self.state = .finished;
        return token;
    }
    /// Before any poll, return the runtime with no RM/queue work. Even these
    /// unused names remain consumed; later graphs receive fresh wire IDs.
    pub fn cancelUnsubmitted(self: *Owner, deadline: u64) Error!boot.Handoff {
        if (self.state != .base_creating or self.self_address != 0 or self.base.outstanding != null or self.subscriptions != null) return error.State;
        try self.stable();
        for (self.base.slots) |slot| if (slot != .absent) return error.State;
        const token = self.base.exchange.handoff(deadline) catch |err| return self.fail(err);
        self.session().rm_names.retire(self.reservation) catch |err| return self.fail(err);
        self.base.state = .finished;
        self.state = .finished;
        return token;
    }
};
