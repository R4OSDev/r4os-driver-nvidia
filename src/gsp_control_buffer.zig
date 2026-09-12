//! Private native control buffer: resident DMA pages -> RM object -> GPU VA.
//! The same runtime token handles notifications and confirmed reverse teardown.
const std = @import("std");
const r4os = @import("r4os");
const exchange = @import("gsp_exchange.zig");
const boot = @import("gsp_boot_events.zig");
const storage = @import("gsp_control_storage.zig");
pub const wire = @import("gsp_buffer_wire.zig");
pub const Error = wire.Error || storage.Error || error{Retained};
pub const State = enum { creating, unwinding, ready, handed_off, destroying, closed, finished, failed };
pub const Info = struct { epoch: u64, memory: u32, virtual: u32, address: u64, bytes: u64 };
pub const Owner = struct {
    self_address: usize = 0,
    exchange: exchange.Exchange,
    ctx: r4os.r4dev.DriverContext,
    adapter: u32,
    binding: wire.Binding,
    backing: storage.Storage = .{},
    state: State = .creating,
    registered: bool = false,
    allocated: bool = false,
    mapped: bool = false,
    address: u64 = 0,
    rejected: ?u32 = null,
    host_rejected: ?anyerror = null,
    failure: ?anyerror = null,
    protocol_failure: ?exchange.Error = null,
    last_status: ?u32 = null,
    operation: ?wire.Operation = null,
    request: [wire.max_request_bytes]u8 = undefined,
    deadline: u64,

    pub fn init(token: *boot.Handoff, ctx: *const r4os.r4dev.DriverContext, adapter: u32, binding: wire.Binding, deadline: u64) Error!Owner {
        try wire.validate(binding);
        if (adapter == 0 or token.session.epoch != binding.space.epoch) return error.Stale;
        return .{ .ctx = ctx.*, .adapter = adapter, .binding = binding, .deadline = deadline, .exchange = try exchange.Exchange.init(token, deadline) };
    }
    fn stable(self: *const Owner) Error!void {
        if ((self.self_address != 0 and self.self_address != @intFromPtr(self)) or
            self.binding.space.epoch != self.exchange.session.epoch) return error.Stale;
    }
    fn fail(self: *Owner, err: Error) Error {
        self.state = .failed;
        self.failure = err;
        self.protocol_failure = self.exchange.fail(error.Handler);
        return err;
    }
    pub fn info(self: *const Owner) ?Info {
        if (self.self_address != @intFromPtr(self) or (self.state != .ready and self.state != .handed_off) or
            !self.mapped or !self.backing.gpuReady(self.address) or !self.backing.retained or self.exchange.session.state != .active) return null;
        return .{ .epoch = self.binding.space.epoch, .memory = self.binding.memory, .virtual = self.binding.virtual, .address = self.address, .bytes = wire.bytes };
    }
    pub fn poll(self: *Owner) Error!?exchange.Dispatch {
        try self.stable();
        if (self.state != .creating and self.state != .unwinding and self.state != .destroying) return error.State;
        self.self_address = @intFromPtr(self);
        return self.advance() catch |err| {
            if (err == error.Pending) return err;
            return self.fail(err);
        };
    }
    fn advance(self: *Owner) Error!?exchange.Dispatch {
        try self.exchange.guard(self.deadline);
        if (self.backing.prepared and !self.backing.valid()) return error.Stale;
        if (self.exchange.pending != null) return error.Pending;
        if (self.operation == null) {
            if (self.state == .creating and !self.backing.prepared) {
                self.backing.prepare(&self.ctx, self.adapter, self.binding.space.epoch) catch |err| {
                    self.host_rejected = err;
                    self.state = .unwinding;
                    return null;
                };
                try self.exchange.guard(self.deadline);
                return null;
            }
            const operation: wire.Operation = if (self.state == .creating)
                if (!self.registered) .register else if (!self.allocated) .allocate else .map
            else if (self.mapped) .unmap else if (self.allocated) .free_virtual else if (self.registered) .free_memory else {
                self.backing.retained = false;
                if (!self.backing.close()) return error.Retained;
                self.state = if (self.state == .unwinding) .ready else .closed;
                return null;
            };
            const encoded = try wire.encode(self.binding, operation, &self.backing.pages, self.address, &self.request);
            try self.exchange.begin(encoded.function, encoded.bytes, self.deadline);
            // TX publication may be ambiguous even when send reports failure.
            if (operation == .register) self.backing.retained = true;
            self.operation = operation;
        }
        const dispatch = (try self.exchange.poll(self.deadline)) orelse return null;
        if (!dispatch.response) return dispatch;
        const operation = self.operation.?;
        const reply = try wire.decode(self.binding, operation, self.request[0..wire.length(operation)], dispatch.record, self.address);
        self.last_status = if (reply == .rejected) reply.rejected else 0;
        try self.exchange.complete(dispatch.ticket);
        if (reply == .rejected) {
            if (self.state != .creating) return error.FirmwareResult;
            self.rejected = reply.rejected;
            self.state = .unwinding;
        } else switch (operation) {
            .register => self.registered = true,
            .allocate => {
                self.allocated = true;
                self.address = reply.ok;
            },
            .map => {
                self.mapped = true;
                self.state = .ready;
                self.backing.retainGpu(self.address) catch |err| {
                    // RM reached the map, but common residency admission
                    // failed. Confirm reverse RPC teardown before BO free.
                    self.host_rejected = err;
                    self.state = .unwinding;
                };
            },
            .unmap => self.mapped = false,
            .free_virtual => {
                self.allocated = false;
                self.address = 0;
            },
            .free_memory => self.registered = false,
        }
        self.operation = null;
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
        const operation = self.operation orelse return false;
        if (self.self_address != @intFromPtr(self) or self.failure != null or
            (self.state != .creating and self.state != .unwinding and self.state != .destroying)) return false;
        return current == &self.exchange and current.phase == .prepared and current.pending == null and
            current.deadline == deadline and self.deadline == deadline and current.session.epoch == self.binding.space.epoch and
            current.request.ptr == self.request[0..].ptr and current.request.len == wire.length(operation) and
            current.function == wire.function(operation) and self.backing.retained;
    }
};
