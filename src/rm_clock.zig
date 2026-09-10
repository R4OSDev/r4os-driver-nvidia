const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;

// Bound before publishing callbacks; cleared only after their quiescence.
// The source owns monotonic publication across CPUs and source transitions.
// Do not derive nanoseconds or hardware resolution from timerFrequency().
var context: ?r4os.r4dev.DriverContext = null;
var fast_clock: ?r4os.r4dev.DriverResourceContext = null;
var failed: u32 = 0;
pub const unavailable = std.math.maxInt(u64);

pub fn bind(ctx: *const r4os.r4dev.DriverContext) void {
    context = ctx.*;
    fast_clock = ctx.resources();
    @atomicStore(u32, &failed, 0, .release);
    _ = snapshot();
    _ = r4nv_clock_now_ns();
}

pub fn unbind() void {
    context = null;
    fast_clock = null;
    @atomicStore(u32, &failed, 1, .release);
}

pub fn available() bool {
    return context != null and @atomicLoad(u32, &failed, .acquire) == 0;
}
pub fn invalidate() void {
    @atomicStore(u32, &failed, 1, .release);
}

pub fn snapshot() ?a.MonotonicClockInfo {
    const ctx = context orelse return null;
    if (@atomicLoad(u32, &failed, .acquire) != 0) return null;
    var output: a.MonotonicClockInfo = .{};
    const required = a.monotonic_clock_flag_valid | a.monotonic_clock_flag_continuous;
    if (ctx.monotonicClock(&output) <= 0 or output.version != 1 or output.size != @sizeOf(a.MonotonicClockInfo) or
        output.flags & required != required or output.frequency_hz != a.monotonic_clock_frequency_hz or
        output.resolution_ns == 0 or output.resolution_ns == unavailable or output.instant_ns == unavailable or
        output.source == a.monotonic_clock_source_unavailable)
    {
        @atomicStore(u32, &failed, 1, .release);
        return null;
    }
    return output;
}

// Private C imports for the still-separate RM/NVKMS partial links. UINT64_MAX
// is an invalid reading, never an invented zero or a divided error value.
// Loss of the clock latches ordinary admission closed until a new bind. Native
// dispatch checks this fault before and after its deadline-bound callback;
// these value-only upstream callbacks cannot unwind arbitrary RM loops.
pub export fn r4nv_clock_now_ns() callconv(.c) u64 {
    if (!available()) return unavailable;
    // The loaded-resource service already exposes the canonical raw clock.
    // Cache that read-only function during init; hot timestamp reads neither
    // acquire the resource/lifecycle owner nor recompute the 80-byte metadata.
    const now = if (fast_clock) |clock| clock.nowNs() else unavailable;
    if (now == unavailable) @atomicStore(u32, &failed, 1, .release);
    return now;
}

pub export fn r4nv_clock_resolution_ns() callconv(.c) u64 {
    return if (snapshot()) |value| value.resolution_ns else unavailable;
}
