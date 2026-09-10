const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const native = @import("rm_native.zig");
const heap = @import("rm_heap.zig");
const semaphore = @import("rm_semaphore.zig");
const Handler = *const fn (usize) callconv(.c) i32;
const State = extern struct {
    memory: ?*anyopaque = null,
    semaphore: ?*anyopaque = null,
    after_fault: u32 = 0,
    after_wait: u32 = 0,
    permit_sent: u32 = 0,
};
comptime {
    if (@sizeOf(State) != 32 or @offsetOf(State, "permit_sent") != 24) @compileError("native C probe layout drift");
}
extern fn r4nv_semaphore_probe_healthy(usize) callconv(.c) i32;
extern fn r4nv_semaphore_probe_setup(usize) callconv(.c) i32;
extern fn r4nv_semaphore_probe_wait(usize) callconv(.c) i32;
extern fn r4nv_semaphore_probe_fault(usize) callconv(.c) i32;
extern fn r4nv_semaphore_probe_permit(usize) callconv(.c) i32;
extern fn r4nv_semaphore_probe_cleanup(usize) callconv(.c) i32;
// Keep Task entry addresses in Zig and call C directly. Taking an external
// C address produces REX_GOTPCRELX hints that the current portable R4M0
// packager deliberately rejects; these thunks need only PC32/PLT32.
fn healthy(context: usize) callconv(.c) i32 {
    return r4nv_semaphore_probe_healthy(context);
}
fn setup(context: usize) callconv(.c) i32 {
    return r4nv_semaphore_probe_setup(context);
}
fn wait(context: usize) callconv(.c) i32 {
    return r4nv_semaphore_probe_wait(context);
}
fn fault(context: usize) callconv(.c) i32 {
    return r4nv_semaphore_probe_fault(context);
}
fn permit(context: usize) callconv(.c) i32 {
    return r4nv_semaphore_probe_permit(context);
}
fn cleanup(context: usize) callconv(.c) i32 {
    return r4nv_semaphore_probe_cleanup(context);
}
var threads: ?r4os.r4dev.DriverThreadContext = null;
var state: State = .{};
// Diagnostic concurrency only; the dispatcher itself has caller-owned records
// and no fixed invocation pool. These stay resident through Task retirement.
var calls: [2]native.Invocation = undefined;
var handles: [2]u64 = .{ 0, 0 };

pub fn start(ctx: *const r4os.r4dev.DriverContext) bool {
    if (threads != null or !native.available()) return failed(ctx, "unavailable");
    threads = ctx.threads() orelse return failed(ctx, "query");
    if (!prefixCompatible(ctx) or threads.?.abortCurrent(native.aborted) != a.driver_thread_error_context)
        return failed(ctx, "prefix-context");
    if (threads.?.start(refuseAbort, 0, a.driver_thread_flag_aborted, &handles[0]) != a.driver_thread_error_invalid or handles[0] != 0)
        return failed(ctx, "status-flag");
    if (threads.?.start(refuseAbort, 0, 0, &handles[0]) != 0 or !completed(ctx, 0, 0, false))
        return failed(ctx, "ordinary-context");
    if (!launch(0, refuseAbort, false, 1) or !completed(ctx, 0, 0, false)) return failed(ctx, "negative-only");
    if (!launch(0, healthy, false, @intFromPtr(&state)) or !completed(ctx, 0, 0, false))
        return failed(ctx, "healthy");
    const cpu = ctx.heap() orelse return failed(ctx, "heap");
    const sem = ctx.semaphores() orelse return failed(ctx, "semaphores");
    var memory: a.DriverHeapStats = .{};
    var gates: a.DriverSemaphoreStats = .{};
    var tasks: a.DriverThreadStats = .{};
    if (cpu.stats(&memory) != 0 or memory.allocations != 0 or memory.bytes != 0 or
        sem.stats(&gates) != 0 or gates.records != 0 or gates.active_acquires != 0 or
        threads.?.stats(&tasks) != 0 or tasks.records != 0 or native.faultCount() != 0 or native.firstFault() != 0 or
        !semaphore.available() or heap.releaseFailures() != 0 or state.semaphore != null) return failed(ctx, "healthy-cleanup");
    ctx.logInfo("NVIDIA runtime-check: native-semaphores=OK adapters=16 provider=driver-api link=actual resources=0");
    ctx.logInfo("NVIDIA runtime-check: native-boundary=OK prefix=72,80 context=checked result=negative-only status-flag=rejected");
    return true;
}

