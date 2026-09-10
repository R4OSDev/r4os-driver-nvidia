const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const native = @import("rm_native.zig");
const clock = @import("rm_clock.zig");
const wait = @import("rm_wait.zig");
const State = extern struct { milliseconds: u32 = 0, expected: u32 = 0, returned: u32 = 0, observed: u32 = 0 };
extern fn r4nv_wait_probe_healthy(usize) callconv(.c) i32;
extern fn r4nv_wait_probe_delay(usize) callconv(.c) i32;
fn healthy(value: usize) callconv(.c) i32 {
    return r4nv_wait_probe_healthy(value);
}
fn delay(value: usize) callconv(.c) i32 {
    return r4nv_wait_probe_delay(value);
}
var threads: ?r4os.r4dev.DriverThreadContext = null;
var calls: [2]native.Invocation = undefined;
var handles: [2]u64 = .{ 0, 0 };
var states: [2]State = .{ .{}, .{} };

pub fn start(ctx: *const r4os.r4dev.DriverContext) bool {
    threads = ctx.threads() orelse return failed(ctx, "service");
    if (!native.available()) return failed(ctx, "native");
    const before = wait.stats();
    if (!launch(0, healthy, 10 * std.time.ns_per_s) or !completed(ctx, 0, 0)) return failed(ctx, "healthy");
    const after = wait.stats();
    if (after.sleeps <= before.sleeps or after.spins <= before.spins or after.yields <= before.yields) return failed(ctx, "scheduler");
    // The status flag is computed from the actual blocked Task and its wait
    // queue. A callback's 'about to sleep' boolean cannot prove this race.
    states[0] = .{ .milliseconds = 60000, .expected = 0x64 }; // NV_ERR_SIGNAL_PENDING
    if (!launch(0, delay, 10 * std.time.ns_per_s)) return failed(ctx, "cancel-start");
    const began = ctx.tickCount();
    while (true) {
        var status: a.DriverThreadStatus = .{};
        if (threads.?.status(handles[0], &status) != 0) return failed(ctx, "cancel-status");
        if (status.flags & a.driver_thread_flag_sleeping != 0) break;
        if (ctx.tickCount() -% began >= timeout(ctx)) return failed(ctx, "cancel-enrollment");
        ctx.waitTicks(1);
    }
    if (threads.?.stop(handles[0]) != 0 or !completed(ctx, 0, 0) or @atomicLoad(u32, &states[0].returned, .acquire) != 1)
        return failed(ctx, "cancel-wake");
    // Two concurrent calls retain independent deadlines across scheduling and
    // migration. The healthy call must outlive its peer's expired deadline.
    states[0] = .{ .milliseconds = 60000, .expected = 0x65 }; // NV_ERR_TIMEOUT
    states[1] = .{ .milliseconds = 1500 };
    if (!launch(0, delay, 250 * std.time.ns_per_ms) or !launch(1, delay, 5 * std.time.ns_per_s) or
        !completed(ctx, 0, native.deadline_exceeded) or !completed(ctx, 1, 0) or
        @atomicLoad(u32, &states[0].returned, .acquire) != 1 or @atomicLoad(u32, &states[1].returned, .acquire) != 1)
        return failed(ctx, "independent-deadlines");
    calls[0].deadline_ns = clock.r4nv_clock_now_ns();
    states[0].returned = 0;
    if (native.start(&calls[0], 0, &handles[0]) != native.deadline_exceeded or handles[0] != 0 or states[0].returned != 0)
        return failed(ctx, "expired-admission");
    var tasks: a.DriverThreadStats = .{};
    if (threads.?.stats(&tasks) != 0 or tasks.records != 0 or native.firstFault() != 0 or !clock.available()) return failed(ctx, "cleanup");
    ctx.logInfo("NVIDIA runtime-check: native-waits=OK adapters=5 busy=monotonic sleep=scheduler yield=real duration=4100ms cancel=blocked-task deadlines=independent resources=0");
    return true;
}
fn launch(index: usize, handler: *const fn (usize) callconv(.c) i32, duration: u64) bool {
    if (handles[index] != 0) return false;
    const now = clock.r4nv_clock_now_ns();
    if (now == clock.unavailable) return false;
    calls[index] = .{ .handler = handler, .context = @intFromPtr(&states[index]), .deadline_ns = std.math.add(u64, now, duration) catch return false };
    return native.start(&calls[index], a.driver_thread_flag_parallel, &handles[index]) == 0;
}
fn completed(ctx: *const r4os.r4dev.DriverContext, index: usize, expected: i32) bool {
    var result: i32 = 0;
    var status: a.DriverThreadStatus = .{};
    if (threads.?.join(handles[index], timeout(ctx), &result) != 0 or result != expected or
        threads.?.status(handles[index], &status) != 0 or status.flags & (a.driver_thread_flag_aborted | a.driver_thread_flag_sleeping) != 0) return false;
    return retire(ctx, index);
}
fn retire(ctx: *const r4os.r4dev.DriverContext, index: usize) bool {
    const began = ctx.tickCount();
    while (true) {
        const result = threads.?.release(handles[index]);
        if (result == 0) {
            handles[index] = 0;
            return true;
        }
        if (result != a.driver_thread_error_busy or ctx.tickCount() -% began >= timeout(ctx)) return false;
        ctx.waitTicks(1);
    }
}
pub fn shutdown(ctx: *const r4os.r4dev.DriverContext) bool {
    if (threads == null) return true;
    for (handles) |handle| if (handle != 0) {
        _ = threads.?.stop(handle);
    };
    for (handles, 0..) |handle, index| {
        if (handle == 0) continue;
        var result: i32 = 0;
        if (threads.?.join(handle, timeout(ctx), &result) != 0 or !retire(ctx, index)) return false;
    }
    threads = null;
    return true;
}
fn timeout(ctx: *const r4os.r4dev.DriverContext) u64 {
    return @as(u64, @max(ctx.timerFrequency(), 1)) * 10;
}
fn failed(ctx: *const r4os.r4dev.DriverContext, phase: []const u8) bool {
    var message: [160]u8 = undefined;
    const line = std.fmt.bufPrintZ(&message, "NVIDIA runtime-check: FAILED phase=wait-{s}", .{phase}) catch unreachable;
    ctx.logError(line.ptr);
    return false;
}
