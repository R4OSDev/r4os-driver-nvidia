//! A dedicated pacing task owns waits; short serialized DriverWork callbacks
//! under the lifecycle owner alone mutate the native device. Exactly one
//! outstanding work completion; waits never hold the lifecycle owner.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const device = @import("gsp_device.zig");
pub fn supported(ctx: *const r4os.r4dev.DriverContext) bool {
    return ctx.supportsDriverApi(a.driver_api_owned_work_version, @offsetOf(a.DriverApi, "driver_work_submit_owned") + 8) and
        ctx.api.driver_work_submit_owned != null;
}
pub const Work = struct {
    self_address: usize = 0,
    ctx: ?r4os.r4dev.DriverContext = null,
    threads: ?r4os.r4dev.DriverThreadContext = null,
    semaphores: ?r4os.r4dev.DriverSemaphoreContext = null,
    wake_semaphore: u64 = 0,
    device: ?*device.Device = null,
    task: u64 = 0,
    completion: u32 = 0,
    completion_disposition: u32 = std.math.maxInt(u32),
    stopping: u32 = 0,

    pub fn start(self: *Work, ctx: *const r4os.r4dev.DriverContext, target: *device.Device) !void {
        if (self.self_address != 0 or target.self_address != @intFromPtr(target)) return error.State;
        if (!supported(ctx)) return error.Api;
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
        return self.pause() and self.finishPause();
    }
    /// Drain the pacing Task without poisoning the resident device or
    /// destroying the semaphore still reachable from a live IRQ callback.
    pub fn pause(self: *Work) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        @atomicStore(u32, &self.stopping, 1, .release);
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
        return self.completion == 0;
    }
    pub fn finishPause(self: *Work) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.task != 0 or self.completion != 0 or
            @atomicLoad(u32, &self.stopping, .acquire) == 0) return false;
        const target = self.device orelse return false;
        if (target.interrupts.self_address != 0 and !target.interrupts.closed) return false;
        if (self.wake_semaphore != 0) {
            if (self.semaphores.?.destroy(self.wake_semaphore) != 0) return false;
            self.wake_semaphore = 0;
        }
        target.irq_wake = null;
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
        var owner_wait_started = ctx.tickCount();
        var owner_retries: u32 = 0;
        while (@atomicLoad(u32, &self.stopping, .acquire) == 0) {
            // Ordinary Work carries a driver identity but no lifecycle guard;
            // it cannot query the boot hold or perform display/MMIO operations.
            if (self.completion == 0) @atomicStore(u32, &self.completion_disposition, std.math.maxInt(u32), .release);
            if (self.completion != 0 or ctx.workSubmitOwned(slice, raw, &self.completion) != 0 or self.completion == 0) {
                ctx.logError("NVIDIA gsp-start: pacing=failed reason=work-admission device=retained");
                return -1;
            }
            var result: i32 = 0;
            if (!self.finish(&result)) {
                ctx.logError("NVIDIA gsp-start: pacing=failed reason=work-completion device=retained");
                return -1;
            }
            if (result == 1) return 0;
            if (result == a.driver_work_owner_busy) {
                // No callback ran. Its ticket has been released by finish;
                // retry only after pacing, without retaining the shared lane.
                owner_retries += 1;
                if (owner_retries >= 4096 or ctx.tickCount() -% owner_wait_started >= 5 * @as(u64, @max(ctx.timerFrequency(), 1))) {
                    ctx.logError("NVIDIA gsp-start: pacing=failed reason=owner-deadline device=retained");
                    return result;
                }
            } else {
                if (result < 0) return result;
                owner_wait_started = ctx.tickCount();
                owner_retries = 0;
            }
            // A slice which used its bounded progress budget has not reached
            // an idle hardware wait. Requeue behind other owners immediately,
            // after releasing this exact completion and lifecycle guard.
            // Idle polling and owner contention retain their finite waits.
            if (result == 3) continue;
            // Sleeping here releases the dedicated task's owner context.
            // No shared worker, MMIO callback or device lock spans this wait.
            // A GSP IRQ supplies a permit immediately; the finite timeout
            // preserves startup, deadlines and log polling if no IRQ arrives.
            const ticks = if (result == 2) @max(ctx.timerFrequency() / 100, 1) else 1;
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
            const queried = ctx.completionStatus(self.completion, &status);
            if (queried != 0) return self.failedCompletion("status", queried, status, started_at);
            if (status.state == a.driver_work_state_completed or status.state == a.driver_work_state_cancelled) {
                var disposition = status.result;
                if (status.state == a.driver_work_state_completed and status.result == 0) {
                    const published = @atomicLoad(u32, &self.completion_disposition, .acquire);
                    // Kernel Work success is zero. Our pacing state belongs
                    // to this exact callback, not its generic result code.
                    // Missing publication cannot release the retained ticket.
                    if (published > 3) return self.failedCompletion("disposition", 0, status, started_at);
                    disposition = @intCast(published);
                }
                const released = ctx.completionRelease(self.completion);
                if (released == 0) {
                    result.* = disposition;
                    self.completion = 0;
                    @atomicStore(u32, &self.completion_disposition, std.math.maxInt(u32), .release);
                    return true;
                }
                // Final status can precede wake publication. Keep the exact
                // ticket until release succeeds or this bounded wait expires.
                if (released != -2) return self.failedCompletion("release", released, status, started_at);
            } else if (status.state == a.driver_work_state_queued or status.state == a.driver_work_state_running) {
                if (@atomicLoad(u32, &self.stopping, .acquire) != 0 and status.state == a.driver_work_state_queued) _ = ctx.workCancel(self.completion);
                const elapsed = ctx.tickCount() -% started_at;
                if (elapsed >= bound) return self.failedCompletion("deadline", 1, status, started_at);
                // The dedicated task sleeps on this exact completion. Its
                // physical callback and publication wake it immediately;
                // periodic status polling would add a tick to every turn.
                var waited_result: i32 = 0;
                const waited = ctx.completionWait(self.completion, bound - elapsed, &waited_result);
                if (waited == 0 or waited == a.driver_work_result_cancelled) continue;
                if (waited == 1) {
                    // A timeout wake can race the real callback's final
                    // publication. Recheck only this exact ticket; a final
                    // state still needs its actual disposition and release.
                    // Running/queued work keeps the original expired bound.
                    var raced: a.DriverCompletionStatus = .{};
                    const checked = ctx.completionStatus(self.completion, &raced);
                    if (checked == 0 and (raced.state == a.driver_work_state_completed or
                        raced.state == a.driver_work_state_cancelled)) continue;
                    return self.failedCompletion("wait-timeout", if (checked == 0) waited else checked, raced, started_at);
                }
                // A stopped task can have its wait cancelled while the
                // callback still owns its ticket. Drain with the original
                // bounded status/release path, never free that live ticket.
                if (waited != -5 or @atomicLoad(u32, &self.stopping, .acquire) == 0)
                    return self.failedCompletion("wait", waited, status, started_at);
            } else return self.failedCompletion("state", 0, status, started_at);
            if (ctx.tickCount() -% started_at >= bound) return self.failedCompletion("release-deadline", 1, status, started_at);
            ctx.waitTicks(1);
        }
    }
    fn failedCompletion(self: *const Work, phase: []const u8, result: i32, previous: a.DriverCompletionStatus, started_at: u64) bool {
        const ctx = self.ctx.?;
        var live: a.DriverCompletionStatus = .{};
        const queried = ctx.completionStatus(self.completion, &live);
        var bytes: [340]u8 = undefined;
        const message = std.fmt.bufPrintZ(&bytes,
            "NVIDIA work-completion: phase={s} code={d} ticket={d} prior-state={d} live-status={d} live-state={d} live-result={d} disposition={d} elapsed-ticks={d} stopping={d}",
            .{ phase, result, self.completion, previous.state, queried, live.state, live.result,
                @atomicLoad(u32, &self.completion_disposition, .acquire), ctx.tickCount() -% started_at,
                @atomicLoad(u32, &self.stopping, .acquire) }) catch return false;
        ctx.logError(message.ptr);
        return false;
    }
    fn completeSlice(self: *Work, disposition: u32) i32 {
        @atomicStore(u32, &self.completion_disposition, disposition, .release);
        return 0;
    }
    fn slice(raw: usize) callconv(.c) i32 {
        const self = from(raw);
        if (self.self_address != raw or self.ctx == null or self.device == null) return -1;
        if (@atomicLoad(u32, &self.stopping, .acquire) != 0) return self.completeSlice(1);
        // Reset temporarily retires the firmware port. Pacing belongs to
        // the resident driver, and must survive that port's replacement.
        const clock = self.ctx.?.resources() orelse return -1;
        const started_at = clock.nowNs();
        if (started_at == std.math.maxInt(u64)) return -1;
        // Both a step count and a monotonic time bound apply. A single step
        // already has its native phase's finite deadline and register limit.
        for (0..64) |_| {
            if (@atomicLoad(u32, &self.stopping, .acquire) != 0) return self.completeSlice(1);
            switch (self.device.?.step()) {
                .stopped => return self.completeSlice(1),
                // An unchanged snapshot can retain a queue job between CE/GR
                // sub-operations. Poll that owner's full lifetime at one tick;
                // the 10-ms delay belongs to a ready device without queued
                // work. Classify under the serialized lifecycle owner.
                .idle => return self.completeSlice(if (self.device.?.phase == .ready and !self.device.?.running.workPolling()) 2 else 0),
                .progress => {},
            }
            const current = clock.nowNs();
            if (current == std.math.maxInt(u64) or current < started_at) return -1;
            if (current - started_at >= 2 * std.time.ns_per_ms) break;
        }
        // The last step made progress; only the shared callback's step/time
        // budget ended this turn. Its next turn must not wait for an IRQ.
        return self.completeSlice(3);
    }
};
