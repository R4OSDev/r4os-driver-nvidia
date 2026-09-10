const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const provider = @import("rm_heap.zig");
const clock_provider = @import("rm_clock.zig");

// Explicit CPU-only diagnostic. No ordinary driver start allocates these
// buffers or submits these callbacks. If the same image is reused, retained
// identities also check real owner retirement and stale handles at restart.
var api: ?*const a.DriverApi = null;
var work: u32 = 0;
var close_work: u32 = 0;
var close_ready: u32 = 0;
var closing_pointer: ?*anyopaque = null;
var prepared = false;
var previous_epoch: u64 = 0;
var previous_handle: u64 = 0;

pub fn start(ctx: *const r4os.r4dev.DriverContext) bool {
    if (api != null or !provider.available() or !clock_provider.available()) return false;
    api = ctx.api;
    prepared = false;
    @atomicStore(u32, &close_ready, 0, .release);
    const heap = ctx.heap() orelse return false;
    var before: a.DriverHeapStats = .{};
    if (heap.stats(&before) != 0 or before.owner_epoch == 0 or before.closing != 0 or before.allocations != 0 or before.pending_creates != 0 or before.pending_releases != 0) return false;
    if (previous_epoch != 0) {
        if (before.owner_epoch <= previous_epoch or heap.release(previous_handle) != a.driver_heap_error_stale) return false;
        ctx.logInfo("NVIDIA runtime-check: restart=OK old-handle=stale live=0");
    }
    var invalid: a.DriverHeapAllocation = .{};
    if (heap.allocate(1, 3, &invalid) != a.driver_heap_error_invalid or invalid.handle != 0 or
        heap.allocate(std.math.maxInt(u64), 16, &invalid) != a.driver_heap_error_overflow or invalid.handle != 0 or
        provider.r4nv_heap_allocate(std.math.maxInt(u64)) != null) return false;

    if (ctx.workSubmit(runWorker, 2, 0, &work) != 0) return false;
    if (!exercise(1)) return false;
    var worker_result: i32 = 0;
    if (!finishWork(ctx, &work, &worker_result) or worker_result != 0) return false;
    var after: a.DriverHeapStats = .{};
    if (heap.stats(&after) != 0 or after.allocations != 0 or after.bytes != 0 or after.pending_creates != 0 or after.pending_releases != 0 or provider.releaseFailures() != 0) return false;
    ctx.logInfo("NVIDIA runtime-check: memory=OK init=64 worker=64 alignment=16 content=verified live=0");
    ctx.logInfo("NVIDIA runtime-check: clock=OK init=64 worker=64 monotonic-ns=verified");
    ctx.logInfo("NVIDIA runtime-check: native-c=OK adapters=21 contexts=init,worker providers=driver-api link=actual");

    var page: a.DriverHeapAllocation = .{};
    if (heap.allocate(4096, 4096, &page) != 0 or page.cpu_address & 4095 != 0) return false;
    @memset(@as([*]u8, @ptrFromInt(page.cpu_address))[0..4096], 0x7a);
    previous_epoch = before.owner_epoch;
    previous_handle = page.handle;
    // These two allocations are intentionally left for generic owner cleanup:
    // 4096 raw CPU bytes plus 73 C payload bytes and its 16-byte handle prefix.
    const leftover = provider.r4nv_heap_allocate(73) orelse return false;
    @memset(@as([*]u8, @ptrCast(leftover))[0..73], 0x79);
    closing_pointer = provider.r4nv_heap_allocate(257) orelse return false;
    if (ctx.workSubmit(closeWorker, 0, 0, &close_work) != 0) return false;
    const started = ctx.tickCount();
    const limit = timeout(ctx) orelse return false;
    while (@atomicLoad(u32, &close_ready, .acquire) == 0) {
        const elapsed = ctx.tickCount() -% started;
        if (elapsed >= limit) return false;
        ctx.waitTicks(1);
    }
    prepared = true;
    return true;
}

pub fn shutdown(ctx: *const r4os.r4dev.DriverContext) bool {
    if (api == null) return true;
    var worker_result: i32 = 0;
    var close_result: i32 = 0;
    if (!finishWork(ctx, &work, &worker_result) or !finishWork(ctx, &close_work, &close_result)) return false;
    if (closing_pointer) |pointer| {
        provider.r4nv_heap_free(pointer);
        closing_pointer = null;
    }
    if (prepared) {
        const heap = ctx.heap();
        // New queries are closed. The provider and worker used their cached
        // table for free; the explicit table below proves existing stats work.
        const cached = r4os.r4dev.DriverHeapContext{ .table = heap_table };
        var snapshot: a.DriverHeapStats = .{};
        if (heap != null or provider.releaseFailures() != 0 or worker_result != 0 or close_result != 0 or
            cached.stats(&snapshot) != 0 or snapshot.closing != 1 or snapshot.allocations != 2 or snapshot.bytes != 4185 or snapshot.pending_creates != 0 or snapshot.pending_releases != 0)
        {
            // A failed CPU assertion is a diagnostic failure. Once callbacks
            // are actually quiesced it must not block safe generic cleanup.
            ctx.logError("NVIDIA runtime-check: FAILED phase=close workers=quiesced");
        } else ctx.logInfo("NVIDIA runtime-check: shutdown=OK admission=closed live=2 bytes=4185 workers=quiesced");
    }
    api = null;
    prepared = false;
    return true;
}

