//! Native RM backing for common BOs. The initial GPU mapping belongs to the
//! backing itself; no permanent common lease can deadlock its last-use release.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const boot = @import("gsp_boot_events.zig");
const exchange = @import("gsp_exchange.zig");
const names = @import("gsp_rm_names.zig");
const vaspace = @import("gsp_vaspace.zig");
const host_vm = @import("gsp_host_vm.zig");
const user_vram = @import("gsp_user_vram.zig");
const clear = @import("gsp_memory_clear.zig");
pub const wire = @import("gsp_vram_wire.zig");
pub const surface = @import("gsp_surface_layout.zig");
pub const storage = @import("gsp_native_backing.zig");
pub const alias = @import("gsp_memory_alias.zig");
pub const Error = wire.Error || names.Error || surface.Error || storage.Error || host_vm.Error || user_vram.Error || error{ Api, Descriptor, Memory, Busy, Retained };
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
    cleared: bool = false,
    clear_active: bool = false,
    clear_request: [clear.bytes]u8 = undefined,
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
    host_range: host_vm.Range = .{},
    host_binding: host_vm.Binding = .{},
    host_active: bool = false,
    host_physical: ?u64 = null,
    user_memory: ?struct { heap: *user_vram.Owner, view: *const @import("gsp_memory_inventory.zig").Owner } = null,
    user_range: user_vram.Range = .{},

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
        return initResident(token, ctx, adapter, space, parent, plan, policy, deadline, null);
    }
    pub fn initResident(token: *boot.Handoff, ctx: *const r4os.r4dev.DriverContext, adapter: u32, space: vaspace.Info,
        parent: names.Lease, plan: surface.Plan, policy: ?storage.Policy, deadline: u64, resident: ?*names.ResidentChildren) Error!Owner
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
        const children = if (resident) |node| try token.session.rm_names.reserveResidentChildren(parent, 2, node)
            else try token.session.rm_names.reserveChildren(parent, 2);
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
        try self.retainAliasReference(use, value.reference, offset, bytes);
    }
    /// A broker-retained full reference may survive the allocation producer's
    /// initial close. Authenticate it through a new common import before RM
    /// work; the supplied object identity alone cannot authorize a mapping.
    pub fn retainAliasReference(self: *Owner, use: *alias.Use, reference: a.GfxBufferReference, offset: u64, bytes: u64) Error!void {
        try self.stable();
        if (self.self_address != @intFromPtr(self) or !self.committed or !self.common_live or !self.mapped or
            self.failure != null or self.exchange.session.state != .active or
            (self.state != .ready and self.state != .handed_off)) return error.State;
        if (reference.version != 1 or reference.size < @sizeOf(a.GfxBufferReference) or reference.reserved0 != 0 or
            !valid(reference.reference) or !std.meta.eql(reference.buffer, self.reservation.buffer)) return error.Stale;
        if (reference.flags != 0) return error.Unsupported;
        if (self.storage_policy != null or self.layout.privileged or self.layout.readonly) return error.Unsupported;
        if (bytes == 0 or (offset | bytes) & 4095 != 0 or bytes > self.logical_bytes or offset > self.logical_bytes - bytes) return error.Bounds;
        var host_source = self.hostSource();
        host_source.offset = offset;
        host_source.bytes = bytes;
        try self.aliases.acquire(use, .{ .space = self.binding.space, .object = self.binding.memory,
            .allocation_bytes = self.bytes, .offset = offset, .bytes = bytes, .location = .video,
            .host = if (self.binding.space.host != null) host_source else null });
        use.retainReference(self.memory, reference.reference, self.reservation.buffer) catch |err| {
            if (err != error.Descriptor and err != error.Retained) { try use.close(true); return err; }
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
        if (self.clear_active) return self.advanceClear();
        if (self.operation == null) {
            if (self.state == .creating and !self.common_live) { try self.reserve(); return null; }
            const op: wire.Operation = if (self.state == .creating) blk: {
                if (!self.physical) break :blk .allocate_memory;
                if (!self.cleared) {
                    const policy = self.storage_policy orelse return error.State;
                    const target = policy.clear orelse return error.Unsupported;
                    const physical = self.physical_extent orelse return error.State;
                    const data = try clear.encode(target, physical.base, self.bytes, &self.clear_request);
                    try self.exchange.begin(clear.function, data, self.deadline);
                    self.clear_active = true; self.last_status = null;
                    return self.advanceClear();
                }
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
            if (self.user_memory != null and (op == .allocate_memory or op == .free_memory)) {
                if (try self.exchange.poll(self.deadline)) |dispatch| return dispatch;
                if (self.exchange.in_lockdown) return null;
                try self.advanceUserPhysical(op);
                return null;
            }
            if (self.binding.space.host) |host| if (op != .allocate_memory and op != .free_memory) {
                if (try self.exchange.poll(self.deadline)) |dispatch| return dispatch;
                if (self.exchange.in_lockdown) return null;
                try self.advanceHost(host, op);
                return null;
            };
            const encoded = try wire.encodeLayout(self.binding, self.bytes, .{ .blocklinear = self.layout.blocklinear(), .scanout = self.layout.scanout(),
                .contiguous = self.storage_policy != null or self.binding.space.host != null, .granule = self.layout.descriptor.alignment,
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
                self.cleared = if (self.storage_policy) |policy| policy.capabilities.vidmemCleared() else true;
                if (self.binding.space.host != null) {
                    // The original allocation request and strict decoder
                    // require PHYSICALITY_CONTIGUOUS for this host walk.
                    // Never infer a complete extent from a discontiguous RM
                    // allocation's first returned physical page.
                    if (reply.ok >= host_vm.page.video_limit or self.bytes > host_vm.page.video_limit - reply.ok) return error.Bounds;
                    self.host_physical = reply.ok;
                }
                if (self.storage_policy != null) self.physical_extent = .{ .base = reply.ok, .bytes = self.bytes };
            },
            .allocate_virtual => { self.virtual = true; self.address = reply.ok; },
            .map => self.mapped = true,
            .unmap => self.mapped = false,
            .free_virtual => { self.virtual = false; self.address = 0; },
            .free_memory => { self.physical = false; self.cleared = false; self.physical_extent = null; self.host_physical = null; },
        }
        self.operation = null;
        return null;
    }
    fn advanceClear(self: *Owner) Error!?exchange.Dispatch {
        const dispatch = (try self.exchange.poll(self.deadline)) orelse return null;
        if (!dispatch.response) return dispatch;
        const target = self.storage_policy.?.clear.?;
        const reply = try clear.decode(target, self.physical_extent.?.base, self.bytes, &self.clear_request, dispatch.record);
        self.last_status = if (reply == .rejected) reply.rejected else 0;
        try self.exchange.complete(dispatch.ticket);
        // A timeout/rejection may leave a partial or uncertain firmware
        // write. Keep the private extent until independent reset quiescence.
        if (reply == .rejected) { self.rejected = reply.rejected; return error.FirmwareResult; }
        self.cleared = true; self.clear_active = false;
        return null;
    }
    fn advanceUserPhysical(self: *Owner, op: wire.Operation) Error!void {
        const user = self.user_memory orelse return error.State;
        if (self.binding.space.host == null or self.storage_policy != null or self.mapped or self.virtual or self.host_active or
            !self.aliases.empty()) return error.State;
        switch (op) {
            .allocate_memory => {
                const base = user.heap.reserve(user.view, self.binding.space.epoch, &self.user_range, self.bytes, self.layout.descriptor.alignment) catch |err| {
                    if (err != error.Memory) return err;
                    self.host_rejected = a.gfx_buffer_error_oom;
                    self.state = .unwinding;
                    return;
                };
                self.host_physical = base; self.physical = true; self.cleared = true;
            },
            .free_memory => {
                // The exact common release ticket excludes users; host VA
                // teardown above already acknowledged every PTE/TLB removal.
                try user.heap.release(&self.user_range, true);
                self.host_physical = null; self.physical = false; self.cleared = false;
            },
            else => return error.State,
        }
        self.last_status = 0;
    }
    fn hostSource(self: *const Owner) host_vm.Source {
        return .{ .context = self, .valid = hostValid, .physical = hostPhysical, .bytes = self.bytes,
            .policy = .{ .aperture = .video, .kind = if (self.layout.blocklinear()) 6 else 0, .cached = true,
                .read_only = self.layout.readonly, .privileged = self.layout.privileged, .atomic = true } };
    }
    fn hostValid(raw: *const anyopaque, epoch: u64) bool {
        const self: *const Owner = @ptrCast(@alignCast(raw));
        self.stable() catch return false;
        if (self.user_memory) |user| if (!user.heap.owns(&self.user_range) or
            self.host_physical != self.user_range.span.base or self.bytes != self.user_range.span.bytes) return false;
        return self.self_address == @intFromPtr(self) and self.binding.space.epoch == epoch and self.physical and self.host_physical != null;
    }
    fn hostPhysical(raw: *const anyopaque, offset: u64) host_vm.Error!u64 {
        const self: *const Owner = @ptrCast(@alignCast(raw));
        if (!hostValid(raw, self.binding.space.epoch)) return error.Stale;
        if (offset >= self.bytes or offset & 4095 != 0) return error.Bounds;
        return self.host_physical.? + offset;
    }
    fn advanceHost(self: *Owner, host: *host_vm.Owner, op: wire.Operation) Error!void {
        self.last_status = null;
        switch (op) {
            .allocate_virtual => {
                self.address = try host.reserve(&self.host_range, self.bytes, self.layout.descriptor.alignment, 0);
                self.virtual = true;
            },
            .map => {
                if (!self.host_active) {
                    try host.beginMap(&self.host_range, &self.host_binding, 0, self.hostSource(), self.deadline);
                    self.host_active = true;
                    return;
                }
                if (!try host.poll(&self.host_binding)) return;
                self.host_active = false;
                self.mapped = true;
            },
            .unmap => {
                if (!self.host_active) {
                    if (!self.aliases.empty()) return error.Busy;
                    // A common last-use release ticket or unpublished unwind
                    // already excludes every executing consumer here.
                    try host.beginUnmap(&self.host_binding, self.deadline, true);
                    self.host_active = true;
                    return;
                }
                if (!try host.poll(&self.host_binding)) return;
                self.host_active = false;
                self.mapped = false;
            },
            .free_virtual => {
                try host.releaseRange(&self.host_range);
                self.virtual = false;
                self.address = 0;
            },
            .allocate_memory, .free_memory => return error.State,
        }
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
        // Confirmed loss may make reference-only BOs reclaimable before
        // their RM aliases are removed. Close the initial logical reference
        // now, but retain this owner and any exact ticket until those aliases
        // have independently consumed the same quiescence proof.
        if (!self.aliases.empty()) return false;
        if (self.common_live) {
            if (self.committed) {
                if (self.release.attempt == 0) return false;
                if (!self.acceptsAfterReset(self.release) or
                    self.memory.bufferFinishRelease(&self.release, 1) != a.gfx_buffer_result_ok) return error.Retained;
            } else if (self.memory.bufferAbort(&self.reservation, 1) != a.gfx_buffer_result_ok) return error.Retained;
            self.common_live = false;
        }
        if (self.user_range.owner) |heap| try heap.release(&self.user_range, true);
        if (self.namespace_live) try self.exchange.session.rm_names.retireChildrenAfterReset(self.names, proof);
        self.namespace_live = false;
        self.physical = false; self.virtual = false; self.mapped = false;
        self.physical_extent = null; self.host_physical = null; self.state = .finished;
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
        if (self.clear_active) {
            const policy = self.storage_policy orelse return false;
            const target = policy.clear orelse return false;
            const physical = self.physical_extent orelse return false;
            return self.self_address == @intFromPtr(self) and channel == &self.exchange and channel.deadline == deadline and self.deadline == deadline and
                self.state == .creating and self.physical and !self.cleared and !self.virtual and !self.mapped and self.operation == null and
                target.epoch == self.binding.space.epoch and physical.bytes == self.bytes and channel.function == clear.function and
                channel.request.ptr == self.clear_request[0..].ptr and clear.matches(target, physical.base, self.bytes, channel.request);
        }
        const op = self.operation orelse return false;
        return self.self_address == @intFromPtr(self) and channel == &self.exchange and channel.deadline == deadline and self.deadline == deadline and
            channel.function == wire.function(op) and channel.request.ptr == self.request[0..].ptr and channel.request.len == self.request_bytes and
            (self.state == .creating or self.state == .unwinding or self.state == .destroying);
    }
};
fn valid(h: a.GfxBufferHandle) bool { return h.id != 0 and h.generation != 0 and h.reserved0 == 0; }
