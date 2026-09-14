//! Device-worker frame admission; only actual Head IRQ observations provide
//! the clock anchor. The retained image repeats through the C67D timeout.
const std = @import("std");
const a = @import("r4os").abi;
const control = @import("gsp_vrr_control.zig");
pub const vrr = control.edid.vrr;
const Sample = @import("gsp_head_events.zig").Sample;
pub const State = struct {
    target: ?a.GfxOutputTarget = null,
    scheduler: vrr.Scheduler = .{},
    observer: vrr.observation.Observer = .{},
    since_ns: u64 = 0,
    outside: u8 = 0,

    pub fn bindTarget(self: *State, target: a.GfxOutputTarget) !bool {
        if (self.target) |old| if (std.meta.eql(old, target)) return false;
        // A reconnect can preserve the display generation. All identity
        // fields participate; an active old link must first be disabled.
        try self.scheduler.configure(target.display_generation, null);
        self.target = target;
        self.observer.reset(target.display_generation);
        self.since_ns = 0;
        self.outside = 0;
        return true;
    }

    pub fn bind(self: *State, generation: u64) !void {
        if (self.scheduler.generation == generation) return;
        try self.scheduler.configure(generation, null);
        self.observer.reset(generation);
        self.since_ns = 0;
        self.outside = 0;
    }
    pub fn begin(self: *State, generation: u64, plan: vrr.Plan, enabled: bool, now: u64) !void {
        try self.bind(generation);
        if (enabled) {
            if (self.scheduler.state != .fixed or self.scheduler.fault != .none) return error.State;
            try self.scheduler.configure(generation, plan);
            self.scheduler.state = .enabling;
        } else {
            if (self.scheduler.state != .active and self.scheduler.state != .disabling) return error.State;
            if (!std.meta.eql(self.scheduler.plan, @as(?vrr.Plan, plan))) return error.Stale;
            self.scheduler.state = .disabling;
        }
        self.since_ns = now;
    }
    pub fn completed(self: *State, enabled: bool, now: u64) !void {
        try self.scheduler.acknowledged(self.scheduler.generation, enabled);
        self.since_ns = now;
        self.outside = 0;
    }
    pub fn clearFault(self: *State) !void {
        if (self.scheduler.state != .fixed and self.scheduler.state != .faulted) return error.Busy;
        try self.scheduler.configure(self.scheduler.generation, self.scheduler.plan);
        self.outside = 0;
    }
    pub fn fault(self: *State, reason: vrr.Reason) void {
        _ = self.scheduler.fail(reason);
    }
    pub fn observe(self: *State, sample: Sample) void {
        if (sample.sequence == 0 and sample.observed_ns == 0) return;
        const result = self.observer.feed(self.scheduler.generation, sample.sequence, sample.frame_counter, sample.observed_ns);
        if (self.scheduler.state != .active) return;
        if (result == .clock or result == .stale) { self.fault(.stale_clock); return; }
        if (result == .duplicate or sample.observed_ns <= self.since_ns) return;
        if (result == .gap) self.scheduler.previous_period_ns = 0;
        const previous = self.scheduler.observed_ns;
        self.scheduler.observed(self.scheduler.generation, sample.observed_ns) catch { self.fault(.stale_clock); return; };
        if (result == .gap) self.scheduler.previous_period_ns = 0;
        if (previous == 0 or result != .sample) return;
        const plan = self.scheduler.plan orelse { self.fault(.timing_fault); return; };
        const period = sample.observed_ns - previous;
        // IRQ delivery has finite latency. One late sample is not evidence
        // of an invalid link; three consecutive outliers request fixed mode.
        const tolerance = @max(500_000, plan.min_period_ns / 10);
        if (period +| tolerance < plan.min_period_ns or period > plan.max_period_ns +| tolerance) self.outside +|= 1 else self.outside = 0;
        if (self.outside >= 3) self.fault(.timing_fault);
    }
    pub fn allowFrame(self: *State, now: u64) bool {
        if (self.scheduler.state == .fixed or self.scheduler.state == .faulted) return true;
        if (self.scheduler.state != .active) return false;
        const plan = self.scheduler.plan orelse { self.fault(.timing_fault); return false; };
        if (now < self.since_ns or (self.scheduler.observed_ns == 0 and now - self.since_ns > plan.max_period_ns * 3)) {
            self.fault(.stale_clock); return false;
        }
        if (self.scheduler.observed_ns == 0) return false;
        const frame = self.scheduler.frame(now, now) catch |err| {
            self.fault(if (err == error.Clock) .stale_clock else .timing_fault);
            return false;
        };
        return !frame.repeat and frame.submit_ns <= now;
    }
    pub fn checkClock(self: *State, now: u64) void {
        if (self.scheduler.state != .active) return;
        const plan = self.scheduler.plan orelse return;
        const anchor = if (self.scheduler.observed_ns != 0) self.scheduler.observed_ns else self.since_ns;
        if (now < anchor or now - anchor > plan.max_period_ns * 3) self.fault(.stale_clock);
    }
};
