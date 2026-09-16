//! Independent GPU VA lifetime on the existing RM session. No page allocator,
//! CPU shadow, application pointer or second firmware transport lives here.
//! Owners/bindings are caller-allocated resident nodes, with no fixed map count.
const std = @import("std");
const boot = @import("gsp_boot_events.zig");
const exchange = @import("gsp_exchange.zig");
const names = @import("gsp_rm_names.zig");
pub const wire = @import("gsp_virtual_wire.zig");
pub const alias = @import("gsp_memory_alias.zig");
pub const Error = alias.Error || names.Error;
pub const State = enum { creating, ready, handed_off, mapping, unmapping, destroying, closed, finished, failed };
pub const Config = struct {
    bytes: u64,
    alignment: u64 = 4096,
    fixed_address: u64 = 0,
    location: wire.Location = .system,
    blocklinear: bool = false,
    pte_kind: u8 = 0,
};
pub const Binding = struct {
    source: alias.Use = .{},
    self_address: usize = 0,
    owner: ?*Owner = null,
    previous: ?*Binding = null,
    next: ?*Binding = null,
    mapping: ?wire.Mapping = null,
    stamp: ?wire.Mapping = null,
    mapped: bool = false,
    rejected: ?u32 = null,
};
pub const Info = struct { plan: wire.Allocation, address: u64 };
pub const Owner = struct {
    self_address: usize = 0,
    exchange: exchange.Exchange,
    plan: wire.Allocation,
    stamp: wire.Allocation,
    reservation: names.Children,
    namespace_live: bool = true,
    state: State = .creating,
    address: u64 = 0,
    bindings: ?*Binding = null,
    active: ?*Binding = null,
    request: [160]u8 = undefined,
    request_bytes: usize = 0,
    submitted: bool = false,
    deadline: u64,
    rejected: ?u32 = null,
    failure: ?Error = null,
    protocol_failure: ?exchange.Error = null,

    pub fn init(token: *boot.Handoff, space: @import("gsp_vaspace.zig").Info,
        parent: names.Lease, config: Config, deadline: u64) Error!Owner
    {
        return initStorage(token, space, parent, config, deadline, null);
    }
    pub fn initResident(token: *boot.Handoff, space: @import("gsp_vaspace.zig").Info,
        parent: names.Lease, config: Config, deadline: u64, storage: *names.ResidentChildren) Error!Owner
    {
        return initStorage(token, space, parent, config, deadline, storage);
    }
    fn initStorage(token: *boot.Handoff, space: @import("gsp_vaspace.zig").Info,
        parent: names.Lease, config: Config, deadline: u64, storage: ?*names.ResidentChildren) Error!Owner
    {
        if (token.claimed or token.session.state != .active or token.session.pending != null or
            space.epoch != token.session.epoch or parent.epoch != space.epoch or parent.client != space.client) return error.Stale;
        try token.session.guard(deadline);
        const reservation = if (storage) |resident| try token.session.rm_names.reserveResidentChildren(parent, 1, resident)
            else try token.session.rm_names.reserveChildren(parent, 1);
        errdefer token.session.rm_names.retireChildren(reservation) catch {};
        const plan: wire.Allocation = .{ .space = space, .object = try reservation.object(0), .bytes = config.bytes,
            .alignment = config.alignment, .fixed_address = config.fixed_address, .location = config.location,
            .blocklinear = config.blocklinear, .pte_kind = config.pte_kind };
        try plan.validate();
        return .{ .exchange = try exchange.Exchange.init(token, deadline), .plan = plan, .stamp = plan,
            .reservation = reservation, .deadline = deadline };
    }
    fn stable(self: *const Owner) Error!void {
        if ((self.self_address != 0 and self.self_address != @intFromPtr(self)) or
            self.plan.space.epoch != self.exchange.session.epoch or !std.meta.eql(self.plan, self.stamp)) return error.Stale;
        if (self.namespace_live) try self.exchange.session.rm_names.validateChildren(self.reservation);
    }
    fn fail(self: *Owner, reason: Error) Error {
        self.failure = reason;
        self.state = .failed;
        if (self.namespace_live) self.exchange.session.rm_names.retainChildren(self.reservation) catch {};
        self.protocol_failure = self.exchange.fail(error.Handler);
        return reason;
    }
    pub fn info(self: *const Owner) ?Info {
        self.stable() catch return null;
        if (self.self_address != @intFromPtr(self) or self.address == 0 or self.exchange.session.state != .active or
            (self.state != .ready and self.state != .handed_off)) return null;
        return .{ .plan = self.plan, .address = self.address };
    }
    fn validateBinding(self: *const Owner, binding: *const Binding) Error!void {
        if (binding.self_address != @intFromPtr(binding) or binding.owner != self or
            binding.source.mapping_owner != @as(*const anyopaque, self) or binding.mapping == null or
            !std.meta.eql(binding.mapping, binding.stamp)) return error.Stale;
        if (binding.previous) |previous| {
            if (previous.next != binding or previous.owner != self) return error.Stale;
        } else if (self.bindings != binding) return error.Stale;
        if (binding.next) |next| if (next.previous != binding or next.owner != self) return error.Stale;
        const source = try binding.source.info();
        const map = binding.mapping.?;
        if (!std.meta.eql(map.allocation, self.plan) or map.address != self.address or
            !std.meta.eql(source.space, self.plan.space) or map.memory != source.object or
            map.memory_bytes != source.allocation_bytes or map.memory_offset != source.offset or
            map.bytes != source.bytes or map.location != source.location) return error.Stale;
    }
    /// Immutable execution view of an acknowledged mapping. The resident
    /// resource owner separately prevents unmap while this view is borrowed.
    pub fn executionMapping(self: *const Owner, binding: *const Binding) Error!wire.Mapping {
        if (self.info() == null or self.state != .handed_off or !binding.mapped or binding.rejected != null) return error.State;
        try self.validateBinding(binding);
        try binding.mapping.?.validate();
        return binding.mapping.?;
    }
    fn reclaim(self: *Owner, token: *boot.Handoff, deadline: u64) Error!void {
        try self.stable();
        if (self.info() == null or self.state != .handed_off or token.session != self.exchange.session) return error.State;
        self.exchange = try exchange.Exchange.init(token, deadline);
        self.deadline = deadline;
        self.submitted = false;
        self.request_bytes = 0;
        self.rejected = null;
    }
    /// Success adopts the binding's already retained source until RM rejects
    /// this map, acknowledges its exact unmap, or the old GPU epoch is reset.
    /// Failure before adoption leaves the caller responsible for that source.
    pub fn beginMap(self: *Owner, token: *boot.Handoff, binding: *Binding, offset: u64, deadline: u64) Error!void {
        try self.stable();
        if (binding.self_address != 0 or binding.owner != null or binding.previous != null or binding.next != null or
            binding.mapping != null or binding.stamp != null or binding.mapped or binding.source.mapping_owner != null or self.active != null) return error.Busy;
        const source = try binding.source.info();
        if (!std.meta.eql(source.space, self.plan.space)) return error.Stale;
        const map: wire.Mapping = .{ .allocation = self.plan, .address = self.address, .memory = source.object,
            .memory_bytes = source.allocation_bytes, .memory_offset = source.offset, .virtual_offset = offset,
            .bytes = source.bytes, .location = source.location, .virtual_kind = self.plan.blocklinear or self.plan.pte_kind != 0 };
        try map.validate();
        var cursor = self.bindings;
        while (cursor) |entry| : (cursor = entry.next) {
            try self.validateBinding(entry);
            const previous = entry.mapping.?;
            if (offset < previous.virtual_offset + previous.bytes and previous.virtual_offset < offset + source.bytes) return error.Busy;
        }
        try self.reclaim(token, deadline);
        binding.self_address = @intFromPtr(binding);
        binding.owner = self;
        binding.source.mapping_owner = self;
        binding.mapping = map;
        binding.stamp = map;
        binding.rejected = null;
        binding.next = self.bindings;
        if (self.bindings) |head| head.previous = binding;
        self.bindings = binding;
        self.active = binding;
        self.state = .mapping;
    }
    pub fn beginUnmap(self: *Owner, token: *boot.Handoff, binding: *Binding, deadline: u64, quiesced: bool) Error!void {
        try self.stable();
        if (!quiesced) return error.Busy;
        try self.validateBinding(binding);
        if (!binding.mapped or self.active != null) return error.State;
        try self.reclaim(token, deadline);
        self.active = binding;
        self.state = .unmapping;
    }
    pub fn beginDestroy(self: *Owner, token: *boot.Handoff, deadline: u64, quiesced: bool) Error!void {
        try self.stable();
        if (!quiesced or self.bindings != null or self.active != null) return error.Busy;
        try self.reclaim(token, deadline);
        self.state = .destroying;
    }
    fn detach(self: *Owner, binding: *Binding) void {
        if (binding.previous) |previous| previous.next = binding.next else self.bindings = binding.next;
        if (binding.next) |next| next.previous = binding.previous;
        binding.self_address = 0;
        binding.owner = null;
        binding.previous = null;
        binding.next = null;
        binding.mapping = null;
        binding.stamp = null;
        binding.mapped = false;
    }
    pub fn poll(self: *Owner) Error!?exchange.Dispatch {
        try self.stable();
        if (self.state != .creating and self.state != .mapping and self.state != .unmapping and self.state != .destroying) return error.State;
        self.self_address = @intFromPtr(self);
        return self.advance() catch |err| {
            if (err == error.Pending) return err;
            return self.fail(err);
        };
    }
    fn advance(self: *Owner) Error!?exchange.Dispatch {
        try self.exchange.guard(self.deadline);
        if (self.exchange.pending != null) return error.Pending;
        if (self.active) |binding| try self.validateBinding(binding);
        if (!self.submitted) {
            const encoded = switch (self.state) {
                .creating => try wire.allocate(self.plan, &self.request),
                .destroying => try wire.free(self.plan, &self.request),
                .mapping, .unmapping => try wire.mapping(self.active.?.mapping.?, if (self.state == .mapping) .map else .unmap, &self.request),
                else => return error.State,
            };
            try self.exchange.begin(encoded.function, encoded.bytes, self.deadline);
            self.request_bytes = encoded.bytes.len;
            self.submitted = true;
        }
        const dispatch = (try self.exchange.poll(self.deadline)) orelse return null;
        if (!dispatch.response) return dispatch;
        const result = switch (self.state) {
            .creating => try wire.allocated(self.plan, dispatch.record),
            .destroying => try wire.freed(self.plan, dispatch.record),
            .mapping, .unmapping => try wire.mapped(self.active.?.mapping.?, if (self.state == .mapping) .map else .unmap, dispatch.record),
            else => return error.State,
        };
        // No address, unlink, reference release, or name retirement precedes
        // the queue ACK. A failed ACK keeps the original pending operation.
        try self.exchange.complete(dispatch.ticket);
        if (result == .rejected) {
            self.rejected = result.rejected;
            if (self.state == .destroying or self.state == .unmapping) return error.FirmwareResult;
        }
        switch (self.state) {
            .creating => {
                if (result == .ok) self.address = result.ok else {
                    try self.exchange.session.rm_names.retireChildren(self.reservation);
                    self.namespace_live = false;
                }
                self.state = .ready;
            },
            .mapping, .unmapping => {
                const binding = self.active.?;
                if (self.state == .unmapping or result == .rejected) {
                    try binding.source.closeMapping(self, true);
                    self.detach(binding);
                    binding.rejected = self.rejected;
                } else binding.mapped = true;
                self.active = null;
                self.state = .ready;
            },
            .destroying => {
                try self.exchange.session.rm_names.retireChildren(self.reservation);
                self.namespace_live = false;
                self.address = 0;
                self.state = .closed;
            },
            else => unreachable,
        }
        self.submitted = false;
        return null;
    }
    pub fn handoff(self: *Owner, deadline: u64) Error!boot.Handoff {
        try self.stable();
        if (self.state != .ready and self.state != .closed) return error.State;
        const token = try self.exchange.handoff(deadline);
        self.state = if (self.address == 0) .finished else .handed_off;
        return token;
    }
    /// One binding per worker slice; true means this whole range is retired.
    pub fn closeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence) Error!bool {
        if ((self.self_address != 0 and self.self_address != @intFromPtr(self)) or !std.meta.eql(self.plan, self.stamp) or
            self.plan.space.epoch != self.exchange.session.epoch or !proof.valid(self.plan.space.epoch)) return error.Retained;
        if (self.namespace_live) try self.exchange.session.rm_names.validateChildrenAfterReset(self.reservation, proof);
        if (self.bindings) |binding| {
            try self.validateBinding(binding);
            try binding.source.closeMappingAfterReset(self, proof);
            self.detach(binding);
            self.active = null;
            return false;
        }
        if (self.namespace_live) try self.exchange.session.rm_names.retireChildrenAfterReset(self.reservation, proof);
        self.namespace_live = false;
        self.active = null;
        self.address = 0;
        self.state = .finished;
        return true;
    }
    pub fn matches(self: *const Owner, channel: *const exchange.Exchange, deadline: u64) bool {
        self.stable() catch return false;
        if (self.self_address != @intFromPtr(self) or !self.submitted or channel != &self.exchange or
            channel.phase != .prepared or channel.pending != null or channel.deadline != deadline or self.deadline != deadline or
            channel.request.ptr != self.request[0..].ptr or channel.request.len != self.request_bytes) return false;
        if (self.active) |binding| self.validateBinding(binding) catch return false;
        const function: u32 = switch (self.state) { .creating => 103, .mapping => 14, .unmapping => 15, .destroying => 10, else => return false };
        return channel.function == function;
    }
};