// Run last: its latched failure must reject new ordinary native work, while
// pre-existing waiters remain entitled to a real permit and explicit cleanup.
pub fn prepareFault(ctx: *const r4os.r4dev.DriverContext) bool {
    const cpu = ctx.heap() orelse return false;
    const sem = ctx.semaphores() orelse return false;
    var before_memory: a.DriverHeapStats = .{};
    var before_gates: a.DriverSemaphoreStats = .{};
    var before_tasks: a.DriverThreadStats = .{};
    if (cpu.stats(&before_memory) != 0 or sem.stats(&before_gates) != 0 or threads.?.stats(&before_tasks) != 0)
        return failed(ctx, "baseline");
    if (!launch(0, setup, false, @intFromPtr(&state)) or !completed(ctx, 0, 0, false) or
        !launch(1, wait, false, @intFromPtr(&state))) return failed(ctx, "setup");
    const began = ctx.tickCount();
    while (true) {
        var gates: a.DriverSemaphoreStats = .{};
        if (sem.stats(&gates) != 0) return failed(ctx, "enroll-stats");
        if (gates.active_acquires == before_gates.active_acquires + 1) break;
        if (ctx.tickCount() -% began >= timeout(ctx)) return failed(ctx, "enroll-timeout");
        ctx.waitTicks(1);
    }
    if (!launch(0, fault, false, @intFromPtr(&state)) or !completed(ctx, 0, native.aborted, true))
        return failed(ctx, "abort");
    if (native.faultCount() != 1 or native.firstFault() != (@as(u64, 1) << 32) | 1 or
        @atomicLoad(u32, &state.after_fault, .acquire) != 0 or @atomicLoad(u32, &state.after_wait, .acquire) != 0)
        return failed(ctx, "fault-latch");
    calls[0] = .{ .handler = fault, .context = @intFromPtr(&state) };
    if (native.start(&calls[0], 0, &handles[0]) != a.driver_thread_error_closed or handles[0] != 0)
        return failed(ctx, "closed");
    var result: i32 = 79;
    var retained_memory: a.DriverHeapStats = .{};
    var retained_gates: a.DriverSemaphoreStats = .{};
    if (threads.?.join(handles[1], 0, &result) != a.driver_thread_error_timeout or result != 0 or
        cpu.stats(&retained_memory) != 0 or retained_memory.allocations != before_memory.allocations + 2 or
        retained_memory.bytes != before_memory.bytes + 145 or sem.stats(&retained_gates) != 0 or
        retained_gates.records != before_gates.records + 1 or retained_gates.active_acquires != before_gates.active_acquires + 1)
        return failed(ctx, "retention");
    ctx.logInfo("NVIDIA runtime-check: native-abort=OK fault=busy-free callback=aborted after-call=unreached memory=145-retained waiter=no-permit admission=closed");
    if (!launch(0, permit, true, @intFromPtr(&state)) or !completed(ctx, 0, 0, false) or
        !completed(ctx, 1, 0, false) or @atomicLoad(u32, &state.after_wait, .acquire) != 1 or
        !launch(0, cleanup, true, @intFromPtr(&state)) or !completed(ctx, 0, 0, false) or
        !freeMemory()) return failed(ctx, "recovery");
    var after_memory: a.DriverHeapStats = .{};
    var after_gates: a.DriverSemaphoreStats = .{};
    var after_tasks: a.DriverThreadStats = .{};
    if (cpu.stats(&after_memory) != 0 or after_memory.allocations != before_memory.allocations or after_memory.bytes != before_memory.bytes or
        sem.stats(&after_gates) != 0 or after_gates.records != before_gates.records or after_gates.active_acquires != before_gates.active_acquires or
        threads.?.stats(&after_tasks) != 0 or after_tasks.records != before_tasks.records or native.faultCount() != 1 or
        !semaphore.available() or heap.releaseFailures() != 0) return failed(ctx, "recovery-accounting");
    ctx.logInfo("NVIDIA runtime-check: native-recovery=OK permit=real waiter=joined tasks=retired semaphore=freed memory=freed fault=latched");
    return true;
}

