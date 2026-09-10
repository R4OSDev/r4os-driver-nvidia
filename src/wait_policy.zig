const std = @import("std");
pub const Result = enum(i32) { ok = 0, invalid = 1, context = 2, cancelled = 3, deadline = 4, clock = 5 };
pub const Mode = enum(u32) { busy = 0, adaptive = 1, sleep = 2 };
pub const Options = struct {
    duration_ns: u64,
    deadline_ns: u64 = 0,
    mode: Mode,
    frequency_hz: u32,
    sleepable: bool,
    irq: bool = false,
    free_running: bool = true,
    // An instruction-count backstop detects a stopped clock. It is not a
    // calibrated elapsed-time estimate and never authorizes early success.
    stalled_read_limit: u32 = 1024 * 1024,
};
const unavailable = std.math.maxInt(u64);
const ns_per_s = std.time.ns_per_s;

pub fn run(options: Options, ops: anytype) Result {
    if (options.mode == .sleep and !options.sleepable) return .context;
    if (options.irq and options.duration_ns > 20 * std.time.ns_per_ms) return .context;
    var now = ops.now();
    if (now == unavailable) return .clock;
    if (options.deadline_ns != 0 and now >= options.deadline_ns) return .deadline;
    const end = std.math.add(u64, now, options.duration_ns) catch return .invalid;
    if (end == unavailable) return .invalid;
    const limit = if (options.deadline_ns == 0) end else @min(end, options.deadline_ns);
    const may_sleep = options.mode != .busy and options.sleepable;
    if (may_sleep and options.frequency_hz == 0) return .clock;
    if (now < limit and !options.sleepable and !options.free_running) return .clock;
    var stalled: u32 = 0;
    var polls: u64 = 0;
    while (now < limit) {
        if (polls & 4095 == 0 and !options.irq) {
            const stop = ops.checkStop();
            if (stop != .ok) return stop;
        }
        const remaining = limit - now;
        const ticks: u64 = if (may_sleep) @intCast(@min(@as(u128, remaining) * options.frequency_hz / ns_per_s, unavailable - 1)) else 0;
        if (ticks != 0) {
            const slept = ops.sleepTicks(ticks);
            if (slept != .ok) return slept;
        } else ops.relax();
        const next = ops.now();
        if (next == unavailable or next < now) return .clock;
        if (next == now) {
            if (stalled >= options.stalled_read_limit) return .clock;
            stalled += 1;
        } else stalled = 0;
        now = next;
        polls +%= 1;
    }
    return if (options.deadline_ns != 0 and now >= options.deadline_ns) .deadline else .ok;
}

const Fixture = struct {
    instant: u64 = 0,
    read_step: u64 = 5000,
    sleep_step: u64 = 500000,
    sleep_to: ?u64 = null,
    sleeps: u32 = 0,
    spins: u32 = 0,
    last_ticks: u64 = 0,
    stop: Result = .ok,
    sleep_result: Result = .ok,
    fn now(self: *Fixture) u64 {
        const value = self.instant;
        self.instant +|= self.read_step;
        return value;
    }
    fn checkStop(self: *Fixture) Result {
        return self.stop;
    }
    fn sleepTicks(self: *Fixture, ticks: u64) Result {
        self.sleeps += 1;
        self.last_ticks = ticks;
        self.instant = self.sleep_to orelse self.instant +| (ticks *| self.sleep_step);
        return self.sleep_result;
    }
    fn relax(self: *Fixture) void {
        self.spins += 1;
    }
};
test "NVIDIA wait policy checks actual monotonic time after early scheduler wakeups" {
    var fixture: Fixture = .{};
    try std.testing.expectEqual(Result.ok, run(.{ .duration_ns = 3100000, .mode = .adaptive, .frequency_hz = 1000, .sleepable = true }, &fixture));
    try std.testing.expect(fixture.instant >= 3100000 and fixture.sleeps >= 2 and fixture.spins != 0);
    fixture = .{};
    try std.testing.expectEqual(Result.ok, run(.{ .duration_ns = 3100000, .mode = .busy, .frequency_hz = 1000, .sleepable = true }, &fixture));
    try std.testing.expect(fixture.instant >= 3100000 and fixture.sleeps == 0 and fixture.spins != 0);
}
test "NVIDIA wait policy preserves deadline and cooperative cancellation outcomes" {
    var fixture: Fixture = .{};
    try std.testing.expectEqual(Result.deadline, run(.{ .duration_ns = 10000000, .deadline_ns = 800000, .mode = .adaptive, .frequency_hz = 1000, .sleepable = true }, &fixture));
    try std.testing.expect(fixture.instant >= 800000 and fixture.instant < 10000000);
    fixture = .{ .sleep_result = .cancelled, .sleep_step = 0 };
    try std.testing.expectEqual(Result.cancelled, run(.{ .duration_ns = 10000000, .mode = .adaptive, .frequency_hz = 1000, .sleepable = true }, &fixture));
    try std.testing.expectEqual(@as(u32, 1), fixture.sleeps);
    fixture = .{ .stop = .cancelled };
    try std.testing.expectEqual(Result.cancelled, run(.{ .duration_ns = 10000, .mode = .busy, .frequency_hz = 1000, .sleepable = true }, &fixture));
    try std.testing.expectEqual(@as(u32, 0), fixture.spins);
}
test "NVIDIA wait policy rejects stopped clocks, unusable contexts and overflow without inventing time" {
    var fixture: Fixture = .{ .read_step = 0 };
    const busy: Options = .{ .duration_ns = 1, .mode = .busy, .frequency_hz = 1000, .sleepable = false, .stalled_read_limit = 8 };
    try std.testing.expectEqual(Result.clock, run(busy, &fixture));
    try std.testing.expectEqual(@as(u32, 9), fixture.spins);
    fixture = .{ .instant = unavailable };
    try std.testing.expectEqual(Result.clock, run(busy, &fixture));
    fixture = .{ .instant = 10000, .read_step = 0, .sleep_to = 5000 };
    try std.testing.expectEqual(Result.clock, run(.{ .duration_ns = 10000000, .mode = .sleep, .frequency_hz = 1000, .sleepable = true }, &fixture));
    fixture = .{ .instant = unavailable - 2 };
    var overflow = busy;
    overflow.duration_ns = 3;
    try std.testing.expectEqual(Result.invalid, run(overflow, &fixture));
    fixture = .{};
    var unsuitable = busy;
    unsuitable.free_running = false;
    try std.testing.expectEqual(Result.clock, run(unsuitable, &fixture));
    unsuitable = busy;
    unsuitable.mode = .sleep;
    try std.testing.expectEqual(Result.context, run(unsuitable, &fixture));
    unsuitable = busy;
    unsuitable.irq = true;
    unsuitable.duration_ns = 20000001;
    try std.testing.expectEqual(Result.context, run(unsuitable, &fixture));
}
test "NVIDIA wait conversion preserves large intervals and never emits WAIT_FOREVER" {
    const duration: u64 = 0x8000000000000100;
    var fixture: Fixture = .{ .read_step = 0, .sleep_to = duration };
    try std.testing.expectEqual(Result.ok, run(.{ .duration_ns = duration, .mode = .adaptive, .frequency_hz = std.math.maxInt(u32), .sleepable = true }, &fixture));
    try std.testing.expectEqual(unavailable - 1, fixture.last_ticks);
    try std.testing.expectEqual(@as(u32, 1), fixture.sleeps);
}
