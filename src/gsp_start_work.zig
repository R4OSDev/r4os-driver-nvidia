//! A dedicated pacing task owns waits; short serialized DriverWork callbacks
//! alone mutate the native device. Exactly one outstanding work completion.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const device = @import("gsp_device.zig");
pub const Work = struct {
    self_address: usize = 0,
    ctx: ?r4os.r4dev.DriverContext = null,
    threads: ?r4os.r4dev.DriverThreadContext = null,
    semaphores: ?r4os.r4dev.DriverSemaphoreContext = null,
    wake_semaphore: u64 = 0,
    device: ?*device.Device = null,
    task: u64 = 0,
    completion: u32 = 0,
    stopping: u32 = 0,

    pub fn start(self: *Work, ctx: *const r4os.r4dev.DriverContext, target: *device.Device) !void {
        if (self.self_address != 0 or target.self_address != @intFromPtr(target)) return error.State;
        if (ctx.apiVersion() < a.driver_api_thread_work_version) return error.Api;
        const service = ctx.threads() orelse return error.Api;
        const semaphores = ctx.semaphores() orelse return error.Api;
        self.self_address = @intFromPtr(self);
        self.ctx = ctx.*;
        self.threads = service;
        self.semaphores = semaphores;
        self.device = target;
        if (semaphores.create(0, 1, &self.wake_semaphore) != 0 or self.wake_semaphore == 0) return error.Semaphore;
        target.irq_wake = .{ .context = self.self_address, .signal = wake };
        if (service.start(pace, self.self_address, 0, &self.task) != 0 or self.task == 0) return error.Task;
    }
    /// Serialized init/shutdown caller. Stop future native admission before
    /// allowing the pacing task to cancel/drain its outstanding completion.
    /// Timeout preserves all task, callback and device resources.
    pub fn stop(self: *Work) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        @atomicStore(u32, &self.stopping, 1, .release);
        if (!self.device.?.stop()) return false;
        if (self.wake_semaphore != 0) _ = wake(self.self_address);
        if (self.task != 0) {
            const service = self.threads.?;
            if (service.stop(self.task) != 0) return false;
            var result: i32 = 0;
            if (service.join(self.task, @max(self.ctx.?.timerFrequency(), 1), &result) != 0) return false;
            if (self.completion != 0) return false;
            // Callback completion precedes exact Task retirement. Allow that
            // existing bounded handoff; any other error retains this owner.
            const ctx = self.ctx.?;
            const started_at = ctx.tickCount();
            while (true) {
                const released = service.release(self.task);
                if (released == 0) break;
                if (released != a.driver_thread_error_busy or ctx.tickCount() -% started_at >= @max(ctx.timerFrequency(), 1)) return false;
                ctx.waitTicks(1);
            }
            self.task = 0;
        }
        if (self.wake_semaphore != 0) {
            if (self.semaphores.?.destroy(self.wake_semaphore) != 0) return false;
            self.wake_semaphore = 0;
        }
        self.device.?.irq_wake = null;
        self.* = .{};
        return true;
    }
    fn from(raw: usize) *Work { return @ptrFromInt(raw); }
    fn wake(raw: usize) i32 {
        const self = from(raw);
        // Immutable while a callback can run. One resident permit coalesces
        // interrupts; release is the existing IRQ-safe semaphore operation.
        const result = self.semaphores.?.release(self.wake_semaphore);
        return if (result == a.driver_semaphore_error_overflow) 0 else result;
    }
    fn pace(raw: usize) callconv(.c) i32 {
        const self = from(raw);
        if (self.self_address != raw or self.ctx == null or self.threads == null) return -1;
        const ctx = self.ctx.?;
        while (@atomicLoad(u32, &self.stopping, .acquire) == 0) {
            if (ctx.workSubmit(slice, raw, 0, &self.completion) != 0) {
                ctx.logError("NVIDIA gsp-start: pacing=failed reason=work-admission device=retained");
                return -1;
            }
            var result: i32 = 0;
            if (!self.finish(&result)) {
                ctx.logError("NVIDIA gsp-start: pacing=failed reason=work-completion device=retained");
                return -1;
            }
            if (result == 1) return 0;
            if (result < 0) return result;
            // Sleeping here releases the dedicated task's owner context.
            // No shared worker, MMIO callback or device lock spans this wait.
            // A GSP IRQ supplies a permit immediately; the finite timeout
            // preserves startup, deadlines and log polling if no IRQ arrives.
            const ticks = if (result == 2 and self.device.?.phase == .ready) @max(ctx.timerFrequency() / 100, 1) else 1;
            const waited = self.semaphores.?.acquire(self.wake_semaphore, ticks);
            if (waited != 0 and waited != a.driver_semaphore_error_timeout) {
                if (@atomicLoad(u32, &self.stopping, .acquire) != 0 or waited == a.driver_semaphore_error_cancelled) return 0;
                ctx.logError("NVIDIA gsp-start: pacing=failed reason=interrupt-wait device=retained");
                return -1;
            }
        }
        return 0;
    }
    fn finish(self: *Work, result: *i32) bool {
        const ctx = self.ctx.?;
        const started_at = ctx.tickCount();
        const bound = @max(ctx.timerFrequency(), 1);
        while (true) {
            var status: a.DriverCompletionStatus = .{};
            if (ctx.completionStatus(self.completion, &status) != 0) return false;
            if (status.state == a.driver_work_state_completed or status.state == a.driver_work_state_cancelled) {
                result.* = status.result;
                if (ctx.completionRelease(self.completion) != 0) return false;
                self.completion = 0;
                return true;
            }
            if (status.state != a.driver_work_state_queued and status.state != a.driver_work_state_running) return false;
            if (@atomicLoad(u32, &self.stopping, .acquire) != 0 and status.state == a.driver_work_state_queued) _ = ctx.workCancel(self.completion);
            if (ctx.tickCount() -% started_at >= bound) return false;
            ctx.waitTicks(1);
        }
    }
    fn slice(raw: usize) callconv(.c) i32 {
        const self = from(raw);
        if (self.self_address != raw or self.ctx == null or self.device == null) return -1;
        if (@atomicLoad(u32, &self.stopping, .acquire) != 0) return 1;
        const clock = self.device.?.port.clock orelse return -1;
        const started_at = clock.nowNs();
        if (started_at == std.math.maxInt(u64)) return -1;
        // Both a step count and a monotonic time bound apply. A single step
        // already has its native phase's finite deadline and register limit.
        for (0..64) |_| {
            if (@atomicLoad(u32, &self.stopping, .acquire) != 0) return 1;
            switch (self.device.?.step()) {
                .stopped => return 1,
                .idle => return 2,
                .progress => {},
            }
            const current = clock.nowNs();
            if (current == std.math.maxInt(u64) or current < started_at) return -1;
            if (current - started_at >= 2 * std.time.ns_per_ms) break;
        }
        return 0;
    }
};
