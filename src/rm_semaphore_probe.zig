const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const provider = @import("rm_semaphore.zig");
const heap = @import("rm_heap.zig");
var api: ?*const a.DriverApi = null;
var semaphores: ?r4os.r4dev.DriverSemaphoreContext = null;
var threads: ?r4os.r4dev.DriverThreadContext = null;
var pointer: ?*anyopaque = null;
var handles: [4]u64 = .{0} ** 4;
var shared_value: u64 = 0;
var shared_check: u64 = 0;
var close_gate = false;
var close_prepared = false;
var baseline_acquires: u32 = 0;

// Explicit diagnostic only. Executes the actual private Zig C-ABI provider
// against R4D services; native_probe covers the linked original-header C path.
pub fn start(ctx: *const r4os.r4dev.DriverContext) bool {
    if (api != null or !provider.available()) return false;
    semaphores = ctx.semaphores() orelse return false;
    threads = ctx.threads() orelse return false;
    api = ctx.api;
    const cpu = ctx.heap() orelse return false;
    var before: a.DriverHeapStats = .{};
    if (cpu.stats(&before) != 0 or before.allocations != 0 or provider.r4nv_semaphore_context_flags() != provider.sleepable)
        return failed(ctx, "context");
    pointer = provider.r4nv_semaphore_create(0) orelse return failed(ctx, "create");
    const began = ctx.tickCount();
    if (provider.r4nv_semaphore_acquire(pointer, 0) != provider.retry or provider.r4nv_semaphore_acquire(pointer, 5) != provider.retry or
        ctx.tickCount() -% began < 5 or ctx.tickCount() -% began > timeout(ctx)) return failed(ctx, "timeout");
    if (provider.r4nv_semaphore_release(pointer) != provider.ok or provider.r4nv_semaphore_acquire(pointer, std.math.maxInt(u64)) != provider.ok or
        !freePointer()) return failed(ctx, "permit");
    pointer = provider.r4nv_semaphore_create(1) orelse return failed(ctx, "mutex");
    shared_value = 0;
    shared_check = 0x79001079;
    for (&handles) |*handle| {
        if (threads.?.start(contend, 0, a.driver_thread_flag_parallel, handle) != 0) return failed(ctx, "start");
    }
    for (&handles) |*handle| {
        var result: i32 = 0;
        if (threads.?.join(handle.*, timeout(ctx), &result) != 0 or result != 0 or !retire(ctx, handle)) return failed(ctx, "join");
    }
    if (shared_value != 128 or shared_check != shared_value ^ 0x79001079 or !freePointer()) return failed(ctx, "exclusion");
    var after: a.DriverHeapStats = .{};
    var sem: a.DriverSemaphoreStats = .{};
    var task: a.DriverThreadStats = .{};
    if (cpu.stats(&after) != 0 or after.allocations != 0 or after.bytes != 0 or heap.releaseFailures() != 0 or
        semaphores.?.stats(&sem) != 0 or sem.records != 0 or sem.active_acquires != 0 or
        threads.?.stats(&task) != 0 or task.records != 0 or !provider.available()) return failed(ctx, "cleanup");
    ctx.logInfo("NVIDIA runtime-check: private-semaphores=OK callbacks=4 contention=128 timeout=bounded cpu-boxes=freed provider=zig");
    return true;
}
pub fn prepareClose(ctx: *const r4os.r4dev.DriverContext) bool {
    var before: a.DriverSemaphoreStats = .{};
    if (semaphores.?.stats(&before) != 0) return failed(ctx, "close-stats");
    baseline_acquires = before.active_acquires;
    pointer = provider.r4nv_semaphore_create(0) orelse return failed(ctx, "close-create");
    close_gate = true;
    if (threads.?.start(waitForClose, 0, a.driver_thread_flag_parallel, &handles[0]) != 0 or !awaitQueued(ctx)) return failed(ctx, "close-enroll");
    if (provider.r4nv_semaphore_free(pointer) != provider.retry or threads.?.stop(handles[0]) != 0) return failed(ctx, "close-retain");
    ctx.waitTicks(2);
    var result: i32 = 79;
    if (threads.?.join(handles[0], 0, &result) != a.driver_thread_error_timeout or result != 0 or !awaitQueued(ctx)) return failed(ctx, "close-stop");
    close_prepared = true;
    return true;
}
pub fn shutdown(ctx: *const r4os.r4dev.DriverContext) bool {
    const t = threads orelse return true;
    var correct = true;
    if (close_prepared) {
        var sem: a.DriverSemaphoreStats = .{};
        if (ctx.semaphores() != null or semaphores.?.stats(&sem) != 0 or sem.closing != 1 or
            sem.active_acquires != baseline_acquires + 1 or provider.r4nv_semaphore_create(1) != null or
            provider.r4nv_semaphore_free(pointer) != provider.retry) correct = false;
    }
    if (close_gate and pointer != null and provider.r4nv_semaphore_release(pointer) != provider.ok) return false;
    for (&handles) |*handle| {
        if (handle.* == 0) continue;
        var result: i32 = 0;
        if (t.join(handle.*, timeout(ctx), &result) != 0) return false;
        if (result != 0) correct = false;
        if (!retire(ctx, handle)) return false;
    }
    if (!freePointer()) return false;
    if (close_prepared) {
        var sem: a.DriverSemaphoreStats = .{};
        if (semaphores.?.stats(&sem) != 0 or sem.records != 2 or sem.active_acquires != baseline_acquires or
            !provider.available() or heap.releaseFailures() != 0) correct = false;
        if (correct) ctx.logInfo("NVIDIA runtime-check: private-semaphore-close=OK stop=no-permit wait=completed busy=retained cpu-box=freed") else _ = failed(ctx, "close-result");
    }
    api = null;
    threads = null;
    semaphores = null;
    close_gate = false;
    close_prepared = false;
    return true;
}
fn contend(_: usize) callconv(.c) i32 {
    for (0..32) |_| {
        if (provider.r4nv_semaphore_acquire(pointer, std.math.maxInt(u64)) != provider.ok) return -1;
        const old = shared_value;
        const consistent = shared_check == old ^ 0x79001079;
        const slept = threads.?.sleepTicks(1);
        if (!consistent or slept != 0 or shared_value != old or shared_check != old ^ 0x79001079) {
            _ = provider.r4nv_semaphore_release(pointer);
            return -2;
        }
        shared_value = old + 1;
        shared_check = shared_value ^ 0x79001079;
        if (provider.r4nv_semaphore_release(pointer) != provider.ok) return -3;
    }
    return 0;
}
fn waitForClose(_: usize) callconv(.c) i32 {
    if (provider.r4nv_semaphore_acquire(pointer, std.math.maxInt(u64)) != provider.ok) return -1;
    var stats: a.DriverSemaphoreStats = .{};
    return if (semaphores.?.stats(&stats) == 0 and stats.closing == 1) 0 else -2;
}
fn awaitQueued(ctx: *const r4os.r4dev.DriverContext) bool {
    const began = ctx.tickCount();
    while (ctx.tickCount() -% began < timeout(ctx)) {
        var stats: a.DriverSemaphoreStats = .{};
        if (semaphores.?.stats(&stats) != 0) return false;
        if (stats.active_acquires == baseline_acquires + 1) return true;
        ctx.waitTicks(1);
    }
    return false;
}
fn freePointer() bool {
    if (provider.r4nv_semaphore_free(pointer) != provider.ok) return false;
    pointer = null;
    return true;
}
fn retire(ctx: *const r4os.r4dev.DriverContext, handle: *u64) bool {
    const began = ctx.tickCount();
    while (true) {
        const code = threads.?.release(handle.*);
        if (code == 0) {
            handle.* = 0;
            return true;
        }
        if (code != a.driver_thread_error_busy or ctx.tickCount() -% began >= timeout(ctx)) return false;
        ctx.waitTicks(1);
    }
}
fn timeout(ctx: *const r4os.r4dev.DriverContext) u64 {
    return @as(u64, @max(ctx.timerFrequency(), 1)) * 5;
}
fn failed(ctx: *const r4os.r4dev.DriverContext, phase: []const u8) bool {
    var message: [160]u8 = undefined;
    const line = std.fmt.bufPrintZ(&message, "NVIDIA runtime-check: FAILED phase=private-semaphore-{s}", .{phase}) catch unreachable;
    ctx.logError(line.ptr);
    return false;
}