pub fn shutdown(ctx: *const r4os.r4dev.DriverContext) bool {
    if (threads == null) return true;
    // No new Tasks can be started after owner close. Finish any partial probe
    // with the cached providers, then free only after every peer has retired.
    if (!quiesce(ctx, 0)) return false;
    if (handles[1] != 0 and @atomicLoad(u32, &state.permit_sent, .acquire) == 0) {
        if (semaphore.r4nv_semaphore_release(state.semaphore) != semaphore.ok) return false;
        @atomicStore(u32, &state.permit_sent, 1, .release);
    }
    if (!quiesce(ctx, 1)) return false;
    if (semaphore.r4nv_semaphore_free(state.semaphore) != semaphore.ok) return false;
    state.semaphore = null;
    if (!freeMemory()) return false;
    state = .{};
    threads = null;
    return true;
}
fn refuseAbort(context: usize) callconv(.c) i32 {
    const service = threads orelse return -1;
    if (service.abortCurrent(0) != a.driver_thread_error_invalid or service.abortCurrent(79) != a.driver_thread_error_invalid) return -2;
    if (context == 0 and service.abortCurrent(native.aborted) != a.driver_thread_error_context) return -3;
    return 0;
}
fn prefixCompatible(ctx: *const r4os.r4dev.DriverContext) bool {
    const query = ctx.api.thread_query orelse return false;
    const Guard = extern struct { table: a.DriverThreadApi, tail: [16]u8 };
    for ([_]u32{ 72, 73, 79, 80 }) |capacity| {
        var guarded: Guard = undefined;
        @memset(std.mem.asBytes(&guarded), 0xa5);
        guarded.table.version = 1;
        guarded.table.size = capacity;
        const expected: usize = if (capacity >= 80) 80 else 72;
        if (query(&guarded.table) != 0 or guarded.table.size != expected or guarded.table.current == 0) return false;
        for (std.mem.asBytes(&guarded)[expected..]) |byte| if (byte != 0xa5) return false;
        if (expected == 80 and guarded.table.abort_current == 0) return false;
    }
    for ([_]a.DriverThreadApi{ .{ .version = 2 }, .{ .size = 71 } }) |invalid| {
        var guarded = invalid;
        if (query(&guarded) != a.driver_thread_error_invalid or !std.mem.eql(u8, std.mem.asBytes(&guarded), std.mem.asBytes(&invalid))) return false;
    }
    return true;
}
fn launch(index: usize, handler: Handler, is_cleanup: bool, context: usize) bool {
    if (handles[index] != 0) return false;
    calls[index] = .{ .handler = handler, .context = context, .cleanup = is_cleanup };
    return native.start(&calls[index], a.driver_thread_flag_parallel, &handles[index]) == 0;
}
fn completed(ctx: *const r4os.r4dev.DriverContext, index: usize, expected: i32, aborted: bool) bool {
    var result: i32 = 0;
    var status: a.DriverThreadStatus = .{};
    if (threads.?.join(handles[index], timeout(ctx), &result) != 0 or result != expected or
        threads.?.status(handles[index], &status) != 0 or (status.flags & a.driver_thread_flag_aborted != 0) != aborted) return false;
    return retire(ctx, &handles[index]);
}
fn quiesce(ctx: *const r4os.r4dev.DriverContext, index: usize) bool {
    if (handles[index] == 0) return true;
    var result: i32 = 0;
    return threads.?.join(handles[index], timeout(ctx), &result) == 0 and retire(ctx, &handles[index]);
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
fn freeMemory() bool {
    if (!heap.release(state.memory)) return false;
    state.memory = null;
    return true;
}
fn timeout(ctx: *const r4os.r4dev.DriverContext) u64 {
    return @as(u64, @max(ctx.timerFrequency(), 1)) * 5;
}
fn failed(ctx: *const r4os.r4dev.DriverContext, phase: []const u8) bool {
    var message: [160]u8 = undefined;
    const line = std.fmt.bufPrintZ(&message, "NVIDIA runtime-check: FAILED phase=native-{s}", .{phase}) catch unreachable;
    ctx.logError(line.ptr);
    return false;
}
