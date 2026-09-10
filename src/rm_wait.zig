const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const clock = @import("rm_clock.zig");
const native = @import("rm_native.zig");
const semaphore = @import("rm_semaphore.zig");
const policy = @import("wait_policy.zig");
const Result = policy.Result;
var context: ?r4os.r4dev.DriverContext = null;
var threads: ?r4os.r4dev.DriverThreadContext = null;
var sleep_calls: u64 = 0;
var spin_calls: u64 = 0;
var yield_calls: u64 = 0;
pub const Stats = struct { sleeps: u64, spins: u64, yields: u64 };
pub fn stats() Stats {
    return .{ .sleeps = @atomicLoad(u64, &sleep_calls, .monotonic), .spins = @atomicLoad(u64, &spin_calls, .monotonic), .yields = @atomicLoad(u64, &yield_calls, .monotonic) };
}
pub fn bind(ctx: *const r4os.r4dev.DriverContext) void {
    context = ctx.*;
    threads = ctx.threads();
    @atomicStore(u64, &sleep_calls, 0, .monotonic);
    @atomicStore(u64, &spin_calls, 0, .monotonic);
    @atomicStore(u64, &yield_calls, 0, .monotonic);
}
pub fn unbind() void {
    // All native callbacks and legacy work must have quiesced first.
    context = null;
    threads = null;
}
const Ops = struct {
    handle: u64,
    spins: u64 = 0,
    pub fn now(_: *Ops) u64 {
        return clock.r4nv_clock_now_ns();
    }
    pub fn checkStop(self: *Ops) Result {
        if (self.handle == 0) return .ok;
        var status: a.DriverThreadStatus = .{};
        if (threads.?.status(self.handle, &status) != 0) return .context;
        return if (status.stop_requested != 0) .cancelled else .ok;
    }
    pub fn sleepTicks(self: *Ops, ticks: u64) Result {
        _ = @atomicRmw(u64, if (ticks == 0) &yield_calls else &sleep_calls, .Add, 1, .monotonic);
        if (self.handle != 0) return switch (threads.?.sleepTicks(ticks)) {
            0 => .ok,
            a.driver_thread_error_cancelled => .cancelled,
            else => .context,
        };
        // Init/work callbacks can sleep too. Their legacy void provider has
        // no stop result; the policy still verifies the actual clock on wake.
        // That ABI explicitly makes waitTicks(0) a no-op, not a yield.
        if (ticks == 0) return .context;
        context.?.waitTicks(ticks);
        return .ok;
    }
    pub fn relax(self: *Ops) void {
        self.spins +|= 1;
        std.atomic.spinLoopHint();
    }
};
fn finish(result: Result) i32 {
    if (result == .clock) clock.invalidate();
    return @intFromEnum(result);
}
pub export fn r4nv_wait_ns(nanoseconds: u64, mode_raw: u32) callconv(.c) i32 {
    const mode: policy.Mode = switch (mode_raw) {
        0 => .busy,
        1 => .adaptive,
        2 => .sleep,
        else => return finish(.invalid),
    };
    const ctx = context orelse return finish(.context);
    const source = clock.snapshot() orelse return finish(.clock);
    const flags = semaphore.r4nv_semaphore_context_flags();
    const irq = flags & semaphore.irq != 0;
    const invocation = if (irq) null else native.currentInvocation();
    var ops: Ops = .{ .handle = if (!irq and threads != null) threads.?.current() else 0 };
    const result = policy.run(.{
        .duration_ns = nanoseconds,
        .deadline_ns = if (invocation) |call| call.deadline_ns else 0,
        .mode = mode,
        .frequency_hz = ctx.timerFrequency(),
        .sleepable = flags & semaphore.sleepable != 0,
        .irq = irq,
        .free_running = source.source != a.monotonic_clock_source_periodic_event,
    }, &ops);
    _ = @atomicRmw(u64, &spin_calls, .Add, ops.spins, .monotonic);
    return finish(result);
}
pub export fn r4nv_schedule(ticks: u64) callconv(.c) i32 {
    const ctx = context orelse return finish(.context);
    if (ticks > 1) return finish(.invalid);
    if (ticks == 1) {
        const hz = ctx.timerFrequency();
        if (hz == 0) return finish(.clock);
        return r4nv_wait_ns((std.time.ns_per_s + @as(u64, hz) - 1) / hz, @intFromEnum(policy.Mode.sleep));
    }
    if (semaphore.r4nv_semaphore_context_flags() & semaphore.sleepable == 0) return finish(.context);
    const invocation = native.currentInvocation();
    const deadline = if (invocation) |call| call.deadline_ns else 0;
    var ops: Ops = .{ .handle = if (threads) |service| service.current() else 0 };
    const before = ops.now();
    if (before == clock.unavailable) return finish(.clock);
    if (deadline != 0 and before >= deadline) return finish(.deadline);
    const result = ops.sleepTicks(0);
    if (result != .ok) return finish(result);
    const after = ops.now();
    if (after == clock.unavailable or after < before) return finish(.clock);
    return finish(if (deadline != 0 and after >= deadline) .deadline else .ok);
}
