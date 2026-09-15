//! Read actual runtime owners without allocating or changing their lifetime.
//! Reservation envelopes, ACKed physical backing and overlapping purpose
//! subsets are distinct. This snapshot grants no eviction or quiescence.
const std = @import("std");
const a = @import("r4os").abi;
pub const Admission = struct {
    epoch: u64 = 0,
    configured: bool = false,
    limit_bytes: u64 = 0,
    progress_bytes: u64 = 0,
    charged_bytes: u64 = 0,
    denials: u64 = 0,

    // This is a conservative admission ceiling, not a free-space query or
    // placement guarantee. The retained union already includes firmware.
    // RM's speculative reserve may overlap it; subtracting it again is an
    // intentional conservative margin, without inventing a reserved address.
    pub fn ceiling(memory: anytype) u64 {
        const region_capacity = @min(memory.region_bytes, @min(memory.physical_bytes, memory.reported_bytes));
        return (region_capacity -| memory.retained_bytes -| memory.speculative_reserved) & ~@as(u64, 65535);
    }
    fn accept(self: *Admission, state: a.GfxDeviceBudgetState, adapter: u32, epoch: u64) !void {
        if (state.version != 1 or state.size < @sizeOf(a.GfxDeviceBudgetState) or state.adapter_id != adapter or
            state.memory_generation != epoch or state.flags & ~a.gfx_memory_budget_closing != 0 or state.limit_bytes % 4096 != 0) return error.Descriptor;
        if (state.flags & a.gfx_memory_budget_closing != 0) return error.Closed;
        self.limit_bytes = state.limit_bytes;
        self.charged_bytes = state.charged_bytes;
    }
    pub fn admit(self: *Admission, run: anytype, bytes: u64, critical: bool) !void {
        const observed = run.nativeMemory() orelse return error.State;
        if (observed.epoch != run.epoch or bytes == 0 or bytes % 65536 != 0) return error.Descriptor;
        const memory = run.ctx.?.memory() orelse return error.Api;
        var state: a.GfxDeviceBudgetState = .{};
        if (self.epoch == 0) {
            const limit = ceiling(observed);
            const result = memory.memoryBudget(&.{ .adapter_id = run.adapter_id, .memory_generation = run.epoch,
                .operation = a.gfx_memory_budget_configure, .limit_bytes = limit }, &state);
            if (result != a.gfx_buffer_result_ok and result != a.err_no_fn) return error.Api;
            if (result == a.gfx_buffer_result_ok) {
                if (state.limit_bytes != limit) return error.Descriptor;
                try self.accept(state, run.adapter_id, run.epoch);
                self.configured = true;
            } else self.limit_bytes = limit; // Old providers retain their common shared budget as well.
            self.progress_bytes = @min(64 * 1024 * 1024, limit / 8) & ~@as(u64, 65535);
            self.epoch = run.epoch;
        } else {
            if (self.epoch != run.epoch) return error.Stale;
            if (self.configured) {
                if (memory.memoryBudget(&.{ .adapter_id = run.adapter_id, .memory_generation = run.epoch }, &state) != a.gfx_buffer_result_ok) return error.Api;
                try self.accept(state, run.adapter_id, run.epoch);
            }
        }
        const held = try read(run);
        self.charged_bytes = if (self.configured) @max(self.charged_bytes, held.native_reserved_bytes) else held.native_reserved_bytes;
        const available = if (critical) self.limit_bytes else self.limit_bytes -| self.progress_bytes;
        if (self.charged_bytes > available or bytes > available - self.charged_bytes) {
            self.denials +|= 1;
            return error.Budget;
        }
    }
};
pub const Snapshot = struct {
    epoch: u64 = 0,
    firmware_capture_known: bool = false,
    stopped: bool = false,
    physical_bytes: u64 = 0,
    firmware_reserved_bytes: u64 = 0,
    boot_retained_bytes: u64 = 0,
    rm_reserved_hint_bytes: u64 = 0,
    native_slots: usize = 0,
    native_reserved_bytes: u64 = 0,
    native_physical_bytes: u64 = 0,
    native_mapped_bytes: u64 = 0,
    native_retiring_bytes: u64 = 0,
    native_uncertain_bytes: u64 = 0,
    control_reserved_bytes: u64 = 0,
    scanout_reserved_bytes: u64 = 0,
    mapping_slots: usize = 0,
    mapping_reserved_bytes: u64 = 0,
    mapping_cache_bytes: u64 = 0,
    mapping_evicting_bytes: u64 = 0,
    render_cache_bytes: u64 = 0,
    mapping_evictions: u64 = 0,
};
fn add(target: *u64, bytes: u64) !void { target.* = try std.math.add(u64, target.*, bytes); }
pub fn read(run: anytype) !Snapshot {
    if (run.self_address == 0 or run.self_address != @intFromPtr(run) or run.epoch == 0) return error.Stale;
    var result: Snapshot = .{ .epoch = run.epoch, .stopped = run.failure != null, .mapping_evictions = run.mapping_evictions };
    // An invalidated or partially captured firmware view is unknown, never an
    // empty available budget. Retained allocation owners remain inspectable.
    if (run.memory_inventory.snapshot()) |memory| {
        if (memory.epoch != run.epoch) return error.Stale;
        const lease = run.memory_inventory.lease orelse return error.Stale;
        const plan = if (lease.plan) |*value| value else return error.Stale;
        result.firmware_capture_known = true;
        result.physical_bytes = @min(memory.physical_bytes, memory.reported_bytes);
        result.firmware_reserved_bytes = plan.reserved.bytes;
        result.boot_retained_bytes = memory.retained_bytes;
        result.rm_reserved_hint_bytes = memory.speculative_reserved;
    }
    for (&run.native_buffers) |slot| if (slot.owner) |owner| {
        if (slot.allocation.handle == 0 or slot.serial == 0 or owner.binding.space.epoch != run.epoch or
            (owner.self_address != 0 and owner.self_address != @intFromPtr(owner))) return error.Stale;
        result.native_slots += 1;
        // The host reservation is retained until the Runtime frees this exact
        // slot, including unacknowledged allocation and failed cleanup.
        try add(&result.native_reserved_bytes, owner.bytes);
        if (owner.physical) try add(&result.native_physical_bytes, owner.bytes);
        if (owner.mapped) {
            if (!owner.physical) return error.Stale;
            try add(&result.native_mapped_bytes, owner.bytes);
        }
        if (owner.closing or owner.state == .unwinding or owner.state == .destroying or owner.state == .closed)
            try add(&result.native_retiring_bytes, owner.bytes);
        if (run.failure != null or owner.failure != null or owner.state == .failed)
            try add(&result.native_uncertain_bytes, owner.bytes);
        if (owner.storage_policy) |policy| switch (policy.role) {
            .control => try add(&result.control_reserved_bytes, owner.bytes),
            .scanout => try add(&result.scanout_reserved_bytes, owner.bytes),
        };
    };
    for (&run.buffers) |slot| if (slot.owner) |owner| {
        if (slot.allocation.handle == 0 or slot.serial == 0 or owner.space.epoch != run.epoch or
            (owner.self_address != 0 and owner.self_address != @intFromPtr(owner))) return error.Stale;
        result.mapping_slots += 1;
        // Address-space mapping envelopes are not additional physical RAM.
        // The common BO owner reports unique backing and lifetime pins.
        try add(&result.mapping_reserved_bytes, owner.mapped_bytes);
        if (slot.cacheable and owner.source.flags == a.gfx_buffer_reference_mapping_only)
            try add(&result.mapping_cache_bytes, owner.mapped_bytes);
        if (slot.evicting) try add(&result.mapping_evicting_bytes, owner.mapped_bytes);
    };
    result.render_cache_bytes = run.graphics_cache.reservedBytes();
    return result;
}
