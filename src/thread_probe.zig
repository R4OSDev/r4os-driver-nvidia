const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const heap = @import("rm_heap.zig");
const clock = @import("rm_clock.zig");
const ThreadContext = r4os.r4dev.DriverThreadContext;

// Explicit runtime-check only. These counts describe this short diagnostic,
// never a driver/runtime capacity. All callbacks use resident CPU services.
var api: ?*const a.DriverApi = null;
var threads: ?ThreadContext = null;
var handles: [7]u64 = .{0} ** 7;
var ready: [7]u32 = .{0} ** 7;
var samples: [4]a.DriverThreadStatus = .{a.DriverThreadStatus{}} ** 4;
var go: u32 = 0;
var work_gate: u32 = 0;
var work_ready: u32 = 0;
var work_done: u32 = 0;
var work_handle: u32 = 0;
var close_pointer: ?*anyopaque = null;
var prepared = false;
var close_prepared = false;
var cpu_mask: u32 = 0;
var join_target: u64 = 0;

pub fn start(ctx: *const r4os.r4dev.DriverContext) bool {
    if (api != null) return false;
    const service = ctx.threads() orelse return false;
    api = ctx.api;
    threads = service;
    handles = .{0} ** 7;
    for (&ready) |*value| @atomicStore(u32, value, 0, .release);
    @atomicStore(u32, &go, 0, .release);
    @atomicStore(u32, &work_gate, 0, .release);
    @atomicStore(u32, &work_ready, 0, .release);
    @atomicStore(u32, &work_done, 0, .release);
    prepared = false;
    close_prepared = false;
    cpu_mask = 0;
    var before: a.DriverThreadStats = .{};
    if (service.current() != 0 or service.stats(&before) != 0 or before.records != 0 or before.owner_epoch == 0 or before.closing != 0)
        return failed(ctx, "empty-owner");
    var invalid: u64 = 77;
    if (service.start(compute, 0, 0x80000000, &invalid) != a.driver_thread_error_invalid or invalid != 0 or
        service.sleepTicks(0) != a.driver_thread_error_context) return failed(ctx, "admission");

    // Hold the original shared BSP work lane until the dedicated callbacks
    // finish. Their progress must not depend on that worker returning.
    if (ctx.workSubmit(blockWork, 0, 0, &work_handle) != 0 or !awaitReady(ctx, &work_ready)) return failed(ctx, "work-lane");
    for (0..4) |index| {
        const flags: u32 = if (index == 0) 0 else a.driver_thread_flag_parallel;
        if (service.start(compute, index, flags, &handles[index]) != 0) return failed(ctx, "start");
    }
    for (ready[0..4]) |*value| {
        if (!awaitReady(ctx, value)) return failed(ctx, "entry");
    }
    @atomicStore(u32, &go, 1, .release);
    for (0..4) |index| {
        var result: i32 = 0;
        if (service.join(handles[index], timeout(ctx), &result) != 0 or result != 79 + @as(i32, @intCast(index))) return failed(ctx, "compute-join");
        const value = samples[index];
        if (value.handle != handles[index] or value.task_id == 0 or value.task_generation == 0 or value.owner_epoch != before.owner_epoch or value.cpu_index >= 32)
            return failed(ctx, "identity");
        if (index == 0 and value.cpu_index != 0) return failed(ctx, "bsp-placement");
        for (samples[0..index]) |earlier| {
            if (earlier.task_id == value.task_id or earlier.task_generation == value.task_generation) return failed(ctx, "duplicate-task");
        }
        cpu_mask |= @as(u32, 1) << @as(u5, @intCast(value.cpu_index));
        const old = handles[index];
        if (!release(ctx, &handles[index])) return failed(ctx, "retire");
        var stale: a.DriverThreadStatus = .{};
        if (service.status(old, &stale) != a.driver_thread_error_stale) return failed(ctx, "stale");
    }
    if (@popCount(cpu_mask) < 2 or @atomicLoad(u32, &work_done, .acquire) != 0) return failed(ctx, "independent-progress");
    @atomicStore(u32, &work_gate, 1, .release);
    var work_result: i32 = 0;
    if (!finishWork(ctx, &work_result) or work_result != 0) return failed(ctx, "work-complete");

    if (service.start(stopWait, 4, a.driver_thread_flag_parallel, &handles[4]) != 0 or !awaitReady(ctx, &ready[4])) return failed(ctx, "stop-target");
    var result: i32 = 123;
    if (service.release(handles[4]) != a.driver_thread_error_busy or
        service.join(handles[4], 0, &result) != a.driver_thread_error_timeout or result != 0 or
        service.join(handles[4], std.math.maxInt(u64), &result) != a.driver_thread_error_invalid or result != 0) return failed(ctx, "live-handle");
    join_target = handles[4];
    if (service.start(joinWait, 0, a.driver_thread_flag_parallel, &handles[5]) != 0) return failed(ctx, "joiner-start");
    const started = ctx.tickCount();
    while (true) {
        var target: a.DriverThreadStatus = .{};
        if (service.status(handles[4], &target) != 0) return failed(ctx, "join-target");
        if (target.waiters == 1) break;
        if (ctx.tickCount() -% started >= timeout(ctx)) return failed(ctx, "join-enrollment");
        ctx.waitTicks(1);
    }
    if (service.stop(handles[5]) != 0 or service.join(handles[5], timeout(ctx), &result) != 0 or result != 0) return failed(ctx, "join-cancel");
    var target: a.DriverThreadStatus = .{};
    if (service.status(handles[4], &target) != 0 or target.stop_requested != 0 or target.state != a.driver_thread_state_running or target.waiters != 0)
        return failed(ctx, "target-retained");
    if (service.stop(handles[4]) != 0 or service.join(handles[4], timeout(ctx), &result) != 0 or result != 0) return failed(ctx, "target-stop");
    var after: a.DriverThreadStats = .{};
    if (service.stats(&after) != 0 or after.records != 2 or after.active != 0 or after.completed != 2 or after.waiters != 0 or after.pending_creates != 0 or after.pending_releases != 0)
        return failed(ctx, "retained-records");
    var message: [192]u8 = undefined;
    const line = std.fmt.bufPrintZ(&message, "NVIDIA runtime-check: threads=OK callbacks=4 cpu-mask={x} shared-work=blocked heap-clock=verified", .{cpu_mask}) catch unreachable;
    ctx.logInfo(line.ptr);
    ctx.logInfo("NVIDIA runtime-check: thread-waits=OK poll=timeout self-join=rejected join-cancel=target-retained stop=cooperative stale=verified");
    prepared = true;
    return true;
}

