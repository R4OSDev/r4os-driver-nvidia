const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
var api: ?*const a.DriverApi = null;
var service: ?r4os.r4dev.DriverSemaphoreContext = null;
var threads: ?r4os.r4dev.DriverThreadContext = null;
var gate: u64 = 0;
var mutex: u64 = 0;
var handles: [4]u64 = .{0} ** 4;
var fifo_next: u32 = 0;
var shared_value: u64 = 0;
var shared_check: u64 = 0x79007900;
var prepared = false;
var close_wait = false;

// Runs only in the explicit offline runtime-check. These are real R4D API
// calls, real Task waits and real permit handoffs, never a mock scheduler.
pub fn start(ctx: *const r4os.r4dev.DriverContext) bool {
    if (api != null) return false;
    const semaphore_service = ctx.semaphores() orelse return false;
    const thread_service = ctx.threads() orelse return false;
    service = semaphore_service;
    threads = thread_service;
    api = ctx.api;
    const sem = service.?;
    var before: a.DriverSemaphoreStats = .{};
    if (sem.stats(&before) != 0 or before.records != 0 or before.owner_epoch == 0 or
        sem.contextFlags() != a.driver_semaphore_context_sleepable) return failed(ctx, "context");
    var invalid: u64 = 79;
    if (sem.create(1, 0, &invalid) != a.driver_semaphore_error_invalid or invalid != 0 or
        sem.create(2, 1, &invalid) != a.driver_semaphore_error_invalid or invalid != 0) return failed(ctx, "bounds");
    if (sem.create(0, 1, &gate) != 0 or sem.create(1, 1, &mutex) != 0) return failed(ctx, "create");
    const began = ctx.tickCount();
    if (sem.acquire(gate, 0) != a.driver_semaphore_error_timeout or sem.acquire(gate, 5) != a.driver_semaphore_error_timeout or
        ctx.tickCount() -% began < 5 or ctx.tickCount() -% began > timeout(ctx)) return failed(ctx, "timeout");
    if (sem.release(gate) != 0 or sem.release(gate) != a.driver_semaphore_error_overflow or sem.acquire(gate, 0) != 0 or
        sem.acquire(gate, 0) != a.driver_semaphore_error_timeout) return failed(ctx, "counter");
    var temporary: u64 = 0;
    if (sem.create(0, std.math.maxInt(u32), &temporary) != 0 or sem.destroy(temporary) != 0) return failed(ctx, "destroy");
    var stale: a.DriverSemaphoreStatus = .{};
    if (sem.status(temporary, &stale) != a.driver_semaphore_error_stale) return failed(ctx, "stale");

    // Enroll in a known order, then release exactly one at a time. Every
    // join names the expected FIFO recipient; polling never grants a permit.
    @atomicStore(u32, &fifo_next, 0, .release);
    for (0..3) |index| {
        if (threads.?.start(fifoWait, index, a.driver_thread_flag_parallel, &handles[index]) != 0 or
            !awaitQueued(ctx, @intCast(index + 1))) return failed(ctx, "fifo-enrollment");
    }
    if (sem.destroy(gate) != a.driver_semaphore_error_busy) return failed(ctx, "wait-retention");
    for (0..3) |index| {
        var result: i32 = 0;
        if (sem.release(gate) != 0 or threads.?.join(handles[index], timeout(ctx), &result) != 0 or result != 79 + @as(i32, @intCast(index)) or
            !retire(ctx, &handles[index])) return failed(ctx, "fifo-handoff");
    }
    shared_value = 0;
    shared_check = 0x79007900;
    for (&handles, 0..) |*handle, index| {
        if (threads.?.start(contend, index, a.driver_thread_flag_parallel, handle) != 0) return failed(ctx, "contention-start");
    }
    for (&handles) |*handle| {
        var result: i32 = 0;
        const joined = threads.?.join(handle.*, timeout(ctx), &result);
        if (joined != 0 or result != 0) {
            var message: [192]u8 = undefined;
            const line = std.fmt.bufPrintZ(&message, "NVIDIA runtime-check: semaphore-contention join={d} callback={d}", .{ joined, result }) catch unreachable;
            ctx.logError(line.ptr);
            return failed(ctx, "contention-join");
        }
        if (!retire(ctx, handle)) return failed(ctx, "contention-retire");
    }
    if (shared_value != 256 or shared_check != (shared_value ^ 0x79007900)) return failed(ctx, "exclusion");
    var after: a.DriverSemaphoreStats = .{};
    if (sem.stats(&after) != 0 or after.records != 2 or after.active_acquires != 0 or after.pending_creates != 0 or
        after.pending_destroys != 0 or after.destroys - before.destroys != 1) return failed(ctx, "accounting");
    prepared = true;
    ctx.logInfo("NVIDIA runtime-check: semaphores=OK fifo=3 contention=256 timeout=bounded overflow=retained stale=verified");
    return true;
}
pub fn prepareClose(ctx: *const r4os.r4dev.DriverContext) bool {
    const t = threads orelse return false;
    if (t.start(closeWait, 0, a.driver_thread_flag_parallel, &handles[0]) != 0 or !awaitQueued(ctx, 1)) return failed(ctx, "close-enrollment");
    // A cooperative stop must leave this uninterruptible semaphore wait
    // enrolled. The shutdown callback will provide its actual permit.
    if (t.stop(handles[0]) != 0) return failed(ctx, "close-stop");
    ctx.waitTicks(2);
    var result: i32 = 79;
    if (t.join(handles[0], 0, &result) != a.driver_thread_error_timeout or result != 0 or !awaitQueued(ctx, 1)) return failed(ctx, "stop-fabricated-permit");
    close_wait = true;
    return true;
}
pub fn shutdown(ctx: *const r4os.r4dev.DriverContext) bool {
    const sem = service orelse return true;
    const t = threads orelse return true;
    var correct = true;
    if (prepared and close_wait) {
        var snapshot: a.DriverSemaphoreStats = .{};
        var descriptor: a.DriverSemaphoreStatus = .{};
        var rejected: u64 = 79;
        if (ctx.semaphores() != null or sem.stats(&snapshot) != 0 or snapshot.closing != 1 or
            sem.status(gate, &descriptor) != 0 or descriptor.queued_waiters != 1 or descriptor.active_acquires != 1 or
            sem.create(0, 1, &rejected) != a.driver_semaphore_error_closed or rejected != 0 or
            sem.destroy(gate) != a.driver_semaphore_error_busy) correct = false;
    }
    // Failed probes also release every possible gate waiter. No provider is
    // unbound until all callbacks actually return and their Tasks retire.
    if (gate != 0) {
        const count: usize = if (prepared and close_wait) 1 else handles.len;
        for (0..count) |_| _ = sem.release(gate);
    }
    for (&handles) |*handle| {
        if (handle.* == 0) continue;
        var result: i32 = 0;
        if (t.join(handle.*, timeout(ctx), &result) != 0) return false;
        if (result != 0) correct = false;
        if (!retire(ctx, handle)) return false;
    }
    if (prepared and close_wait) {
        var snapshot: a.DriverSemaphoreStats = .{};
        if (sem.stats(&snapshot) != 0 or snapshot.records != 2 or snapshot.active_acquires != 0 or snapshot.pending_creates != 0 or snapshot.pending_destroys != 0) correct = false;
        if (correct) ctx.logInfo("NVIDIA runtime-check: semaphore-close=OK stop=no-permit admission=closed wait=completed records=2") else ctx.logError("NVIDIA runtime-check: FAILED phase=semaphore-close callbacks=quiesced");
    }
    // The generic kernel cleanup frees these two retained records after
    // all driver Tasks, work and IRQ callbacks have genuinely quiesced.
    gate = 0;
    mutex = 0;
    prepared = false;
    close_wait = false;
    api = null;
    threads = null;
    service = null;
    return true;
}
fn fifoWait(index: usize) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api orelse return -1);
    if (service.?.acquire(gate, timeout(&ctx)) != 0) return -2;
    if (@atomicRmw(u32, &fifo_next, .Add, 1, .acq_rel) != index) return -3;
    return 79 + @as(i32, @intCast(index));
}
fn contend(_: usize) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api orelse return -1);
    const sem = service.?;
    for (0..64) |_| {
        const acquired = sem.acquire(mutex, timeout(&ctx));
        if (acquired != 0) return -100 + acquired;
        const old = shared_value;
        const consistent = shared_check == (old ^ 0x79007900);
        const slept = threads.?.sleepTicks(1);
        if (!consistent or slept != 0 or shared_value != old or shared_check != (old ^ 0x79007900)) {
            _ = sem.release(mutex);
            return if (slept != 0) -200 + slept else -3;
        }
        shared_value = old + 1;
        shared_check = shared_value ^ 0x79007900;
        const released = sem.release(mutex);
        if (released != 0) return -300 + released;
    }
    return 0;
}
fn closeWait(_: usize) callconv(.c) i32 {
    if (service.?.acquire(gate, std.math.maxInt(u64)) != 0) return -1;
    var stats: a.DriverSemaphoreStats = .{};
    if (service.?.stats(&stats) != 0 or stats.closing != 1) return -2;
    return 0;
}
fn awaitQueued(ctx: *const r4os.r4dev.DriverContext, count: u32) bool {
    const began = ctx.tickCount();
    while (ctx.tickCount() -% began < timeout(ctx)) {
        var value: a.DriverSemaphoreStatus = .{};
        if (service.?.status(gate, &value) != 0) return false;
        if (value.queued_waiters == count and value.active_acquires == count and value.available == 0) return true;
        ctx.waitTicks(1);
    }
    return false;
}
fn retire(ctx: *const r4os.r4dev.DriverContext, handle: *u64) bool {
    const began = ctx.tickCount();
    while (true) {
        const result = threads.?.release(handle.*);
        if (result == 0) {
            handle.* = 0;
            return true;
        }
        if (result != a.driver_thread_error_busy or ctx.tickCount() -% began >= timeout(ctx)) return false;
        ctx.waitTicks(1);
    }
}
fn timeout(ctx: *const r4os.r4dev.DriverContext) u64 {
    return @as(u64, @max(ctx.timerFrequency(), 1)) * 5;
}
fn failed(ctx: *const r4os.r4dev.DriverContext, phase: []const u8) bool {
    var message: [160]u8 = undefined;
    const line = std.fmt.bufPrintZ(&message, "NVIDIA runtime-check: FAILED phase=semaphore-{s}", .{phase}) catch unreachable;
    ctx.logError(line.ptr);
    return false;
}
