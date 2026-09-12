//! Optional NV40_I2C child of the one RM subdevice. Uses the common object
//! wire codec and queue; only an ACKed allocation rejection permits fallback.
//! A protocol/transport/ACK/free failure retains this object and its parents.
const objects = @import("gsp_objects.zig");
const exchange = @import("gsp_exchange.zig");
const boot = @import("gsp_boot_events.zig");
pub const Error = objects.Error;
pub const State = enum { creating, ready, handed_off, destroying, closed, finished, failed };
pub const Owner = struct {
    exchange: exchange.Exchange,
    plan: objects.Plan,
    deadline: u64,
    state: State = .creating,
    live: bool = false,
    rejected: ?u32 = null,
    outstanding: ?objects.Operation = null,
    request: [32]u8 = undefined,
    self_address: usize = 0,

    pub fn init(token: *boot.Handoff, plan: objects.Plan, deadline: u64) Error!Owner {
        try plan.validate();
        if (plan.handles.i2c == 0 or plan.epoch != token.session.epoch) return error.Handle;
        return .{ .exchange = try exchange.Exchange.init(token, deadline), .plan = plan, .deadline = deadline };
    }
    fn stable(self: *Owner) Error!void {
        if (self.self_address != 0 and self.self_address != @intFromPtr(self)) return error.Stale;
        if (self.plan.epoch != self.exchange.session.epoch) return error.Stale;
    }
    fn fail(self: *Owner, reason: Error) Error {
        self.state = .failed;
        return self.exchange.fail(reason);
    }
    pub fn poll(self: *Owner) Error!?exchange.Dispatch {
        try self.stable();
        if (self.state != .creating and self.state != .destroying) return error.State;
        self.self_address = @intFromPtr(self);
        self.exchange.guard(self.deadline) catch |err| return self.fail(err);
        if (self.exchange.pending != null) return error.Pending;
        if (self.outstanding == null) {
            if (self.state == .destroying and !self.live) { self.state = .closed; return null; }
            const operation: objects.Operation = if (self.state == .creating) .{ .allocate = .i2c } else .{ .free = .i2c };
            const encoded = try objects.encode(&self.plan, operation, &self.request);
            try self.exchange.begin(encoded.function, encoded.bytes, self.deadline);
            self.outstanding = operation;
        }
        const dispatch = (self.exchange.poll(self.deadline) catch |err| return self.fail(err)) orelse return null;
        if (!dispatch.response) return dispatch;
        const operation = self.outstanding.?;
        const reply = objects.decode(&self.plan, operation, dispatch.record) catch |err| return self.fail(err);
        if (reply == .rpc_error) return self.fail(error.FirmwareResult);
        self.exchange.complete(dispatch.ticket) catch |err| return self.fail(err);
        if (reply == .rm_error and operation == .free) return self.fail(error.FirmwareResult);
        self.outstanding = null;
        if (operation == .allocate) {
            self.live = reply == .ok;
            if (reply == .rm_error) self.rejected = reply.rm_error;
            self.state = .ready;
        } else {
            self.live = false;
            self.state = .closed;
        }
        return null;
    }
    pub fn handoff(self: *Owner, deadline: u64) Error!boot.Handoff {
        try self.stable();
        if (self.state != .ready and self.state != .closed) return error.State;
        const token = try self.exchange.handoff(deadline);
        self.state = if (self.state == .ready) .handed_off else .finished;
        return token;
    }
    pub fn beginDestroy(self: *Owner, token: *boot.Handoff, deadline: u64) Error!void {
        try self.stable();
        if (self.state != .handed_off or token.session != self.exchange.session) return error.State;
        self.exchange = try exchange.Exchange.init(token, deadline);
        self.deadline = deadline;
        self.state = .destroying;
    }
    pub fn matches(self: *const Owner, current: *const exchange.Exchange, deadline: u64) bool {
        if (self.self_address != @intFromPtr(self) or self.outstanding == null or
            (self.state != .creating and self.state != .destroying)) return false;
        const allocate = self.outstanding.? == .allocate;
        return current == &self.exchange and current.phase == .prepared and current.pending == null and
            current.deadline == deadline and self.deadline == deadline and current.session.epoch == self.plan.epoch and
            current.request.ptr == self.request[0..].ptr and current.request.len == @as(usize, if (allocate) 32 else 16) and
            current.function == @as(u32, if (allocate) 103 else 10);
    }
};