pub fn prepareClose(ctx: *const r4os.r4dev.DriverContext) bool {
    const service = threads orelse return false;
    close_pointer = heap.r4nv_heap_allocate(113) orelse return failed(ctx, "close-heap");
    @memset(@as([*]u8, @ptrCast(close_pointer.?))[0..113], 0x79);
    if (service.start(closeWait, 0, a.driver_thread_flag_parallel, &handles[6]) != 0 or !awaitReady(ctx, &ready[6])) return failed(ctx, "close-wait");
    close_prepared = true;
    return true;
}

pub fn shutdown(ctx: *const r4os.r4dev.DriverContext) bool {
    const service = threads orelse return true;
    @atomicStore(u32, &go, 1, .release);
    @atomicStore(u32, &work_gate, 1, .release);
    var correct = true;
    for (handles) |handle| {
        if (handle != 0 and service.stop(handle) != 0) return false;
    }
    for (handles, 0..) |handle, index| {
        if (handle == 0) continue;
        var result: i32 = 0;
        if (service.join(handle, timeout(ctx), &result) != 0) return false;
        if (index >= 4 and result != 0) correct = false;
    }
    var work_result: i32 = 0;
    if (!finishWork(ctx, &work_result)) return false;
    if (work_result != 0) correct = false;
    if (close_pointer) |pointer| {
        heap.r4nv_heap_free(pointer);
        close_pointer = null;
    }
    if (prepared and close_prepared) {
        var snapshot: a.DriverThreadStats = .{};
        if (!correct or ctx.threads() != null or service.stats(&snapshot) != 0 or snapshot.closing != 1 or snapshot.records != 3 or snapshot.completed != 3 or
            snapshot.active != 0 or snapshot.waiters != 0 or snapshot.pending_creates != 0 or snapshot.pending_releases != 0 or heap.releaseFailures() != 0)
        {
            ctx.logError("NVIDIA runtime-check: FAILED phase=thread-close callbacks=quiesced");
        } else ctx.logInfo("NVIDIA runtime-check: thread-close=OK admission=closed callbacks=quiesced records=3 heap-free=verified");
    }
    // Generic R4D cleanup owns the three completed records and exact Tasks.
    // CPU/GPU resource providers stay bound until this function has quiesced.
    threads = null;
    api = null;
    return true;
}