var heap_table: a.DriverHeapApi = .{};
extern fn r4nv_cpu_probe(seed: u32) callconv(.c) i32;

fn runWorker(seed: usize) callconv(.c) i32 {
    return if (exercise(@intCast(seed))) 0 else -1;
}

fn exercise(seed: u8) bool {
    const ctx = r4os.r4dev.DriverContext.init(api orelse return false);
    const native_result = r4nv_cpu_probe(seed);
    if (native_result != 0) {
        var buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrintZ(&buffer, "NVIDIA runtime-check: FAILED phase=native-c line={d} seed={d}", .{ native_result, seed }) catch unreachable;
        ctx.logError(message.ptr);
        return false;
    }
    if (!exerciseClock(&ctx)) return false;
    var pointers: [64]?*anyopaque = .{null} ** 64;
    defer for (&pointers) |*pointer| {
        provider.r4nv_heap_free(pointer.*);
        pointer.* = null;
    };
    for (&pointers, 0..) |*pointer, index| {
        const bytes = index * 37 + 1;
        pointer.* = provider.r4nv_heap_allocate(bytes) orelse return false;
        if (@intFromPtr(pointer.*.?) & 15 != 0) return false;
        @memset(@as([*]u8, @ptrCast(pointer.*.?))[0..bytes], seed +% @as(u8, @intCast(index)));
    }
    // A coprime permutation frees in an order distinct from allocation order.
    for (0..pointers.len) |iteration| {
        const index = (iteration * 13) % pointers.len;
        const data: [*]const u8 = @ptrCast(pointers[index].?);
        for (data[0 .. index * 37 + 1]) |value| {
            if (value != seed +% @as(u8, @intCast(index))) return false;
        }
        provider.r4nv_heap_free(pointers[index]);
        pointers[index] = null;
    }
    return true;
}

fn exerciseClock(ctx: *const r4os.r4dev.DriverContext) bool {
    const before = clock_provider.snapshot() orelse return false;
    var previous = before.instant_ns;
    for (0..64) |_| {
        const now = clock_provider.r4nv_clock_now_ns();
        if (now == clock_provider.unavailable or now < previous) return false;
        previous = now;
    }
    const resolution = clock_provider.r4nv_clock_resolution_ns();
    if (resolution == 0 or resolution == clock_provider.unavailable) return false;
    ctx.waitTicks(1);
    const after = clock_provider.snapshot() orelse return false;
    if (after.instant_ns <= previous or after.instant_ns <= before.instant_ns) return false;
    if (before.generation == after.generation and (before.resolution_ns != resolution or after.resolution_ns != resolution)) return false;
    return true;
}

fn closeWorker(_: usize) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api orelse return -1);
    const heap = ctx.heap() orelse return -1;
    heap_table = heap.table;
    @atomicStore(u32, &close_ready, 1, .release);
    const started = ctx.tickCount();
    const limit = timeout(&ctx) orelse return -1;
    while (true) {
        var snapshot: a.DriverHeapStats = .{};
        if (heap.stats(&snapshot) != 0) return -1;
        if (snapshot.closing != 0) break;
        if (ctx.tickCount() -% started >= limit) return -1;
        ctx.waitTicks(1);
    }
    var rejected: a.DriverHeapAllocation = .{};
    if (heap.allocate(17, 16, &rejected) != a.driver_heap_error_closed or rejected.handle != 0 or provider.r4nv_heap_allocate(17) != null) return -1;
    provider.r4nv_heap_free(closing_pointer);
    closing_pointer = null;
    return if (provider.releaseFailures() == 0) 0 else -1;
}

fn timeout(ctx: *const r4os.r4dev.DriverContext) ?u64 {
    const hz = ctx.timerFrequency();
    return if (hz == 0) null else @as(u64, hz) * 5;
}

fn finishWork(ctx: *const r4os.r4dev.DriverContext, handle: *u32, result: *i32) bool {
    if (handle.* == 0) return true;
    const limit = timeout(ctx) orelse return false;
    if (ctx.completionWait(handle.*, limit, result) != 0) return false;
    if (ctx.completionRelease(handle.*) != 0) return false;
    handle.* = 0;
    return true;
}
