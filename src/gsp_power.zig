//! Retained RUSD DMA page and finite performance requests for one RM graph.
//! One control exchange at a time; the runtime lends and reclaims its token.
//! Sensor failures are optional. Ambiguous DMA publication never permits free.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const exchange = @import("gsp_exchange.zig");
const boot = @import("gsp_boot_events.zig");
const storage = @import("gsp_control_storage.zig");
pub const wire = @import("gsp_power_wire.zig");
pub const policy = @import("gsp_power_policy.zig");
pub const telemetry = @import("r4nv_telemetry");
pub const Status = enum { unprobed, ready, rejected, host_failure, closed };
pub const sample_period_ns = 200 * std.time.ns_per_ms;
pub const max_age_ns = 3 * std.time.ns_per_s;
pub const demand_ns = 10 * std.time.ns_per_s;
pub const Owner = struct {
    self_address: usize = 0,
    ctx: r4os.r4dev.DriverContext,
    adapter: u32,
    binding: wire.Binding,
    shared_binding: wire.Binding,
    backing: storage.Storage = .{},
    status: Status = .unprobed,
    attached: bool = false,
    possibly_attached: bool = false,
    stopping: bool = false,
    active: ?exchange.Exchange = null,
    operation: ?wire.Operation = null,
    request: [wire.max_bytes]u8 = @splat(0),
    started: bool = false,
    completed: bool = false,
    deadline: u64 = 0,
    rejection: ?u32 = null,
    poll_rejection: ?u32 = null,
    detach_rejection: ?u32 = null,
    last_status: ?u32 = null,
    host_failure: ?anyerror = null,
    active_mask: u64 = 0,
    demanded_mask: u64 = 0,
    demanded_until: u64 = 0,
    work_until: u64 = 0,
    recent_activity: policy.Activity = .{},
    recent_until: u64 = 0,
    next_sample: u64 = 0,
    tracker: telemetry.Tracker = .{},
    next_tracker: ?telemetry.Tracker = null,
    snapshot: telemetry.Snapshot = .{},
    performance: policy.Owner = .{},
    performance_request: ?policy.Request = null,
    controls: u64 = 0,
    reads: u64 = 0,
    common_next: u64 = 0,
    common_status: ?i32 = null,
    timing_until: u64 = 0,
    timer_next: u64 = 0,
    timer_requested_ns: u64 = 0,
    timer: @import("gsp_power_clock.zig").Owner = .{},

    pub fn init(ctx: r4os.r4dev.DriverContext, adapter: u32, binding: wire.Binding, shared_binding: wire.Binding) !Owner {
        var check: [wire.max_bytes]u8 = undefined;
        _ = try wire.encode(binding, .detach, &check);
        _ = try wire.encode(shared_binding, .detach, &check);
        if (adapter == 0 or binding.epoch != shared_binding.epoch) return error.Parameter;
        return .{ .ctx = ctx, .adapter = adapter, .binding = binding, .shared_binding = shared_binding };
    }
    pub fn observeActivity(self: *Owner, now: u64, activity: policy.Activity) void {
        if (activity.copy or activity.render or activity.compute or activity.video or activity.display_commit or activity.cursor) {
            self.work_until = now +| (2 * std.time.ns_per_s);
            self.recent_until = now +| policy.hold_ns;
            self.recent_activity = activity;
        }
    }
    fn controlBinding(self: *const Owner, operation: wire.Operation) wire.Binding {
        return if (operation == .boost or operation == .timer) self.binding else self.shared_binding;
    }
    fn stable(self: *Owner) !void {
        if (self.self_address == 0) self.self_address = @intFromPtr(self);
        if (self.self_address != @intFromPtr(self)) return error.Stale;
    }
    pub fn demand(self: *Owner, now: u64, mask: u64) !void {
        try self.stable();
        if (mask & ~telemetry.poll_mask != 0 or now == 0 or self.stopping) return error.Parameter;
        if (now >= self.demanded_until) self.demanded_mask = 0;
        self.demanded_mask |= mask;
        if (mask != 0) self.demanded_until = now +| demand_ns;
    }
    pub fn publicState(self: *const Owner, now: u64) a.GfxTelemetryState {
        var output: a.GfxTelemetryState = .{ .adapter_id = self.adapter, .memory_generation = self.binding.epoch,
            .sampled_ns = now, .valid_until_ns = now +| max_age_ns, .source = 1, .state = @intFromEnum(self.status),
            .policy = @intFromEnum(self.performance.reason), .boost = if (now < self.performance.accepted_until) self.performance.accepted_level else 0,
            .control_status = self.last_status orelse 0 };
        for (telemetry.fields, 0..) |field, i| {
            const reading = self.snapshot.get(field);
            const metric = &output.metrics[i];
            metric.status = @intFromEnum(reading.status);
            metric.source_stamp = reading.sequence;
            if (!reading.usable()) continue;
            const changed = self.tracker.entries[i].changed_host_ns orelse { metric.status = a.gfx_telemetry_unavailable; continue; };
            const end = changed +| max_age_ns;
            if (now < changed or now >= end) { metric.status = a.gfx_telemetry_stale; continue; }
            // Conservative cache expiry: no published group can outlive the
            // earliest still-fresh source update if Driver Work stops running.
            output.valid_until_ns = @min(output.valid_until_ns, end);
            switch (field) {
                .clocks => {
                    const hz = reading.targetClocksHz().?;
                    for (&metric.values, hz) |*value, frequency| value.* = @intCast(frequency);
                },
                .pstate => metric.values[0] = reading.pstateIndex() orelse { metric.status = a.gfx_telemetry_malformed; continue; },
                .gpu_temperature, .memory_temperature => metric.values[0] = reading.temperatureMilliCelsius().?,
                else => {
                    const count: usize = switch (field) { .throttle => 1, .utilization, .power_limit => 2, .average_power, .instantaneous_power => 3, else => unreachable };
                    for (metric.values[0..count], reading.words[0..count]) |*value, raw| value.* = raw;
                },
            }
        }
        output.metrics[9] = self.timer.snapshot(now, max_age_ns);
        if (output.metrics[9].status == a.gfx_telemetry_fresh) output.valid_until_ns = @min(output.valid_until_ns, self.timer.received_ns +| max_age_ns);
        return output;
    }
    pub fn exchangeCommon(self: *Owner, now: u64) !void {
        try self.stable();
        if (now < self.common_next) return;
        self.common_next = now +| sample_period_ns;
        const memory = self.ctx.memory() orelse return;
        const state = self.publicState(now);
        var wanted: a.GfxTelemetryDemand = .{};
        const rc = memory.telemetryExchange(&state, &wanted);
        self.common_status = rc;
        if (rc != a.gfx_buffer_result_ok) return;
        const clock = self.ctx.resources() orelse return error.Api;
        const received_at = clock.nowNs();
        if (wanted.version != 1 or wanted.size < @sizeOf(a.GfxTelemetryDemand) or wanted.reserved0 != 0 or
            wanted.adapter_id != self.adapter or wanted.memory_generation != self.binding.epoch or
            received_at < now or received_at == std.math.maxInt(u64) or
            wanted.metric_mask & ~a.gfx_telemetry_metric_mask != 0 or wanted.until_ns > received_at +| demand_ns) return error.Descriptor;
        var mask: u64 = 0;
        if (!self.stopping and now < wanted.until_ns) for (telemetry.fields, 0..) |field, i| {
            if (wanted.metric_mask & (@as(u64, 1) << @intCast(i)) != 0) mask |= telemetry.spec(field).group;
        };
        self.demanded_mask = mask;
        self.demanded_until = wanted.until_ns;
        self.timing_until = if (wanted.metric_mask & (1 << 9) != 0 and !self.stopping) wanted.until_ns else 0;
    }
    /// No firmware call or DMA access. Publish terminal metadata immediately
    /// so a cached pre-fault temperature/clock cannot remain apparently live.
    pub fn deviceLost(self: *Owner, now: u64) void {
        self.stable() catch return;
        self.stopping = true; self.status = .host_failure;
        self.snapshot = .{}; self.timer = .{};
        self.demanded_mask = 0; self.demanded_until = 0; self.timing_until = 0;
        self.common_next = 0;
        if (now == 0 or now == std.math.maxInt(u64)) return;
        const memory = self.ctx.memory() orelse return;
        var state: a.GfxTelemetryState = .{ .adapter_id = self.adapter, .memory_generation = self.binding.epoch,
            .sampled_ns = now, .valid_until_ns = now, .source = 1, .state = @intFromEnum(self.status) };
        var ignored: a.GfxTelemetryDemand = .{};
        self.common_status = memory.telemetryExchange(&state, &ignored);
        // Keep any pending control receipt, attached RUSD page and DMA leases.
    }
    pub fn sample(self: *Owner, now: u64) !void {
        try self.stable();
        if (!self.attached or self.active_mask == 0 or now < self.next_sample) return;
        errdefer self.snapshot = .{ .sampled_host_ns = now };
        self.next_sample = now +| sample_period_ns;
        var reader = self.map() catch |err| {
            self.snapshot = .{ .sampled_host_ns = now };
            return err;
        };
        const result = self.tracker.sample(&reader, now, max_age_ns) catch |err| {
            self.snapshot = .{ .sampled_host_ns = now };
            try self.unmap();
            return err;
        };
        try self.unmap();
        self.snapshot = result;
        self.reads +|= 1;
    }
    pub fn choose(self: *Owner, now: u64, activity: policy.Activity) !?wire.Operation {
        try self.stable();
        if (self.active != null) return null;
        if (self.backing.cpu.lease.id != 0) try self.unmap();
        if (activity.stopping) self.stopping = true;
        const workload = activity.copy or activity.render or activity.compute or activity.video or activity.display_commit or activity.cursor;
        if (workload and !self.stopping) self.work_until = now +| (2 * std.time.ns_per_s);
        const requested = if (self.stopping) 0 else
            (if (now < self.demanded_until) self.demanded_mask else @as(u64, 0)) |
            (if (now < self.work_until) telemetry.poll_mask else @as(u64, 0));
        if (!self.attached and self.status == .unprobed and requested != 0) {
            self.backing.prepare(&self.ctx, self.adapter, self.binding.epoch, storage.shared_page_bytes) catch |err| {
                self.host_failure = err;
                self.status = .host_failure;
                _ = self.backing.close();
                return null;
            };
            return .{ .attach = self.backing.pages[0] };
        }
        if (self.attached and requested != self.active_mask and self.poll_rejection == null)
            return .{ .poll = .{ .mask = requested, .interval_ms = 1000 } };
        const throttle = self.snapshot.get(.throttle);
        const fresh = throttle.usable() and now >= self.snapshot.sampled_host_ns and now - self.snapshot.sampled_host_ns <= max_age_ns;
        var controlled_activity = activity;
        if (!workload and now < self.recent_until) controlled_activity = self.recent_activity;
        controlled_activity.stopping = self.stopping;
        const wanted = try self.performance.next(now, controlled_activity, .{ .throttle_mask = if (fresh) throttle.words[0] else null });
        if (wanted) |request| {
            self.performance_request = request;
            return .{ .boost = .{ .level = request.level, .seconds = request.seconds } };
        }
        if (self.stopping and self.attached and self.detach_rejection == null) return .detach;
        if (self.stopping and !self.possibly_attached and self.backing.close()) self.status = .closed;
        if (!self.stopping and self.timer.rejected == null and !self.timer.faulted and now < self.timing_until and now >= self.timer_next) return .timer;
        return null;
    }
    pub fn begin(self: *Owner, token: *boot.Handoff, operation: wire.Operation, now: u64, deadline: u64) !void {
        try self.stable();
        if (self.active != null or token.session.epoch != self.binding.epoch or deadline <= now) return error.State;
        const encoded = try wire.encode(self.controlBinding(operation), operation, &self.request);
        switch (operation) {
            .attach => |address| if (self.status != .unprobed or self.possibly_attached or !self.backing.valid() or self.backing.pages[0] != address) return error.Binding,
            .detach => if (!self.stopping or !self.attached or !self.possibly_attached) return error.State,
            .poll => |value| {
                if (!self.attached or !self.possibly_attached) return error.State;
                // Baseline before enabling the poll; pre-existing values must
                // not acquire a new apparent age when the client returns.
                var reader = try self.map();
                var next = self.tracker;
                next.begin(&reader, value.mask, now) catch |err| {
                    try self.unmap();
                    return err;
                };
                try self.unmap();
                self.next_tracker = next;
            },
            .boost => |value| {
                const request = self.performance_request orelse return error.State;
                if (self.performance.pending == null or !std.meta.eql(request, self.performance.pending.?) or
                    request.level != value.level or request.seconds != value.seconds) return error.Binding;
            },
            .timer => {
                if (self.stopping or now >= self.timing_until or self.timer.rejected != null) return error.State;
                self.timer_requested_ns = now;
                self.timer_next = now +| std.time.ns_per_s;
            },
        }
        self.active = try exchange.Exchange.init(token, deadline);
        self.operation = operation;
        self.deadline = deadline;
        self.started = false;
        self.completed = false;
        self.last_status = null;
        // No later method is allowed to recreate a different request.
        if (encoded.ptr != self.request[0..].ptr) return error.Binding;
    }
    pub fn poll(self: *Owner, now: u64) !?exchange.Dispatch {
        try self.stable();
        const current = if (self.active) |*value| value else return error.State;
        const operation = self.operation orelse return error.State;
        if (self.completed) return null;
        if (!self.started) {
            if (operation == .attach) {
                // Publication can be ambiguous. Only a matched rejection or
                // an acknowledged detach may release this physical page.
                self.possibly_attached = true;
                self.backing.retained = true;
            }
            try current.begin(wire.function, self.request[0..wire.size(operation)], self.deadline);
            self.started = true;
        }
        const dispatch = (try current.poll(self.deadline)) orelse return null;
        if (!dispatch.response) return dispatch;
        const reply = try wire.decode(self.controlBinding(operation), operation, dispatch.record);
        const status: u32 = if (reply == .rejected) reply.rejected else 0;
        try current.complete(dispatch.ticket);
        self.last_status = status;
        self.controls +|= 1;
        switch (operation) {
            .attach => {
                if (status == 0) { self.attached = true; self.status = .ready; } else {
                    self.rejection = status; self.status = .rejected;
                    self.possibly_attached = false; self.backing.retained = false;
                    _ = self.backing.close();
                }
            },
            .detach => {
                if (status == 0) {
                    self.attached = false; self.possibly_attached = false;
                    self.active_mask = 0; self.snapshot = .{}; self.tracker = .{};
                    self.backing.retained = false;
                    if (self.backing.close()) self.status = .closed;
                } else self.detach_rejection = status;
            },
            .poll => |value| {
                if (status == 0) {
                    self.active_mask = value.mask;
                    self.tracker = self.next_tracker orelse return error.State;
                    self.next_sample = now;
                    self.snapshot = .{};
                } else self.poll_rejection = status;
                self.next_tracker = null;
            },
            .boost => {
                try self.performance.complete(self.performance_request orelse return error.State, status, now);
                self.performance_request = null;
            },
            .timer => {
                if (status == 0) self.timer.accept(reply.timer, self.timer_requested_ns, now) else {
                    self.timer.rejected = status; self.timer.metric = .{};
                }
            },
        }
        self.completed = true;
        return null;
    }
    pub fn handoff(self: *Owner, deadline: u64) !boot.Handoff {
        try self.stable();
        if (!self.completed or self.active == null) return error.State;
        const token = try self.active.?.handoff(deadline);
        self.active = null; self.operation = null; self.completed = false; self.started = false;
        return token;
    }
    pub fn matches(self: *Owner, current: *const exchange.Exchange, deadline: u64) bool {
        if (self.self_address != @intFromPtr(self) or self.active == null or current != &self.active.? or !self.started or self.completed or
            current.phase != .prepared or current.pending != null or current.session.epoch != self.binding.epoch or
            current.deadline != deadline or self.deadline != deadline or current.function != wire.function or current.request.ptr != self.request[0..].ptr) return false;
        const operation = self.operation orelse return false;
        if (operation == .attach or operation == .detach or operation == .poll) {
            if (!self.backing.valid() or !self.possibly_attached or !self.backing.retained) return false;
        }
        var expected: [wire.max_bytes]u8 = undefined;
        const encoded = wire.encode(self.controlBinding(operation), operation, &expected) catch return false;
        return std.mem.eql(u8, encoded, current.request);
    }
    pub fn closed(self: *const Owner) bool {
        return self.status == .closed and self.active == null and !self.possibly_attached and self.backing.self_address == 0;
    }
    pub fn stop(self: *Owner, now: u64) !bool {
        try self.stable();
        self.stopping = true;
        // An unused telemetry owner has no firmware lifetime to drain. A
        // still-live boost must be cleared by the ordinary serialized path.
        if (self.active == null and !self.possibly_attached and self.performance.pending == null and
            (self.performance.accepted_level == 0 or now >= self.performance.accepted_until) and self.backing.close()) self.status = .closed;
        return self.closed();
    }
    fn map(self: *Owner) !Reader {
        if (!self.backing.valid()) return error.State;
        const memory = self.backing.memory orelse return error.Api;
        if (memory.bufferMap(&self.backing.reference.reference, a.gfx_buffer_map_read, 0, telemetry.page_bytes, &self.backing.cpu) != a.gfx_buffer_result_ok) return error.Map;
        errdefer self.unmap() catch {};
        const mapped = self.backing.cpu;
        if (mapped.version != 1 or mapped.size < @sizeOf(a.GfxBufferMap) or mapped.lease.id == 0 or mapped.lease.generation == 0 or
            mapped.byte_length != telemetry.page_bytes or mapped.cpu_address == 0 or mapped.cpu_address & 4095 != 0 or
            mapped.cpu_address > std.math.maxInt(u64) - telemetry.page_bytes or mapped.lease.reserved0 != 0 or mapped.reserved0 != 0 or
            mapped.cache_policy != a.gfx_buffer_cache_write_back) return error.Descriptor;
        return .{ .bytes = @ptrFromInt(mapped.cpu_address) };
    }
    fn unmap(self: *Owner) !void {
        if (self.backing.cpu.lease.id == 0) return;
        const memory = self.backing.memory orelse return error.Api;
        if (memory.bufferUnmap(&self.backing.cpu.lease) != a.gfx_buffer_result_ok) return error.Synchronization;
        self.backing.cpu = .{};
    }
};
const Reader = struct {
    bytes: [*]const volatile u8,
    pub fn load64(self: *const Reader, offset: usize) !u64 {
        if (offset & 7 != 0 or offset > telemetry.shared_bytes - 8) return error.Bounds;
        const pointer: *const volatile u64 = @ptrCast(@alignCast(self.bytes + offset));
        return pointer.*;
    }
    pub fn load32(self: *const Reader, offset: usize) !u32 {
        if (offset & 3 != 0 or offset > telemetry.shared_bytes - 4) return error.Bounds;
        const pointer: *const volatile u32 = @ptrCast(@alignCast(self.bytes + offset));
        return pointer.*;
    }
    pub fn barrier(_: *const Reader) !void {
        asm volatile ("lfence" ::: .{ .memory = true });
    }
};