fn compute(index: usize) callconv(.c) i32 {
    const service = threads orelse return -1;
    const ctx = r4os.r4dev.DriverContext.init(api orelse return -1);
    const me = service.current();
    var self_result: i32 = 79;
    if (me == 0 or service.status(me, &samples[index]) != 0 or
        service.join(me, 1, &self_result) != a.driver_thread_error_self_join or self_result != 0 or
        service.release(me) != a.driver_thread_error_self_join) return -2;
    @atomicStore(u32, &ready[index], 1, .release);
    const started = ctx.tickCount();
    while (@atomicLoad(u32, &go, .acquire) == 0) {
        if (ctx.tickCount() -% started >= timeout(&ctx) or service.sleepTicks(1) != 0) return -3;
    }
    const before = clock.r4nv_clock_now_ns();
    if (before == clock.unavailable) return -4;
    var pointers: [16]?*anyopaque = .{null} ** 16;
    defer for (pointers) |pointer| heap.r4nv_heap_free(pointer);
    for (&pointers, 0..) |*pointer, which| {
        pointer.* = heap.r4nv_heap_allocate(which * 73 + 1) orelse return -5;
        if (@intFromPtr(pointer.*.?) & 15 != 0) return -6;
        @memset(@as([*]u8, @ptrCast(pointer.*.?))[0 .. which * 73 + 1], @intCast(index * 17 + which));
    }
    if (service.sleepTicks(1) != 0) return -7;
    const after = clock.r4nv_clock_now_ns();
    if (after == clock.unavailable or after <= before) return -8;
    for (pointers, 0..) |pointer, which| {
        for (@as([*]const u8, @ptrCast(pointer.?))[0 .. which * 73 + 1]) |byte| {
            if (byte != index * 17 + which) return -9;
        }
    }
    return 79 + @as(i32, @intCast(index));
}

fn stopWait(index: usize) callconv(.c) i32 {
    const service = threads orelse return -1;
    @atomicStore(u32, &ready[index], 1, .release);
    return if (service.sleepTicks(std.math.maxInt(u64)) == a.driver_thread_error_cancelled) 0 else -1;
}

fn joinWait(_: usize) callconv(.c) i32 {
    const service = threads orelse return -1;
    const ctx = r4os.r4dev.DriverContext.init(api orelse return -1);
    var result: i32 = 79;
    if (service.join(join_target, timeout(&ctx), &result) != a.driver_thread_error_cancelled or result != 0) return -1;
    var target: a.DriverThreadStatus = .{};
    return if (service.status(join_target, &target) == 0 and target.stop_requested == 0) 0 else -1;
}

fn closeWait(_: usize) callconv(.c) i32 {
    const service = threads orelse return -1;
    @atomicStore(u32, &ready[6], 1, .release);
    if (service.sleepTicks(std.math.maxInt(u64)) != a.driver_thread_error_cancelled) return -1;
    var rejected: u64 = 79;
    if (service.start(compute, 0, 0, &rejected) != a.driver_thread_error_closed or rejected != 0 or heap.r4nv_heap_allocate(1) != null) return -2;
    const pointer = close_pointer orelse return -3;
    for (@as([*]const u8, @ptrCast(pointer))[0..113]) |byte| {
        if (byte != 0x79) return -4;
    }
    heap.r4nv_heap_free(pointer);
    close_pointer = null;
    return if (heap.releaseFailures() == 0) 0 else -5;
}

fn blockWork(_: usize) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api orelse return -1);
    @atomicStore(u32, &work_ready, 1, .release);
    const started = ctx.tickCount();
    while (@atomicLoad(u32, &work_gate, .acquire) == 0) {
        if (ctx.tickCount() -% started >= timeout(&ctx)) {
            @atomicStore(u32, &work_done, 1, .release);
            return -1;
        }
        ctx.waitTicks(1);
    }
    @atomicStore(u32, &work_done, 1, .release);
    return 0;
}

fn timeout(ctx: *const r4os.r4dev.DriverContext) u64 {
    return @as(u64, ctx.timerFrequency()) * 5;
}
fn awaitReady(ctx: *const r4os.r4dev.DriverContext, value: *u32) bool {
    const started = ctx.tickCount();
    while (@atomicLoad(u32, value, .acquire) == 0) {
        if (ctx.tickCount() -% started >= timeout(ctx)) return false;
        ctx.waitTicks(1);
    }
    return true;
}
fn release(ctx: *const r4os.r4dev.DriverContext, handle: *u64) bool {
    const service = threads orelse return false;
    const started = ctx.tickCount();
    while (true) {
        const result = service.release(handle.*);
        if (result == 0) {
            handle.* = 0;
            return true;
        }
        if (result != a.driver_thread_error_busy or ctx.tickCount() -% started >= timeout(ctx)) return false;
        ctx.waitTicks(1);
    }
}
fn finishWork(ctx: *const r4os.r4dev.DriverContext, result: *i32) bool {
    result.* = 0;
    if (work_handle == 0) return true;
    if (ctx.completionWait(work_handle, timeout(ctx), result) != 0 or ctx.completionRelease(work_handle) != 0) return false;
    work_handle = 0;
    return true;
}
fn failed(ctx: *const r4os.r4dev.DriverContext, phase: []const u8) bool {
    var message: [160]u8 = undefined;
    const line = std.fmt.bufPrintZ(&message, "NVIDIA runtime-check: FAILED phase=thread-{s}", .{phase}) catch unreachable;
    ctx.logError(line.ptr);
    return false;
}
