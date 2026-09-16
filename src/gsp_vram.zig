//! Native RM backing for common BOs. The initial GPU mapping belongs to the
//! backing itself; no permanent common lease can deadlock its last-use release.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const boot = @import("gsp_boot_events.zig");
const exchange = @import("gsp_exchange.zig");
const names = @import("gsp_rm_names.zig");
const vaspace = @import("gsp_vaspace.zig");
pub const wire = @import("gsp_vram_wire.zig");
pub const surface = @import("gsp_surface_layout.zig");
pub const storage = @import("gsp_native_backing.zig");
pub const alias = @import("gsp_memory_alias.zig");
pub const Error = wire.Error || names.Error || surface.Error || storage.Error || error{ Api, Descriptor, Memory, Busy, Retained };
pub const State = enum { creating, unwinding, ready, handed_off, destroying, closed, finished, failed };
pub const Info = struct { reference: a.GfxBufferReference, address: u64, logical_bytes: u64, allocation_bytes: u64, epoch: u64, surface: surface.Plan, physical: ?storage.Physical = null };
pub const Owner = struct {
    self_address: usize = 0,
    exchange: exchange.Exchange,
    memory: r4os.driver_memory.Context,
    names: names.Children,
    namespace_live: bool = true,
    binding: wire.Binding,
    adapter: u32,
    logical_bytes: u64,
    bytes: u64,
    layout: surface.Plan,
    storage_policy: ?storage.Policy = null,
    physical_extent: ?storage.Physical = null,
    aliases: alias.Set = .{},
    storage_claimed: bool = false,
    state: State = .creating,
    reservation: a.GfxOwnedBufferReservation = .{},
    reservation_stamp: a.GfxOwnedBufferReservation = .{},
    common_live: bool = false,
    committed: bool = false,
    reference: a.GfxBufferReference = .{},
    reference_live: bool = false,
    closing: bool = false,
    release: a.GfxOwnedBufferRelease = .{},
    physical: bool = false,
    virtual: bool = false,
    mapped: bool = false,
    address: u64 = 0,
    operation: ?wire.Operation = null,
    request: [160]u8 = undefined,
    request_bytes: usize = 0,
    deadline: u64,
    rejected: ?u32 = null,
    last_status: ?u32 = null,
    host_rejected: ?i32 = null,
    failure: ?Error = null,
    protocol_failure: ?exchange.Error = null,

    pub fn init(token: *boot.Handoff, ctx: *const r4os.r4dev.DriverContext, adapter: u32, space: vaspace.Info,
        parent: names.Lease, logical_bytes: u64, deadline: u64) Error!Owner
    {
        return initPlanned(token, ctx, adapter, space, parent, try surface.raw(adapter, space, logical_bytes), deadline);
    }
    pub fn initPlanned(token: *boot.Handoff, ctx: *const r4os.r4dev.DriverContext, adapter: u32, space: vaspace.Info,
        parent: names.Lease, plan: surface.Plan, deadline: u64) Error!Owner
    {
        return initStorage(token, ctx, adapter, space, parent, plan, null, deadline);
    }
    pub fn initStorage(token: *boot.Handoff, ctx: *const r4os.r4dev.DriverContext, adapter: u32, space: vaspace.Info,
        parent: names.Lease, plan: surface.Plan, policy: ?storage.Policy, deadline: u64) Error!Owner
    {
        if (token.claimed or token.session.state != .active or token.session.pending != null or adapter == 0 or
            space.epoch != token.session.epoch or parent.epoch != space.epoch or parent.client != space.client) return error.Stale;
        try token.session.guard(deadline);
        const memory = ctx.memory() orelse return error.Api;
        if (memory.table.size < 152 or memory.table.buffer_reserve == 0 or memory.table.buffer_commit == 0 or
            memory.table.buffer_abort == 0 or memory.table.buffer_take_release == 0 or memory.table.buffer_finish_release == 0) return error.Api;
        try plan.validate(adapter, space);
        if (policy) |value| {
            switch (value.role) {
                .control => if (plan.request != null) return error.Descriptor,
                .scanout => {
                    _ = try @import("gsp_display_image.zig").create(plan, 1, 1);
                    if (plan.descriptor.usage & a.gfx_buffer_usage_transfer_target == 0) return error.Descriptor;
                },
            }
            try value.validate(space, plan.allocation_bytes);
        }
        const children = try token.session.rm_names.reserveChildren(parent, 2);
        errdefer token.session.rm_names.retireChildren(children) catch {};
        const binding: wire.Binding = .{ .space = space, .memory = try children.object(0), .virtual = try children.object(1) };
        return .{ .exchange = try exchange.Exchange.init(token, deadline), .memory = memory, .names = children,
            .binding = binding, .adapter = adapter, .logical_bytes = plan.descriptor.byte_length,
            .bytes = plan.allocation_bytes, .layout = plan, .storage_policy = policy, .deadline = deadline };
    }
    fn stable(self: *const Owner) Error!void {
        if ((self.self_address != 0 and self.self_address != @intFromPtr(self)) or self.binding.space.epoch != self.exchange.session.epoch or
            !std.meta.eql(self.reservation, self.reservation_stamp)) return error.Stale;
        if (self.namespace_live) try self.exchange.session.rm_names.validateChildren(self.names);
    }
    fn fail(self: *Owner, err: Error) Error {
        self.failure = err; self.state = .failed;
        if (self.namespace_live) self.exchange.session.rm_names.retainChildren(self.names) catch {};
        self.protocol_failure = self.exchange.fail(error.Handler);
        return err;
    }
    pub fn info(self: *const Owner) ?Info {
        self.stable() catch return null;
        if (self.self_address != @intFromPtr(self) or !self.committed or !self.reference_live or self.closing or !self.mapped or
            self.exchange.session.state != .active or (self.state != .ready and self.state != .handed_off)) return null;
        return .{ .reference = self.reference, .address = self.address, .logical_bytes = self.logical_bytes,
            .allocation_bytes = self.bytes, .epoch = self.binding.space.epoch, .surface = self.layout, .physical = self.physical_extent };
    }
    pub fn retainStorage(self: *Owner, use: *storage.Use) Error!void {
        const value = self.info() orelse return error.State;
        const physical = value.physical orelse return error.Unsupported;
        const policy = self.storage_policy orelse return error.Unsupported;
        try policy.validate(self.binding.space, self.bytes);
        // Clearing is an allocation-time guarantee, not a reusable clean
        // state after a channel/group may have written its control storage.
        if (self.storage_claimed) return error.Busy;
        use.acquire(self.memory, .{ .reference = self.reference, .physical = physical, .address = self.address,
            .bytes = self.logical_bytes, .epoch = self.binding.space.epoch, .adapter = self.adapter,
            .driver_owner = self.reservation.driver_owner }) catch |err| {
            if (err == error.Descriptor or err == error.Retained) return self.fail(err);
            return err;
        };
        self.storage_claimed = true;
    }
    pub fn retainAlias(self: *Owner, use: *alias.Use, offset: u64, bytes: u64) Error!void {
        const value = self.info() orelse return error.State;
        if (self.storage_policy != null or self.layout.privileged or self.layout.readonly) return error.Unsupported;
        if (bytes == 0 or (offset | bytes) & 4095 != 0 or bytes > self.logical_bytes or offset > self.logical_bytes - bytes) return error.Bounds;
        try self.aliases.acquire(use, .{ .space = self.binding.space, .object = self.binding.memory,
            .allocation_bytes = self.bytes, .offset = offset, .bytes = bytes, .location = .video });
        use.retainCommon(self.memory, value.reference) catch |err| {
            if (err == error.Busy) { try use.close(true); return err; }
            // A partial/invalid returned import is retained, never dropped or
            // treated as an ordinary allocation rejection.
            return self.fail(err);
        };
    }
    /// Called only with a separately retained canonical active-job reference.
    /// The producer may already have closed its reference; the common queue
    /// and this retained reference still veto native release-ticket issuance.
    pub fn queuedInfo(self: *const Owner, reference: a.GfxBufferReference) ?Info {
        self.stable() catch return null;
        if (self.self_address != @intFromPtr(self) or !self.committed or !self.common_live or !self.mapped or self.state != .handed_off or
            self.exchange.session.state != .active or (if (self.storage_policy) |policy| policy.role != .scanout else false) or
            reference.flags != a.gfx_buffer_reference_mapping_only or reference.reference.id == 0 or
            !std.meta.eql(reference.buffer, self.reservation.buffer)) return null;
        return .{ .reference = reference, .address = self.address, .logical_bytes = self.logical_bytes,
            .allocation_bytes = self.bytes, .epoch = self.binding.space.epoch, .surface = self.layout };
    }
    /// A full reference issued for an admitted scanout job may outlive the
    /// public producer. Private control storage can never enter this path.
    pub fn scanoutInfo(self: *const Owner, reference: a.GfxBufferReference) ?Info {
        self.stable() catch return null;
        const policy = self.storage_policy orelse return null;
        if (policy.role != .scanout or self.physical_extent == null or !self.layout.scanout() or
            self.self_address != @intFromPtr(self) or !self.committed or !self.common_live or !self.mapped or self.state != .handed_off or
            self.exchange.session.state != .active or reference.version != 1 or reference.size < @sizeOf(a.GfxBufferReference) or
            reference.flags != a.gfx_buffer_reference_immutable or reference.reserved0 != 0 or !valid(reference.reference) or
            !std.meta.eql(reference.buffer, self.reservation.buffer)) return null;
        return .{ .reference = reference, .address = self.address, .logical_bytes = self.logical_bytes,
            .allocation_bytes = self.bytes, .epoch = self.binding.space.epoch, .surface = self.layout, .physical = self.physical_extent };
    }
    fn reserve(self: *Owner) Error!void {
        const result = self.memory.bufferReserve(&self.layout.descriptor, self.binding.memory, &self.reservation);
        self.reservation_stamp = self.reservation;
        if (result != a.gfx_buffer_result_ok and self.reservation.buffer.id == 0) {
            self.host_rejected = result; self.state = .unwinding; return;
        }
        const v = self.reservation;
        if (v.version != 1 or v.size < @sizeOf(a.GfxOwnedBufferReservation) or v.reserved0 != 0 or
            !valid(v.buffer) or !valid(v.reference) or v.allocation_bytes != self.bytes or v.cookie != self.binding.memory or
            v.device_generation != self.binding.space.epoch or v.adapter_id != self.adapter or v.driver_owner == 0 or v.driver_generation == 0) return error.Descriptor;
        self.common_live = true;
        if (result != a.gfx_buffer_result_ok) { self.host_rejected = result; self.state = .unwinding; }
    }
    fn publish(self: *Owner) Error!void {
        const result = self.memory.bufferCommit(&self.reservation, &self.reference);
        if (result != a.gfx_buffer_result_ok and self.reference.reference.id == 0) {
            self.host_rejected = result; self.state = .unwinding; return;
        }
        const v = self.reference;
        if (v.version != 1 or v.size < @sizeOf(a.GfxBufferReference) or v.flags != 0 or v.reserved0 != 0 or
            !std.meta.eql(v.reference, self.reservation.reference) or !std.meta.eql(v.buffer, self.reservation.buffer)) return error.Descriptor;
        if (result != a.gfx_buffer_result_ok) return error.Retained;
        self.committed = true; self.reference_live = true; self.state = .ready;
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
        if (self.exchange.pending != null) return error.Pending;
        if (self.operation == null) {
            if (self.state == .creating and !self.common_live) { try self.reserve(); return null; }
            const op: wire.Operation = if (self.state == .creating) blk: {
                if (!self.physical) break :blk .allocate_memory;
                if (!self.virtual) break :blk .allocate_virtual;
                if (!self.mapped) break :blk .map;
                try self.publish(); return null;
            } else if (self.mapped) .unmap else if (self.virtual) .free_virtual else if (self.physical) .free_memory else {
                if (self.common_live) {
                    const result = if (self.committed) self.memory.bufferFinishRelease(&self.release, 1) else self.memory.bufferAbort(&self.reservation, 1);
                    if (result != a.gfx_buffer_result_ok) return error.Retained;
                    self.common_live = false;
                }
                if (self.namespace_live) { try self.exchange.session.rm_names.retireChildren(self.names); self.namespace_live = false; }
                self.state = if (self.state == .unwinding) .ready else .closed;
                return null;
            };
            const encoded = try wire.encodeLayout(self.binding, self.bytes, .{ .blocklinear = self.layout.blocklinear(), .scanout = self.layout.scanout(),
                .contiguous = self.storage_policy != null, .granule = self.layout.descriptor.alignment,
                .privileged = self.layout.privileged, .readonly = self.layout.readonly }, op, self.address, &self.request);
            try self.exchange.begin(encoded.function, encoded.bytes, self.deadline);
            self.operation = op; self.request_bytes = encoded.bytes.len;
        }
        const dispatch = (try self.exchange.poll(self.deadline)) orelse return null;
        if (!dispatch.response) return dispatch;
        const op = self.operation.?;
        const reply = try wire.decode(self.binding, self.bytes, op, self.request[0..self.request_bytes], dispatch.record, self.address);
        if (op == .allocate_memory and reply == .ok) if (self.storage_policy) |policy| {
            if (reply.ok == 0 or reply.ok > policy.physical_bytes or self.bytes > policy.physical_bytes - reply.ok) return error.Bounds;
        };
        self.last_status = if (reply == .rejected) reply.rejected else 0;
        try self.exchange.complete(dispatch.ticket);
        if (reply == .rejected) {
            if (self.state != .creating) return error.FirmwareResult;
            self.rejected = reply.rejected; self.state = .unwinding;
        } else switch (op) {
            .allocate_memory => {
                self.physical = true;
                if (self.storage_policy != null) self.physical_extent = .{ .base = reply.ok, .bytes = self.bytes };
            },
            .allocate_virtual => { self.virtual = true; self.address = reply.ok; },
            .map => self.mapped = true,
            .unmap => self.mapped = false,
            .free_virtual => { self.virtual = false; self.address = 0; },
            .free_memory => { self.physical = false; self.physical_extent = null; },
        }
        self.operation = null;
        return null;
    }
    // Closing the initial reference is a logical operation. Imports, queue
    // leases and execution uses can independently keep the allocation alive.
    pub fn closeReference(self: *Owner) Error!void {
        try self.stable();
        if (self.state != .handed_off) return error.State;
        if (self.reference_live) {
            if (self.memory.bufferRelease(&self.reference.reference) != a.gfx_buffer_result_ok) return self.fail(error.Retained);
            self.reference_live = false;
        }
        self.closing = true;
    }
    pub fn accepts(self: *const Owner, ticket: a.GfxOwnedBufferRelease) bool {
        self.stable() catch return false;
        return self.committed and self.common_live and self.closing and !self.reference_live and self.state == .handed_off and
            ticket.version == 1 and ticket.size >= @sizeOf(a.GfxOwnedBufferRelease) and ticket.reserved0 == 0 and ticket.attempt != 0 and
            std.meta.eql(ticket.buffer, self.reservation.buffer) and ticket.cookie == self.reservation.cookie and ticket.byte_length == self.bytes and
            ticket.device_generation == self.reservation.device_generation and ticket.driver_generation == self.reservation.driver_generation and
            ticket.adapter_id == self.adapter and ticket.driver_owner == self.reservation.driver_owner;
    }
    pub fn beginDestroy(self: *Owner, token: *boot.Handoff, ticket: a.GfxOwnedBufferRelease, deadline: u64) Error!void {
        if (!self.aliases.empty()) return error.Busy;
        if (!self.accepts(ticket) or token.session != self.exchange.session) return error.Stale;
        self.exchange = try exchange.Exchange.init(token, deadline);
        self.release = ticket; self.deadline = deadline; self.state = .destroying;
    }
    pub fn acceptsAfterReset(self: *const Owner, ticket: a.GfxOwnedBufferRelease) bool {
        return self.committed and self.common_live and self.closing and !self.reference_live and
            ticket.version == 1 and ticket.size >= @sizeOf(a.GfxOwnedBufferRelease) and ticket.reserved0 == 0 and ticket.attempt != 0 and
            std.meta.eql(ticket.buffer, self.reservation.buffer) and ticket.cookie == self.reservation.cookie and ticket.byte_length == self.bytes and
            ticket.device_generation == self.reservation.device_generation and ticket.driver_generation == self.reservation.driver_generation and
            ticket.adapter_id == self.adapter and ticket.driver_owner == self.reservation.driver_owner;
    }
    /// A reset destroys the complete RM address space. The common owner still
    /// requires an exact release ticket, and its outstanding leases still veto
    /// issuance. False means a ticket or one of those consumers remains held.
    pub fn closeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence) Error!bool {
        if (!self.aliases.empty()) return false;
        if ((self.self_address != 0 and self.self_address != @intFromPtr(self)) or
            !proof.valid(self.binding.space.epoch) or self.exchange.session.epoch != self.binding.space.epoch or
            !std.meta.eql(self.reservation, self.reservation_stamp) or
            (self.failure != null and self.failure.? == error.Descriptor)) return error.Retained;
        if (self.namespace_live) try self.exchange.session.rm_names.validateChildrenAfterReset(self.names, proof);
        self.closing = true;
        if (self.reference_live) {
            if (!std.meta.eql(self.reference.reference, self.reservation.reference) or
                self.memory.bufferRelease(&self.reference.reference) != a.gfx_buffer_result_ok) return error.Retained;
            self.reference_live = false;
        }
        if (self.common_live) {
            if (self.committed) {
                if (self.release.attempt == 0) return false;
                if (!self.acceptsAfterReset(self.release) or
                    self.memory.bufferFinishRelease(&self.release, 1) != a.gfx_buffer_result_ok) return error.Retained;
            } else if (self.memory.bufferAbort(&self.reservation, 1) != a.gfx_buffer_result_ok) return error.Retained;
            self.common_live = false;
        }
        if (self.namespace_live) try self.exchange.session.rm_names.retireChildrenAfterReset(self.names, proof);
        self.namespace_live = false;
        self.physical = false; self.virtual = false; self.mapped = false;
        self.physical_extent = null; self.state = .finished;
        return true;
    }
    pub fn handoff(self: *Owner) Error!boot.Handoff {
        try self.stable();
        if (self.state != .ready and self.state != .closed) return error.State;
        const token = try self.exchange.handoff(self.deadline);
        self.state = if (self.state == .closed) .finished else .handed_off;
        return token;
    }
    pub fn matches(self: *const Owner, channel: *const exchange.Exchange, deadline: u64) bool {
        self.stable() catch return false;
        const op = self.operation orelse return false;
        return self.self_address == @intFromPtr(self) and channel == &self.exchange and channel.deadline == deadline and self.deadline == deadline and
            channel.function == wire.function(op) and channel.request.ptr == self.request[0..].ptr and channel.request.len == self.request_bytes and
            (self.state == .creating or self.state == .unwinding or self.state == .destroying);
    }
};
fn valid(h: a.GfxBufferHandle) bool { return h.id != 0 and h.generation != 0 and h.reserved0 == 0; }
