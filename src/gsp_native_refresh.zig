//! VRR policy and shared intent bridge in the existing Device worker. The
//! Runtime owns commands, DMA completion and real frame-clock observations.
const std = @import("std");
const a = @import("r4os").abi;
const control = @import("gsp_vrr_control.zig");
const vrr = control.edid.vrr;
const Entry = struct {
    published: ?a.GfxOutputRefresh = null,
    intent: a.GfxRefreshRequest = .{},
    consumed_sequence: u64 = 0,
    read_after_ns: u64 = 0,
    publish_failed: bool = false,
};
const Action = struct { window: u32, enabled: bool, deadline: u64 = 0, sequence: u64 = 0 };
pub const Owner = struct {
    entries: [8]Entry = @splat(.{}),
    pending: ?Action = null,

    pub fn busy(self: *const Owner) bool { return self.pending != null; }
    pub fn step(self: *Owner, product: anytype) !bool {
        const outputs = product.outputs orelse return false;
        if (!outputs.supportsRefresh() or !product.callback_confirmed or product.mode == null) return false;
        const run = product.running.?;
        const now = product.last_clock;
        if (self.pending) |work| if (work.sequence != 0) {
            if (run.display_work != null) {
                const entry = &self.entries[work.window];
                if (entry.published) |old| {
                    var value = old;
                    const pacing = &run.refresh_clocks[work.window];
                    value.status.phase = @intFromEnum(pacing.scheduler.state);
                    value.status.since_ns = pacing.since_ns;
                    if (!std.meta.eql(old.status, value.status) and value.status.sequence != std.math.maxInt(u64)) {
                        value.status.sequence += 1;
                        if (outputs.publishRefresh(&value) == a.gfx_output_ok) entry.published = value;
                    }
                }
                return false;
            }
            const result = run.refresh_results[work.window] orelse return error.Completion;
            if (result.sequence != work.sequence or (result.enabled != work.enabled and (result.failure == null or result.enabled))) return error.Completion;
            self.pending = null;
            run.refresh_quiescing = false;
            return true;
        };
        const cursor_core = if (product.cursor.job) |job| job.request.operation != a.display_cursor_operation_move else false;
        const transition = product.modes.pending() or cursor_core or product.additional.hardwareBusy() or
            product.hotplug.phase != .online or product.hotplug.refreshing or run.mode_control_active or
            run.outputs.invalidated or run.receiver_events.pending or run.receiver_events.capturing;
        var head_count: u32 = 0;
        for (&run.display_images) |*image| if (image.* != null and image.*.?.boot_mode != null) { head_count += 1; };
        var selected: ?Action = null;
        for (&self.entries, 0..) |*entry, window| {
            const target = run.presentation_targets[window] orelse continue;
            const image = run.display_images[window] orelse continue;
            const mode = image.boot_mode orelse continue;
            const pacing = &run.refresh_clocks[window];
            if (entry.published) |old| {
                if (!std.meta.eql(old.target, target)) entry.* = .{};
            }
            const fresh = run.adaptiveRefreshPlan(@intCast(window)) catch null;
            const active = if (run.refresh_results[window]) |result| result.enabled else false;
            if (now >= entry.read_after_ns) {
                var request: a.GfxRefreshRequest = .{};
                const status = outputs.readRefresh(&target, &request);
                if (status == a.gfx_output_ok and validIntent(request, target)) entry.intent = request
                else entry.intent = .{ .target = target };
                entry.read_after_ns = now +| 5 * std.time.ns_per_ms;
            }
            var intent = entry.intent;
            if (intent.deadline_ns == 0 or now >= intent.deadline_ns) {
                intent.policy = 0; intent.scene = 0; intent.operation = 0;
            }
            if (intent.sequence != 0 and intent.sequence != entry.consumed_sequence) {
                if (intent.operation == a.gfx_refresh_operation_flicker) pacing.fault(.user_flicker);
                if (intent.operation == a.gfx_refresh_operation_clear_fault) {
                    pacing.clearFault() catch |err| {
                        if (err != error.Busy) return err;
                    };
                    if (pacing.scheduler.fault == .none) entry.consumed_sequence = intent.sequence;
                } else entry.consumed_sequence = intent.sequence;
            }
            const current = run.currentPresentation(@intCast(window));
            const direct = current != null and current.?.direct != null;
            const scene: vrr.Scene = .{
                .policy = @enumFromInt(intent.policy), .fullscreen = intent.scene & a.gfx_refresh_scene_fullscreen != 0,
                .animated = intent.scene & a.gfx_refresh_scene_animated != 0,
                .direct_scanout = direct, .composed = current != null and !direct,
                .output_ready = fresh != null and !run.outputPaused(@intCast(window)) and run.output_faults[window] == null,
                .mode_or_color_pending = transition, .hdr_active = mode.color != null and mode.color.?.transfer != .srgb,
                .hdr_compatible = true, .head_count = head_count,
                // NV570 mixed fixed/VRR heads require additional RM flip
                // traps. Do not advertise independent VRR without that path.
                .independent_heads = false,
                .capture_active = intent.scene & a.gfx_refresh_scene_capture != 0,
                // VRR changes vertical blanking, never the retained pixel
                // clock or the HDA/HDMI N/CTS and DP audio transport clock.
                .audio_clock_independent = true,
            };
            const reason: vrr.Reason = if (pacing.scheduler.fault != .none) pacing.scheduler.fault else
                if (entry.publish_failed) .unavailable else if (run.outputs.invalidated or run.receiver_events.pending) .link_lost else scene.reason();
            pacing.scheduler.reason = reason;
            if (active and reason != .none) selected = .{ .window = @intCast(window), .enabled = false }
            else if (selected == null and !active and fresh != null and reason == .none and pacing.scheduler.state == .fixed)
                selected = .{ .window = @intCast(window), .enabled = true };
            // Retain the admitted facts while an already-active route is
            // being disabled. Receiver invalidation cannot grant new VRR.
            const known: ?control.Plan = if (fresh) |plan| plan else if (active) run.refresh_results[window].?.plan else null;
            var value: a.GfxOutputRefresh = .{ .target = target,
                .capabilities = .{ .flags = a.gfx_refresh_cap_known, .nominal_millihz = if (control.timing(mode)) |timing| timing.millihz() else |_| 0 },
                .status = .{ .sequence = if (entry.published) |old| old.status.sequence else 1,
                    .request_sequence = intent.sequence, .phase = @intFromEnum(pacing.scheduler.state), .reason = @intFromEnum(reason),
                    .policy = intent.policy, .scene = intent.scene, .since_ns = pacing.since_ns } };
            if (known) |plan| {
                const refresh = plan.refresh;
                value.capabilities.flags |= a.gfx_refresh_cap_capable | a.gfx_refresh_cap_hdr;
                value.capabilities.origin = @intFromEnum(refresh.origin);
                value.capabilities.min_millihz = refresh.range.min_millihz; value.capabilities.max_millihz = refresh.range.max_millihz;
                value.capabilities.min_period_ns = refresh.min_period_ns; value.capabilities.max_period_ns = refresh.max_period_ns;
                value.capabilities.max_increase_ns = refresh.max_increase_ns; value.capabilities.max_decrease_ns = refresh.max_decrease_ns;
                value.capabilities.max_vtotal = refresh.max_vtotal;
            }
            if (run.refresh_results[window]) |result| {
                value.status.core_point = result.core_point; value.status.receipt = result.receipt;
            }
            const measured = pacing.observer.summary();
            value.measured = .{ .sequence = pacing.observer.sequence, .observed_ns = pacing.observer.observed_ns,
                .samples = measured.samples, .last_period_ns = measured.last_ns, .min_period_ns = measured.min_ns,
                .max_period_ns = measured.max_ns, .mean_period_ns = measured.mean_ns, .millihz = measured.millihz,
                .gaps = @intCast(@min(std.math.maxInt(u32), pacing.observer.gaps)) };
            if (entry.published) |old| {
                if (!std.meta.eql(value.status, old.status)) {
                    if (value.status.sequence == std.math.maxInt(u64)) return error.Exhausted;
                    value.status.sequence += 1;
                }
                if (std.meta.eql(old, value)) continue;
            }
            const status = outputs.publishRefresh(&value);
            if (status == a.gfx_output_ok) { entry.published = value; entry.publish_failed = false; }
            else if (status != a.gfx_output_error_busy and status != a.gfx_output_error_stale) entry.publish_failed = true;
        }
        const action = selected orelse {
            self.pending = null; run.refresh_quiescing = false; return false;
        };
        if (self.pending == null or self.pending.?.window != action.window or self.pending.?.enabled != action.enabled)
            self.pending = .{ .window = action.window, .enabled = action.enabled, .deadline = now +| 3 * std.time.ns_per_s };
        if (now >= self.pending.?.deadline) return error.Timeout;
        try run.quiesceAdaptiveRefresh();
        const sequence = run.beginAdaptiveRefresh(product.core.?, action.window, action.enabled, self.pending.?.deadline) catch |err| {
            if (err == error.Busy) return false;
            if (action.enabled and (err == error.Unsupported or err == error.Stale or err == error.Incomplete or err == error.Range)) {
                run.refresh_clocks[action.window].fault(.unavailable);
                self.pending = null; run.refresh_quiescing = false; return true;
            }
            return err;
        };
        self.pending.?.sequence = sequence;
        return true;
    }
    pub fn lost(self: *Owner, product: anytype) void {
        const outputs = product.outputs orelse return;
        if (!outputs.supportsRefresh()) return;
        for (&self.entries) |*entry| if (entry.published) |old| {
            var value = old;
            if (value.status.sequence == std.math.maxInt(u64)) continue;
            value.status.sequence += 1; value.status.phase = a.gfx_refresh_phase_lost;
            value.status.reason = a.gfx_refresh_reason_link_lost;
            if (outputs.publishRefresh(&value) == a.gfx_output_ok) entry.published = value;
        };
    }
};
fn validIntent(value: a.GfxRefreshRequest, target: a.GfxOutputTarget) bool {
    return value.version == 1 and value.size >= @sizeOf(a.GfxRefreshRequest) and value.reserved0 == 0 and
        value.operation <= a.gfx_refresh_operation_clear_fault and value.policy <= a.gfx_refresh_policy_windows and
        value.scene & ~@as(u32, 7) == 0 and std.meta.eql(value.target, target);
}
