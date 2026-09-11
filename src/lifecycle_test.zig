const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const driver = @import("main.zig");
const t = std.testing;
const resource_loader = @import("firmware_resources.zig");
const firmware = @import("firmware.zig");
const cpu_provider = @import("rm_heap.zig");
const clock_provider = @import("rm_clock.zig");
const sem_provider = @import("rm_semaphore.zig");
const vbios = @import("vbios.zig");
const vbios_probe = @import("vbios_probe.zig");
const fixtures = @import("tests.zig");
const log_provider = @import("rm_log.zig");
const preflight = @import("fwsec_state.zig");
extern fn r4nv_format_probe(u32) callconv(.c) i32;
extern fn nv_printf(u32, [*:0]const u8, ...) callconv(.c) c_int;
var native_log_text: [513]u8 = undefined;
var native_log_length: usize = 0;
var native_log_severity: u32 = 0;
fn nativeLogInfo(text: [*:0]const u8) callconv(.c) void {
    captureNativeLog(0, text);
}
fn nativeLogWarn(text: [*:0]const u8) callconv(.c) void {
    captureNativeLog(1, text);
}
fn nativeLogError(text: [*:0]const u8) callconv(.c) void {
    captureNativeLog(2, text);
}
fn captureNativeLog(level: u32, text: [*:0]const u8) void {
    const value = std.mem.span(text);
    std.debug.assert(value.len <= 512);
    @memcpy(native_log_text[0..value.len], value);
    native_log_text[value.len] = 0;
    native_log_length = value.len;
    native_log_severity = level;
}
test "NVIDIA actual driver lifecycle formats original C arguments and binds bounded native logs through shutdown" {
    var api = apiTable();
    state = .{ .present = false };
    try t.expectEqual(@as(i32, -4), driver.nvidia_init(&api));
    defer _ = driver.nvidia_shutdown();
    api.log_info = nativeLogInfo;
    api.log_warn = nativeLogWarn;
    api.log_error = nativeLogError;
    try t.expectEqual(@as(i32, 0), r4nv_format_probe(7));
    try t.expectEqual(@as(u64, 4), log_provider.recordCount());
    try t.expectEqual(@as(u32, 1), native_log_severity);
    try t.expectEqualStrings("NVIDIA modeset: GPU-check: native-log-check severity=warning", native_log_text[0..native_log_length]);
    const before = log_provider.recordCount();
    try t.expectEqual(@as(i32, -1), log_provider.r4nv_log(3, "invalid"));
    try t.expectEqual(@as(i32, -1), log_provider.r4nv_log(0, null));
    try t.expectEqual(before, log_provider.recordCount());
    var oversized: [600:0]u8 = @splat('x');
    oversized[600] = 0;
    try t.expectEqual(@as(i32, 512), log_provider.r4nv_log(2, &oversized));
    try t.expectEqual(@as(u32, 2), native_log_severity);
    try t.expectEqual(@as(usize, 512), native_log_length);
    try t.expect(std.mem.endsWith(u8, native_log_text[0..native_log_length], " [truncated]"));
    try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
    const closed = log_provider.recordCount();
    try t.expectEqual(@as(i32, -1), log_provider.r4nv_log(0, "closed"));
    try t.expectEqual(@as(c_int, -1), nv_printf(4, "closed: %llu", @as(c_ulonglong, 79)));
    try t.expectEqual(closed, log_provider.recordCount());
}
var prom_bytes: [vbios.max_rom_bytes]u8 align(16) = .{0} ** vbios.max_rom_bytes;

const SemFixture = struct {
    live: bool = false,
    closed: bool = false,
    flags: u32 = a.driver_semaphore_context_sleepable,
    count: u32 = 0,
    deadline: u64 = 0,
    create_result: i32 = 0,
    destroy_result: i32 = 0,
    release_result: i32 = 0,
    destroys: u32 = 0,
};
var sem_fixture: SemFixture = .{};
const sem_handle: u64 = 0xf000000100000079;
fn semQuery(output: *a.DriverSemaphoreApi) callconv(.c) i32 {
    if (sem_fixture.closed) return a.driver_semaphore_error_closed;
    output.* = .{ .create = @intFromPtr(&semCreate), .acquire = @intFromPtr(&semAcquire), .release = @intFromPtr(&semRelease), .destroy = @intFromPtr(&semDestroy), .context_flags = @intFromPtr(&semFlags) };
    return 0;
}
fn semCreate(initial: u32, maximum: u32, out: *u64) callconv(.c) i32 {
    std.debug.assert(maximum == std.math.maxInt(u32) and out.* == 0 and !sem_fixture.live);
    if (sem_fixture.closed) return a.driver_semaphore_error_closed;
    if (sem_fixture.create_result != 0) return sem_fixture.create_result;
    sem_fixture.live = true;
    sem_fixture.count = initial;
    out.* = sem_handle;
    return 0;
}
fn semAcquire(handle: u64, ticks: u64) callconv(.c) i32 {
    std.debug.assert(handle == sem_handle and sem_fixture.live);
    sem_fixture.deadline = ticks;
    if (ticks != 0 and sem_fixture.flags & a.driver_semaphore_context_sleepable == 0) return a.driver_semaphore_error_context;
    if (sem_fixture.count == 0) return a.driver_semaphore_error_timeout;
    sem_fixture.count -= 1;
    return 0;
}
fn semRelease(handle: u64) callconv(.c) i32 {
    std.debug.assert(handle == sem_handle and sem_fixture.live);
    if (sem_fixture.release_result != 0) return sem_fixture.release_result;
    if (sem_fixture.count == std.math.maxInt(u32)) return a.driver_semaphore_error_overflow;
    sem_fixture.count += 1;
    return 0;
}
fn semDestroy(handle: u64) callconv(.c) i32 {
    std.debug.assert(handle == sem_handle and sem_fixture.live);
    sem_fixture.destroys += 1;
    if (sem_fixture.destroy_result != 0) return sem_fixture.destroy_result;
    sem_fixture.live = false;
    return 0;
}
fn semFlags() callconv(.c) u32 {
    return sem_fixture.flags;
}
fn semaphoreApi() a.DriverApi {
    var api = apiTable();
    api.version = 33;
    api.heap_query = cpuQuery;
    api.semaphore_query = semQuery;
    state = .{ .present = false };
    cpu_closed = false;
    cpu_fail_release = false;
    sem_fixture = .{};
    return api;
}

test "NVIDIA actual driver lifecycle bridges opaque semaphores and preserves close context and integer widths" {
    var api = semaphoreApi();
    try t.expectEqual(@as(i32, -4), driver.nvidia_init(&api));
    defer _ = driver.nvidia_shutdown();
    try t.expect(sem_provider.available());
    const pointer = sem_provider.r4nv_semaphore_create(std.math.maxInt(u32)) orelse return error.SemaphoreAllocation;
    try t.expectEqual(@as(u64, 32), cpu_requested);
    try t.expectEqual(@as(usize, 0), @intFromPtr(pointer) & 15);
    try t.expectEqual(std.math.maxInt(u32), sem_fixture.count);
    try t.expectEqual(sem_provider.ok, sem_provider.r4nv_semaphore_acquire(pointer, std.math.maxInt(u64)));
    try t.expectEqual(std.math.maxInt(u64), sem_fixture.deadline);
    sem_fixture.count = 0;
    try t.expectEqual(sem_provider.retry, sem_provider.r4nv_semaphore_acquire(pointer, 0x100000007));
    try t.expectEqual(@as(u64, 0x100000007), sem_fixture.deadline);
    sem_fixture.flags = a.driver_semaphore_context_irq;
    try t.expectEqual(sem_provider.irq, sem_provider.r4nv_semaphore_context_flags());
    try t.expectEqual(sem_provider.invalid_context, sem_provider.r4nv_semaphore_acquire(pointer, 1));
    try t.expectEqual(sem_provider.ok, sem_provider.r4nv_semaphore_release(pointer));
    try t.expectEqual(sem_provider.ok, sem_provider.r4nv_semaphore_acquire(pointer, 0));
    try t.expectEqual(sem_provider.retry, sem_provider.r4nv_semaphore_acquire(pointer, 0));
    sem_fixture.flags = a.driver_semaphore_context_sleepable;
    try t.expectEqual(sem_provider.sleepable, sem_provider.r4nv_semaphore_context_flags());
    sem_fixture.closed = true;
    cpu_closed = true;
    const ctx = r4os.r4dev.DriverContext.init(&api);
    try t.expect(ctx.semaphores() == null and sem_provider.r4nv_semaphore_create(1) == null);
    try t.expectEqual(sem_provider.ok, sem_provider.r4nv_semaphore_release(pointer));
    try t.expectEqual(sem_provider.ok, sem_provider.r4nv_semaphore_acquire(pointer, std.math.maxInt(u64)));
    try t.expectEqual(sem_provider.ok, sem_provider.r4nv_semaphore_free(pointer));
    try t.expect(cpu_backing == null and !sem_fixture.live and sem_provider.faultCount() == 0);
    try t.expectEqual(sem_provider.ok, sem_provider.r4nv_semaphore_free(null));
    try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
    try t.expect(!sem_provider.available() and sem_provider.r4nv_semaphore_context_flags() == 0);
    api.version = 32;
    api.size = @offsetOf(a.DriverApi, "semaphore_query");
    sem_provider.bind(&ctx);
    try t.expect(!sem_provider.available());
    sem_provider.unbind();
}

test "NVIDIA actual driver lifecycle retains independent semaphore and CPU free failures" {
    var api = semaphoreApi();
    try t.expectEqual(@as(i32, -4), driver.nvidia_init(&api));
    defer _ = driver.nvidia_shutdown();
    sem_fixture.create_result = a.driver_semaphore_error_memory;
    try t.expect(sem_provider.r4nv_semaphore_create(1) == null and cpu_backing == null and !sem_fixture.live);
    sem_fixture.create_result = 0;
    sem_fixture.flags = 0;
    const calls = cpu_calls;
    try t.expect(sem_provider.r4nv_semaphore_create(1) == null and calls == cpu_calls);
    sem_fixture.flags = a.driver_semaphore_context_sleepable;
    const pointer = sem_provider.r4nv_semaphore_create(0) orelse return error.SemaphoreAllocation;
    sem_fixture.destroy_result = a.driver_semaphore_error_busy;
    try t.expectEqual(sem_provider.retry, sem_provider.r4nv_semaphore_free(pointer));
    try t.expect(sem_fixture.live and cpu_backing != null and sem_provider.available());
    sem_fixture.destroy_result = a.driver_semaphore_error_release;
    try t.expectEqual(sem_provider.invalid, sem_provider.r4nv_semaphore_free(pointer));
    try t.expect(sem_fixture.live and cpu_backing != null and !sem_provider.available());
    sem_fixture.destroy_result = 0;
    cpu_fail_release = true;
    try t.expectEqual(sem_provider.invalid, sem_provider.r4nv_semaphore_free(pointer));
    try t.expect(!sem_fixture.live and cpu_backing != null and sem_fixture.destroys == 3);
    cpu_fail_release = false;
    try t.expectEqual(sem_provider.ok, sem_provider.r4nv_semaphore_free(pointer));
    try t.expect(cpu_backing == null and sem_fixture.destroys == 3 and cpu_provider.releaseFailures() == 1 and sem_provider.faultCount() == 2);
    try t.expect(sem_provider.r4nv_semaphore_create(1) == null);
    const ctx = r4os.r4dev.DriverContext.init(&api);
    sem_provider.bind(&ctx);
    const another = sem_provider.r4nv_semaphore_create(1) orelse return error.SemaphoreAllocation;
    sem_fixture.release_result = a.driver_semaphore_error_overflow;
    try t.expectEqual(sem_provider.invalid, sem_provider.r4nv_semaphore_release(another));
    try t.expect(sem_fixture.count == 1 and sem_fixture.live and !sem_provider.available());
    try t.expectEqual(sem_provider.ok, sem_provider.r4nv_semaphore_free(another));
    try t.expect(cpu_backing == null and !sem_fixture.live);
}

var clock_value: a.MonotonicClockInfo = .{};
var clock_result: i32 = 1;
fn clockRead(output: *a.MonotonicClockInfo) callconv(.c) i32 {
    output.* = clock_value;
    return clock_result;
}
fn goodClock() a.MonotonicClockInfo {
    return .{ .flags = a.monotonic_clock_flag_valid | a.monotonic_clock_flag_continuous | a.monotonic_clock_flag_high_resolution, .source = a.monotonic_clock_source_tsc, .generation = 3, .instant_ns = 0x10000000001, .resolution_ns = 1 };
}
test "NVIDIA actual driver lifecycle bridges monotonic clock units and latches clock failure" {
    var api = apiTable();
    api.version = 31;
    api.monotonic_clock = clockRead;
    clock_result = 1;
    clock_value = goodClock();
    state = .{ .present = false, .clock_fixture = true };
    try t.expectEqual(@as(i32, -4), driver.nvidia_init(&api));
    defer _ = driver.nvidia_shutdown();
    try t.expect(clock_provider.available());
    try t.expectEqual(clock_value.instant_ns, clock_provider.r4nv_clock_now_ns());
    try t.expectEqual(@as(u64, 1), clock_provider.r4nv_clock_resolution_ns());
    // A real source change is allowed; its unit stays ns and its current
    // degraded resolution is reported, not cached from the original TSC.
    clock_value.flags = a.monotonic_clock_flag_valid | a.monotonic_clock_flag_continuous | a.monotonic_clock_flag_degraded;
    clock_value.source = a.monotonic_clock_source_periodic_event;
    clock_value.generation += 1;
    clock_value.instant_ns += 10000001;
    clock_value.resolution_ns = 10000001;
    try t.expectEqual(clock_value.instant_ns, clock_provider.r4nv_clock_now_ns());
    try t.expectEqual(@as(u64, 10000001), clock_provider.r4nv_clock_resolution_ns());
    const ctx = r4os.r4dev.DriverContext.init(&api);
    for (0..8) |fault| {
        clock_value = goodClock();
        clock_provider.bind(&ctx);
        switch (fault) {
            0 => clock_result = 0,
            1 => clock_value.flags = a.monotonic_clock_flag_valid,
            2 => clock_value.frequency_hz = 100,
            3 => clock_value.resolution_ns = 0,
            4 => clock_value.instant_ns = std.math.maxInt(u64),
            5 => clock_value.source = a.monotonic_clock_source_unavailable,
            6 => clock_value.version = 2,
            7 => clock_value.size = 79,
            else => unreachable,
        }
        try t.expectEqual(clock_provider.unavailable, clock_provider.r4nv_clock_resolution_ns());
        try t.expectEqual(clock_provider.unavailable, clock_provider.r4nv_clock_now_ns());
        try t.expect(!clock_provider.available());
        clock_value = goodClock();
        clock_result = 1;
        try t.expectEqual(clock_provider.unavailable, clock_provider.r4nv_clock_resolution_ns());
    }
    clock_provider.bind(&ctx);
    clock_value.instant_ns = std.math.maxInt(u64);
    try t.expectEqual(clock_provider.unavailable, clock_provider.r4nv_clock_now_ns());
    try t.expect(!clock_provider.available());
    try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
    try t.expectEqual(clock_provider.unavailable, clock_provider.r4nv_clock_now_ns());
    api.version = 30;
    api.size = @offsetOf(a.DriverApi, "monotonic_clock");
    clock_provider.bind(&ctx);
    try t.expect(!clock_provider.available());
    clock_provider.unbind();
}

var cpu_backing: ?[]align(16) u8 = null;
var stage_backing: ?[]align(256) u8 = null;
const stage_handle: u64 = 0x700000001;
var cpu_handle: u64 = 0x100000001;
var cpu_requested: u64 = 0;
var cpu_calls: u32 = 0;
var cpu_closed = false;
var cpu_fail_release = false;
fn cpuQuery(output: *a.DriverHeapApi) callconv(.c) i32 {
    output.* = .{ .allocate = @intFromPtr(&cpuAllocate), .release = @intFromPtr(&cpuRelease) };
    return 0;
}
fn cpuAllocate(bytes: u64, alignment: u32, output: *a.DriverHeapAllocation) callconv(.c) i32 {
    std.debug.assert((alignment == 16 or alignment == 256) and output.version == 1 and output.size == @sizeOf(a.DriverHeapAllocation));
    cpu_calls += 1;
    cpu_requested = bytes;
    output.* = .{};
    if (cpu_closed) return a.driver_heap_error_closed;
    if (bytes > (if (state.rom_fixture) @as(u64, vbios.max_rom_bytes) else 8192)) return a.driver_heap_error_memory;
    if (cpu_backing != null) {
        std.debug.assert(state.fuse_fixture and stage_backing == null and bytes == 1280 and alignment == 256);
        state.stage_allocations += 1;
        if (state.fuse_fault == .allocation) return a.driver_heap_error_memory;
        const backing = t.allocator.alignedAlloc(u8, comptime std.mem.Alignment.fromByteUnits(256), @intCast(bytes)) catch return a.driver_heap_error_memory;
        stage_backing = backing;
        output.* = .{ .handle = stage_handle, .cpu_address = @intFromPtr(backing.ptr), .byte_length = bytes, .alignment = 256 };
        return 0;
    }
    std.debug.assert(cpu_backing == null and alignment == 16);
    const backing = t.allocator.alignedAlloc(u8, .@"16", @intCast(bytes)) catch return a.driver_heap_error_memory;
    cpu_backing = backing;
    cpu_handle += 1;
    output.* = .{ .handle = cpu_handle, .cpu_address = @intFromPtr(backing.ptr), .byte_length = bytes, .alignment = 16 };
    return 0;
}
fn cpuRelease(handle: u64) callconv(.c) i32 {
    if (handle == stage_handle) {
        std.debug.assert(stage_backing != null and !state.dma_pinned and !state.dma_mapped and state.preflight_mapping == 0);
        if (state.fuse_fault == .release) return a.driver_heap_error_release;
        t.allocator.free(stage_backing.?);
        stage_backing = null;
        return 0;
    }
    std.debug.assert(handle == cpu_handle and cpu_backing != null);
    if (cpu_fail_release) return a.driver_heap_error_release;
    t.allocator.free(cpu_backing.?);
    cpu_backing = null;
    return 0;
}

test "NVIDIA actual driver lifecycle bridges resident CPU memory and retains failed C frees" {
    var api = apiTable();
    api.version = 30;
    api.heap_query = cpuQuery;
    state = .{ .present = false };
    cpu_closed = false;
    cpu_fail_release = false;
    cpu_calls = 0;
    try t.expectEqual(@as(i32, -4), driver.nvidia_init(&api));
    defer _ = driver.nvidia_shutdown();
    try t.expect(cpu_provider.available());
    const pointer = cpu_provider.r4nv_heap_allocate(137) orelse return error.CpuAllocation;
    try t.expectEqual(@as(u64, 153), cpu_requested);
    try t.expectEqual(@as(usize, 0), @intFromPtr(pointer) & 15);
    const data = @as([*]u8, @ptrCast(pointer))[0..137];
    @memset(data, 0x7b);
    cpu_fail_release = true;
    cpu_provider.r4nv_heap_free(pointer);
    try t.expect(cpu_backing != null and cpu_provider.releaseFailures() == 1);
    for (data) |value| try t.expectEqual(@as(u8, 0x7b), value);
    cpu_fail_release = false;
    cpu_provider.r4nv_heap_free(pointer);
    try t.expect(cpu_backing == null);
    const empty = cpu_provider.r4nv_heap_allocate(0) orelse return error.ZeroAllocation;
    try t.expectEqual(@as(u64, 17), cpu_requested);
    cpu_provider.r4nv_heap_free(empty);
    const calls = cpu_calls;
    try t.expect(cpu_provider.r4nv_heap_allocate(std.math.maxInt(u64)) == null);
    try t.expectEqual(calls, cpu_calls);
    try t.expect(cpu_provider.r4nv_heap_allocate(0x100000001) == null);
    try t.expectEqual(@as(u64, 0x100000011), cpu_requested);
    cpu_closed = true;
    try t.expect(cpu_provider.r4nv_heap_allocate(17) == null);
    cpu_provider.r4nv_heap_free(null);
    try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
    try t.expect(!cpu_provider.available() and cpu_backing == null);
    try t.expect(cpu_provider.r4nv_heap_allocate(1) == null);
    // The unchanged old table prefix never evaluates the optional query.
    api.version = 29;
    api.size = @offsetOf(a.DriverApi, "heap_query");
    state = .{ .present = false };
    try t.expectEqual(@as(i32, -4), driver.nvidia_init(&api));
    try t.expect(!cpu_provider.available());
}

const State = struct {
    present: bool = true,
    clock_fixture: bool = false,
    rom_fixture: bool = false,
    rom_reported: bool = false,
    fwsec_reported: bool = false,
    fwsec_rejected: bool = false,
    full_rom_record: bool = false,
    prom_mapping: bool = false,
    prom_seen: bool = false,
    fail_prom_map: bool = false,
    fail_prom_unmap: bool = false,
    fail_prom_collect: bool = false,
    deadline_prom: bool = false,
    fuse_fixture: bool = false,
    fuse_seen: bool = false,
    fuse_mapping: [2]bool = .{ false, false },
    fuse_fault: enum { none, map_debug, map_version, window, unmap_debug, unmap_version, collect, clock, deadline, unstable, allocation, release, signature, debug_missing, sentinel_debug, sentinel_version, short_input, dma_pin, dma_map, dma_pin_header, dma_count, dma_length, dma_owner, dma_alignment, dma_mask, dma_unmap, dma_unpin, dma_bounce, state_map, state_window, state_clock, state_deadline, state_unstable, state_unmap, state_collect, state_protected, state_display_disabled, state_riscv_disabled } = .none,
    preflight_seen: bool = false,
    preflight_mapping: u8 = 0,
    preflight_reported: bool = false,
    dma_pinned: bool = false,
    dma_mapped: bool = false,
    dma_reported: bool = false,
    stage_allocations: u32 = 0,
    stage_prepared: bool = false,
    device_id: u16 = 0x2504,
    enumerate_count: usize = 0,
    detail_count: usize = 0,
    queries: usize = 0,
    maps: usize = 0,
    unmaps: usize = 0,
    collects: usize = 0,
    fail_map: bool = false,
    fail_unmap: bool = false,
    fail_collect: bool = false,
    mapping: bool = false,
    private_mapping: bool = false,
    chip_reported: bool = false,
    lock_verified: bool = false,
    resource_fault: enum { none, missing, wrong, short, deadline, generation } = .none,
    words: [1024]u32 = .{ 0x176000a1, 0 } ++ .{0} ** 1022,
};
var state: State = .{};

fn forbidden() callconv(.c) noreturn {
    @panic("passive driver invoked an unadmitted DriverApi function");
}
fn apiTable() a.DriverApi {
    var api: a.DriverApi = undefined;
    inline for (@typeInfo(a.DriverApi).@"struct".fields) |field| {
        switch (@typeInfo(field.type)) {
            .int => @field(api, field.name) = 0,
            .pointer => @field(api, field.name) = @ptrCast(&forbidden),
            .optional => @field(api, field.name) = null,
            else => @compileError("DriverApi fixture must cover new field kinds"),
        }
    }
    api.magic = a.driver_magic;
    api.version = 29;
    api.size = @sizeOf(a.DriverApi);
    api.log_info = log;
    api.log_warn = log;
    api.log_error = log;
    api.get_option = option;
    api.pci_device_count = count;
    api.pci_device_at = at;
    api.pci_read_config32 = config;
    api.gfx_memory_query = memory;
    api.resource_query = resources;
    return api;
}
fn log(text: [*:0]const u8) callconv(.c) void {
    if (std.mem.indexOf(u8, std.mem.span(text), "chip=GA106") != null) state.chip_reported = true;
    if (std.mem.indexOf(u8, std.mem.span(text), "lock=verified") != null) state.lock_verified = true;
    if (std.mem.indexOf(u8, std.mem.span(text), "vbios: verified source=PROM") != null) state.rom_reported = true;
    if (std.mem.indexOf(u8, std.mem.span(text), "fwsec: catalog=parsed") != null) state.fwsec_reported = true;
    if (std.mem.indexOf(u8, std.mem.span(text), "fwsec: unavailable") != null) state.fwsec_rejected = true;
    if (std.mem.indexOf(u8, std.mem.span(text), "fwsec: cpu-image=prepared") != null) state.stage_prepared = true;
    if (std.mem.indexOf(u8, std.mem.span(text), "fwsec: dma-image=staged") != null) state.dma_reported = true;
    if (std.mem.indexOf(u8, std.mem.span(text), "fwsec: preflight-tcm=fits") != null) state.preflight_reported = true;
    const value = std.mem.span(text);
    const marker = "bytes=64 hex=";
    if (std.mem.indexOf(u8, value, marker)) |index| {
        std.debug.assert(value[index + marker.len ..].len == 128);
        state.full_rom_record = true;
    }
}
fn resources(output: *a.DriverResourceApi) callconv(.c) i32 {
    output.* = .{ .stat = @intFromPtr(&resourceStat), .read_at = @intFromPtr(&resourceRead), .now_ns = @intFromPtr(&resourceNow) };
    return 0;
}
fn resourceNow() callconv(.c) u64 {
    if (state.preflight_seen) {
        if (state.fuse_fault == .state_clock) return 99;
        if (state.fuse_fault == .state_deadline) return 2 * std.time.ns_per_s;
    }
    if (state.fuse_seen) {
        if (state.fuse_fault == .clock) return 99;
        if (state.fuse_fault == .deadline) return 2 * std.time.ns_per_s;
    }
    if (state.prom_mapping and state.deadline_prom) return 11 * std.time.ns_per_s;
    if (state.clock_fixture) return clock_value.instant_ns;
    return 100;
}
fn resourceStat(name: [*]const u8, length: u32, output: *a.DriverResourceInfo) callconv(.c) i32 {
    if (state.resource_fault == .missing) return a.driver_resource_error_not_found;
    if (std.mem.eql(u8, name[0..length], "NVFW-LOCK.json")) {
        output.* = .{ .handle = 0x100000001, .byte_length = resource_loader.lock_bytes.len, .module_generation = 13 };
    } else {
        std.debug.assert(std.mem.eql(u8, name[0..length], firmware.specification(.ga10x).resource));
        output.* = .{ .handle = 0x100000002, .byte_length = firmware.specification(.ga10x).bytes, .module_generation = if (state.resource_fault == .generation) 14 else 13 };
    }
    return 0;
}
fn resourceRead(handle: u64, offset: u64, out: [*]u8, length: u32, deadline: u64) callconv(.c) i32 {
    std.debug.assert(handle == 0x100000001 or handle == 0x100000002);
    std.debug.assert(deadline > resourceNow() and offset == 0);
    if (state.resource_fault == .deadline) return a.driver_resource_error_deadline;
    if (handle == 0x100000001) {
        std.debug.assert(length == resource_loader.lock_bytes.len);
        @memcpy(out[0..length], resource_loader.lock_bytes);
        if (state.resource_fault == .wrong) out[0] ^= 1;
    } else {
        @memset(out[0..length], 0);
    }
    return @as(i32, @intCast(length)) - @as(i32, if (state.resource_fault == .short) 1 else 0);
}

test "NVIDIA actual driver lifecycle verifies loaded lock before PCI and binds firmware generation" {
    var api = apiTable();
    for ([_]@TypeOf(state.resource_fault){ .missing, .wrong, .short, .deadline }) |fault| {
        state = .{ .resource_fault = fault };
        try t.expectEqual(@as(i32, -6), driver.nvidia_init(&api));
        try t.expectEqual(@as(usize, 0), state.enumerate_count);
        try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
        try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
    }
    state = .{ .present = false };
    try t.expectEqual(@as(i32, -4), driver.nvidia_init(&api));
    try t.expect(state.lock_verified);
    try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
    const ctx = r4os.r4dev.DriverContext.init(&api).resources().?;
    var reader = try resource_loader.Reader.init(ctx, .ga10x, 1000);
    var chunk: [65536]u8 = undefined;
    try t.expectEqual(chunk.len, try reader.readAt(firmware.specification(.ga10x).resource, 0, &chunk, 1000));
    try t.expectError(error.Name, reader.readAt("other-version.bin", 0, &chunk, 1000));
    state.resource_fault = .generation;
    try t.expectError(error.Size, resource_loader.Reader.init(ctx, .ga10x, 1000));
    // The exact old prefix remains valid for the original passive probe.
    state = .{ .present = false };
    api.version = 28;
    api.size = @offsetOf(a.DriverApi, "resource_query");
    try t.expectEqual(@as(i32, -4), driver.nvidia_init(&api));
    try t.expect(!state.lock_verified);
    try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
}
fn option(_: [*:0]const u8, _: [*:0]const u8) callconv(.c) [*:0]const u8 {
    return "passive";
}
fn count() callconv(.c) u32 {
    state.enumerate_count += 1;
    return if (state.present) 1 else 0;
}
fn at(index: u32, output: *a.PciDeviceInfo) callconv(.c) i32 {
    std.debug.assert(index == 0 and state.present);
    state.detail_count += 1;
    output.* = .{ .bus_kind = 2, .bus = 9, .vendor_id = 0x10de, .device_id = state.device_id, .class_code = 3 };
    return 0;
}
fn config(kind: u8, bus: u8, device: u8, function: u8, offset: u16) callconv(.c) u32 {
    std.debug.assert(kind == 2 and bus == 9 and device == 0 and function == 0);
    return switch (offset) {
        0 => @as(u32, state.device_id) << 16 | 0x10de,
        4 => if (state.rom_fixture) 0x100002 else 2,
        8 => 0x030000a1,
        0x10 => 0xe0000000,
        0x2c => 0x12341458,
        0x34 => if (state.rom_fixture) 0x40 else 0,
        0x40 => if (state.rom_fixture) 0x10 else 0,
        0x100 => if (state.rom_fixture) 0x10015 else 0,
        0x104 => if (state.rom_fixture) 1 << 8 else 0,
        0x108 => if (state.rom_fixture) (4 << 8) | (1 << 5) else 0,
        else => 0,
    };
}
fn memory(output: *a.GfxDriverMemoryApi) callconv(.c) i32 {
    state.queries += 1;
    output.* = .{ .mmio_map = @intFromPtr(&map), .mmio_unmap = @intFromPtr(&unmap), .collect = @intFromPtr(&collect) };
    return a.gfx_buffer_result_ok;
}
fn map(request: *const a.GfxMmioRequest, output: *a.GfxMmioWindow) callconv(.c) i32 {
    for (preflight.pages, 0..) |page, index| {
        if (!state.dma_reported or request.byte_offset != page) continue;
        std.debug.assert(state.dma_reported and state.dma_mapped and state.fuse_mapping[0] == false and state.fuse_mapping[1] == false and
            request.resource_base == 0xe0000000 and request.resource_bytes == 16 * 1024 * 1024 and
            request.byte_length == 4096 and request.cache_policy == a.gfx_buffer_cache_uncached);
        const bit = @as(u8, 1) << @as(u3, @intCast(index));
        std.debug.assert(state.preflight_mapping & bit == 0);
        std.debug.assert(!(state.fuse_fault == .state_display_disabled and page == 0x625000));
        std.debug.assert(!(state.fuse_fault == .state_riscv_disabled and page == 0x111000));
        state.maps += 1;
        state.preflight_seen = true;
        if (state.fuse_fault == .state_map and index == 2) {
            state.private_mapping = true;
            return -1;
        }
        state.preflight_mapping |= bit;
        if (state.fuse_fault == .state_unstable and index == 2) preflight_words[0][0x108 / 4] ^= 1;
        output.* = .{ .handle = .{ .id = @intCast(5 + index), .generation = 11 }, .cpu_address = @intFromPtr(&preflight_words[index]), .physical_address = request.resource_base + page, .byte_length = if (state.fuse_fault == .state_window) 4095 else 4096, .cache_policy = request.cache_policy };
        return a.gfx_buffer_result_ok;
    }
    if (request.byte_offset == 0x820000 or request.byte_offset == 0x824000) {
        const index: usize = if (request.byte_offset == 0x820000) 0 else 1;
        std.debug.assert(state.fuse_fixture and state.prom_mapping and !state.mapping and !state.fuse_mapping[index] and
            request.resource_base == 0xe0000000 and request.resource_bytes == 16 * 1024 * 1024 and
            request.byte_length == 4096 and request.cache_policy == a.gfx_buffer_cache_uncached);
        state.maps += 1;
        state.fuse_seen = true;
        output.* = .{};
        if ((index == 0 and state.fuse_fault == .map_debug) or (index == 1 and state.fuse_fault == .map_version)) {
            state.private_mapping = true;
            return -1;
        }
        state.fuse_mapping[index] = true;
        if (index == 1 and state.fuse_fault == .unstable) fuse_words[0][0x74c / 4] ^= 1;
        output.* = .{ .handle = .{ .id = @intCast(3 + index), .generation = 11 }, .cpu_address = @intFromPtr(&fuse_words[index]), .physical_address = request.resource_base + request.byte_offset, .byte_length = if (state.fuse_fault == .window) 4095 else 4096, .cache_policy = request.cache_policy };
        return a.gfx_buffer_result_ok;
    }
    if (request.byte_offset == vbios_probe.prom_offset) {
        std.debug.assert(state.rom_fixture and !state.mapping and !state.prom_mapping and
            request.resource_base == 0xe0000000 and request.resource_bytes == 16 * 1024 * 1024 and
            request.byte_length == vbios.max_rom_bytes and request.cache_policy == a.gfx_buffer_cache_uncached);
        state.maps += 1;
        state.prom_seen = true;
        output.* = .{};
        if (state.fail_prom_map) {
            state.private_mapping = true;
            return -1;
        }
        state.prom_mapping = true;
        output.* = .{ .handle = .{ .id = 2, .generation = 11 }, .cpu_address = @intFromPtr(&prom_bytes), .physical_address = request.resource_base + request.byte_offset, .byte_length = request.byte_length, .cache_policy = request.cache_policy };
        return a.gfx_buffer_result_ok;
    }
    std.debug.assert(request.resource_base == 0xe0000000 and request.resource_bytes == 4096 and request.byte_length == 4096 and request.cache_policy == a.gfx_buffer_cache_uncached);
    state.maps += 1;
    output.* = .{};
    if (state.fail_map) {
        state.private_mapping = true;
        return -1;
    }
    std.debug.assert(!state.mapping);
    state.mapping = true;
    output.* = .{ .handle = .{ .id = 1, .generation = 11 }, .cpu_address = @intFromPtr(&state.words), .physical_address = request.resource_base, .byte_length = 4096, .cache_policy = request.cache_policy };
    return a.gfx_buffer_result_ok;
}
fn unmap(handle: *const a.GfxBufferHandle, quiesced: u32) callconv(.c) i32 {
    if (handle.id >= 5 and handle.id < 5 + preflight.pages.len) {
        const bit = @as(u8, 1) << @as(u3, @intCast(handle.id - 5));
        std.debug.assert(handle.generation == 11 and quiesced == 1 and state.preflight_mapping & bit != 0);
        state.unmaps += 1;
        if (state.fuse_fault == .state_unmap and handle.id == 7) return -1;
        state.preflight_mapping &= ~bit;
        return a.gfx_buffer_result_ok;
    }
    if (handle.id == 3 or handle.id == 4) {
        const index: usize = handle.id - 3;
        std.debug.assert(handle.generation == 11 and quiesced == 1 and state.fuse_mapping[index]);
        state.unmaps += 1;
        if ((index == 0 and state.fuse_fault == .unmap_debug) or (index == 1 and state.fuse_fault == .unmap_version)) return -1;
        state.fuse_mapping[index] = false;
        return a.gfx_buffer_result_ok;
    }
    if (handle.id == 2) {
        std.debug.assert(handle.generation == 11 and quiesced == 1 and state.prom_mapping);
        state.unmaps += 1;
        if (state.fail_prom_unmap) return -1;
        state.prom_mapping = false;
        return a.gfx_buffer_result_ok;
    }
    std.debug.assert(handle.id == 1 and handle.generation == 11 and quiesced == 1 and state.mapping);
    state.unmaps += 1;
    if (state.fail_unmap) return -1;
    state.mapping = false;
    return a.gfx_buffer_result_ok;
}
fn collect() callconv(.c) i32 {
    state.collects += 1;
    if (state.preflight_seen and state.fuse_fault == .state_collect) return -1;
    if (state.fuse_seen and state.fuse_fault == .collect) return -1;
    if (state.fail_collect or (state.prom_seen and state.fail_prom_collect)) return -1;
    state.private_mapping = false;
    return a.gfx_buffer_result_ok;
}

var fuse_words: [2][1024]u32 = .{.{0} ** 1024} ** 2;
var preflight_words: [preflight.pages.len][1024]u32 = @splat(@splat(0));
fn fwsecPin(address: u64, bytes: u32, flags: u32, out: *a.DmaPinnedBuffer) callconv(.c) i32 {
    std.debug.assert(state.stage_prepared and stage_backing != null and !state.dma_pinned and !state.dma_mapped);
    std.debug.assert(address == @intFromPtr(stage_backing.?.ptr) and bytes == 1280 and flags == 0);
    if (state.fuse_fault == .dma_pin) return -1;
    state.dma_pinned = true;
    out.* = .{ .handle = 0x900000001, .virt_addr = address, .bytes = bytes, .page_count = @intCast(((address & 4095) + bytes + 4095) / 4096) };
    if (state.fuse_fault == .dma_pin_header) out.flags = 1;
    return 0;
}
fn fwsecMap(pin: *const a.DmaPinnedBuffer, constraints: *const a.DmaConstraints, direction: u32, out: *a.DmaMapping) callconv(.c) i32 {
    std.debug.assert(state.dma_pinned and !state.dma_mapped and pin.handle == 0x900000001);
    std.debug.assert(constraints.dma_mask == 0x1ffffffffffff and constraints.max_segments == 1 and constraints.alignment == 256 and
        constraints.max_segment_bytes == 1280 and constraints.boundary == 0 and constraints.flags == 5 and direction == 1);
    if (state.fuse_fault == .dma_map) return -1;
    state.dma_mapped = true;
    out.* = .{ .handle = 0xa00000001, .pin_handle = pin.handle, .requested_bytes = pin.bytes, .mapped_bytes = pin.bytes, .direction = direction, .flags = constraints.flags, .segment_count = 1 };
    out.segments[0] = .{ .phys_addr = 0x1234567800, .bytes = pin.bytes };
    switch (state.fuse_fault) {
        .dma_count => out.segment_count = 2,
        .dma_length => out.segments[0].bytes -= 1,
        .dma_owner => out.pin_handle += 1,
        .dma_alignment => out.segments[0].phys_addr += 1,
        .dma_mask => out.segments[0].phys_addr = 0x2000000000000,
        .dma_bounce => {
            out.segments[0].phys_addr = 0x4567800;
            out.flags |= a.dma_mapping_flag_bounced;
        },
        else => {},
    }
    return 0;
}
fn fwsecUnmap(mapping: *a.DmaMapping) callconv(.c) i32 {
    std.debug.assert(state.dma_pinned and state.dma_mapped and stage_backing != null and mapping.handle == 0xa00000001);
    mapping.* = .{}; // A failure must not destroy the owner's retry descriptor.
    if (state.fuse_fault == .dma_unmap) return -1;
    state.dma_mapped = false;
    return 0;
}
fn fwsecUnpin(pin: *a.DmaPinnedBuffer) callconv(.c) i32 {
    std.debug.assert(state.dma_pinned and !state.dma_mapped and stage_backing != null and pin.handle == 0x900000001);
    pin.* = .{};
    if (state.fuse_fault == .dma_unpin) return -1;
    state.dma_pinned = false;
    return 0;
}
test "NVIDIA actual driver lifecycle measures GA106 fuses and retains FWSEC DMA mappings before CPU backing" {
    var api = apiTable();
    api.version = 31;
    api.heap_query = cpuQuery;
    api.dma_pin_buffer = fwsecPin;
    api.dma_map_pinned = fwsecMap;
    api.dma_unmap = fwsecUnmap;
    api.dma_unpin_buffer = fwsecUnpin;
    inline for (std.meta.tags(@TypeOf(state.fuse_fault))) |fault| {
        state = .{ .rom_fixture = true, .fuse_fixture = true, .fuse_fault = fault };
        cpu_closed = false;
        cpu_fail_release = false;
        defer {
            state.fuse_fault = .none;
            _ = driver.nvidia_shutdown();
        }
        var rom = @import("fwsec_test.zig").ga106Fixture();
        const original_board = try vbios.parse(&rom, 0x2504);
        const entry = (try @import("fwsec.zig").parse(&rom, &original_board)).entries[0];
        if (fault == .short_input) @import("fwsec_test.zig").put32(&rom, entry.interface.mapper.offset + 12, 23);
        @memset(&prom_bytes, 0);
        @memcpy(prom_bytes[0..rom.len], &rom);
        fuse_words = .{.{0} ** 1024} ** 2;
        fuse_words[0][0x74c / 4] = if (fault == .debug_missing) 0 else if (fault == .sentinel_debug) 0xffffffff else 1;
        fuse_words[1][0x1e0 / 4] = if (fault == .signature) 5 else if (fault == .sentinel_version) 0xffffffff else 8;
        const initial_fuses = fuse_words;
        var raw = @import("fwsec_test.zig").preflightFixture();
        if (fault == .state_protected) raw.put(.bcr, 0xbadf5040);
        if (fault == .state_display_disabled) raw.put(.display_fuse, 1);
        if (fault == .state_riscv_disabled) raw.put(.hwcfg2, 0);
        preflight_words = @splat(@splat(0));
        for (preflight.pages, 0..) |page, page_index| {
            for (preflight.addresses, 0..) |address, index| {
                if (address & ~@as(u32, 0xfff) == page) preflight_words[page_index][(address & 0xfff) / 4] = raw.values[index];
            }
        }
        const initial_preflight = preflight_words;
        const dma_case = @intFromEnum(fault) >= @intFromEnum(@TypeOf(fault).dma_pin);
        const state_case = @intFromEnum(fault) >= @intFromEnum(@TypeOf(fault).state_map);
        const failed_cleanup = fault == .unmap_debug or fault == .unmap_version or fault == .collect or fault == .release or fault == .dma_unmap or fault == .dma_unpin or fault == .state_unmap or fault == .state_collect;
        try t.expectEqual(@as(i32, if (failed_cleanup) -10 else 0), driver.nvidia_init(&api));
        try t.expect(state.rom_reported and state.fwsec_reported and state.fuse_seen);
        try t.expectEqual(fault == .none or fault == .release or dma_case, state.stage_prepared);
        try t.expectEqual(fault == .none or fault == .release or fault == .dma_unmap or fault == .dma_unpin or fault == .dma_bounce or state_case, state.dma_reported);
        try t.expectEqual((!state_case and state.dma_reported) or fault == .state_display_disabled or fault == .state_riscv_disabled, state.preflight_reported);
        try t.expectEqual(@as(u32, if (fault == .none or fault == .release or fault == .allocation or dma_case) 1 else 0), state.stage_allocations);
        try t.expectEqualSlices(u8, &rom, prom_bytes[0..rom.len]);
        if (fault != .unstable) try t.expectEqualDeep(initial_fuses, fuse_words);
        if (fault != .state_unstable) try t.expectEqualDeep(initial_preflight, preflight_words);
        if (failed_cleanup) {
            try t.expect(cpu_backing != null);
            try t.expectEqual(@as(i32, -1), driver.nvidia_shutdown());
            if (fault == .release or fault == .dma_unmap or fault == .dma_unpin or state_case) try t.expect(stage_backing != null);
            state.fuse_fault = .none;
        }
        try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
        try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
        try t.expect(cpu_backing == null and stage_backing == null and !state.prom_mapping and !state.private_mapping and
            !state.fuse_mapping[0] and !state.fuse_mapping[1] and !state.dma_pinned and !state.dma_mapped and state.preflight_mapping == 0);
    }
}

test "NVIDIA actual driver lifecycle reads bounded PROM and retains each failed cleanup owner" {
    var api = apiTable();
    api.version = 31;
    api.heap_query = cpuQuery;
    const rom = fixtures.fixture();
    for (0..10) |fault| {
        state = .{ .rom_fixture = true };
        defer {
            state.fail_prom_unmap = false;
            state.fail_prom_collect = false;
            cpu_fail_release = false;
            cpu_closed = false;
            _ = driver.nvidia_shutdown();
        }
        cpu_closed = false;
        cpu_fail_release = false;
        @memset(&prom_bytes, 0);
        @memcpy(prom_bytes[0..rom.len], &rom);
        switch (fault) {
            0 => {},
            1 => {
                prom_bytes[0x200] ^= 1;
                prom_bytes[0x102] = 8; // Exercise a full 64-byte diagnostic record.
            },
            2 => cpu_closed = true,
            3 => state.fail_prom_map = true,
            4 => state.fail_prom_unmap = true,
            5 => state.fail_prom_collect = true,
            6 => cpu_fail_release = true,
            7 => state.deadline_prom = true,
            8, 9 => {
                const firmware_rom = @import("fwsec_test.zig").fixture(3);
                @memcpy(prom_bytes[0..firmware_rom.len], &firmware_rom);
                if (fault == 9) @import("fwsec_test.zig").put32(&prom_bytes, 0xc08, 0xfffffff0);
            },
            else => unreachable,
        }
        const result = driver.nvidia_init(&api);
        try t.expectEqual(@as(i32, if (fault == 0 or fault >= 8) 0 else -10), result);
        try t.expectEqual(fault == 0 or (fault >= 4 and fault <= 6) or fault >= 8, state.rom_reported);
        try t.expectEqual(fault == 8, state.fwsec_reported);
        if (fault == 0 or fault == 9) try t.expect(state.fwsec_rejected);
        if (fault == 1) try t.expect(state.full_rom_record);
        try t.expect(!state.mapping);
        if (fault >= 4 and fault <= 6) {
            try t.expect(cpu_backing != null);
            try t.expectEqual(@as(i32, -1), driver.nvidia_shutdown());
            try t.expectEqual(@as(i32, -1), driver.nvidia_init(&api));
        }
        state.fail_prom_unmap = false;
        state.fail_prom_collect = false;
        cpu_fail_release = false;
        try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
        try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
        try t.expect(!state.mapping and !state.prom_mapping and !state.private_mapping and cpu_backing == null);
        try t.expectEqual(@as(usize, if (fault == 2) 1 else 2), state.maps);
    }
    cpu_closed = false;
    // Actual non-GA106 words must never reach the PROM map or allocation,
    // even when a device advertises adequate ReBAR extents.
    state = .{ .rom_fixture = true };
    state.words[0] = 0x172000a1;
    const before = cpu_calls;
    try t.expectEqual(@as(i32, 0), driver.nvidia_init(&api));
    try t.expectEqual(@as(usize, 1), state.maps);
    try t.expect(!state.rom_reported and cpu_calls == before);
    try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
}

test "NVIDIA actual driver lifecycle rejects writes and retains failed mappings through shutdown" {
    const api = apiTable();
    state = .{ .present = false };
    try t.expectEqual(@as(i32, -4), driver.nvidia_init(&api));
    try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
    try t.expectEqual(@as(usize, 0), state.queries);
    state = .{ .device_id = 0xbeef };
    try t.expectEqual(@as(i32, 0), driver.nvidia_init(&api));
    try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
    try t.expectEqual(@as(usize, 1), state.enumerate_count);
    try t.expectEqual(@as(usize, 1), state.detail_count);
    try t.expectEqual(@as(usize, 0), state.queries);
    state = .{};
    try t.expectEqual(@as(i32, 0), driver.nvidia_init(&api));
    try t.expectEqual(@as(i32, -1), driver.nvidia_init(&api));
    try t.expect(state.chip_reported and !state.mapping);
    try t.expectEqual(@as(usize, 1), state.enumerate_count);
    try t.expectEqual(@as(usize, 1), state.maps);
    try t.expectEqual(@as(usize, 1), state.unmaps);
    try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
    try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
    state = .{ .fail_map = true, .fail_collect = true };
    try t.expectEqual(@as(i32, -5), driver.nvidia_init(&api));
    try t.expect(state.private_mapping);
    try t.expectEqual(@as(i32, -1), driver.nvidia_shutdown());
    try t.expectEqual(@as(i32, -1), driver.nvidia_init(&api));
    state.fail_collect = false;
    try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
    try t.expect(!state.private_mapping);
    try t.expectEqual(@as(usize, 0), state.unmaps);
    state = .{ .fail_unmap = true };
    try t.expectEqual(@as(i32, -5), driver.nvidia_init(&api));
    try t.expect(state.mapping);
    try t.expectEqual(@as(i32, -1), driver.nvidia_shutdown());
    state.fail_unmap = false;
    try t.expectEqual(@as(i32, 0), driver.nvidia_shutdown());
    try t.expect(!state.mapping);
    try t.expectEqual(@as(usize, 3), state.unmaps);
    try checkBootVramOwner();
}

// Exercise the actual SDK/MMIO snapshot owner inside the existing lifecycle
// case. Host RAM models the aperture; the pure preflight case checks address
// selection and partial device effects independently. This is no GPU proof.
const BootVramFixture = struct {
    var registers: []u8 = &.{};
    var buffers: [2]?[]u8 = .{ null, null };
    var leases: [2]bool = .{ false, false };
    var mapped: [0x900]bool = @splat(false);
    var held = false;
    var effects = false;
    var request: a.GfxBootHoldRequest = .{};
    var fail_unmap = false;
    var fail_map = false;
    fn info() a.GfxNativeBootInfo {
        return .{ .generation = 7, .physical_address = 0xd0000000, .byte_length = 16384,
            .width = 64, .height = 64, .pitch = 256, .state = if (held) 2 else 1 };
    }
    fn memoryQuery(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = .{ .buffer_create = @intFromPtr(&create), .buffer_map = @intFromPtr(&bufferMap),
            .buffer_unmap = @intFromPtr(&bufferUnmap), .buffer_release = @intFromPtr(&release),
            .mmio_map = @intFromPtr(&mapMmio), .mmio_unmap = @intFromPtr(&unmapMmio), .collect = @intFromPtr(&collectBuffers) };
        return a.gfx_buffer_result_ok;
    }
    fn displayQuery(out: *a.GfxDriverDisplayApi) callconv(.c) i32 {
        out.* = .{ .boot_info = @intFromPtr(&bootInfo), .boot_hold = @intFromPtr(&bootHold), .boot_finish = @intFromPtr(&bootFinish) };
        return a.gfx_output_ok;
    }
    fn resourcesQuery(out: *a.DriverResourceApi) callconv(.c) i32 { out.* = .{ .now_ns = @intFromPtr(&now) }; return a.driver_resource_ok; }
    fn now() callconv(.c) u64 { return 1000000; }
    fn bootInfo(out: *a.GfxNativeBootInfo) callconv(.c) i32 { out.* = info(); return a.gfx_output_ok; }
    fn bootHold(input: *const a.GfxBootHoldRequest, out: *a.GfxNativeState) callconv(.c) i32 {
        std.debug.assert(!held and input.generation == 7 and input.reference.id == 1 and buffers[0] != null);
        request = input.*;
        held = true;
        effects = false;
        out.* = .{ .generation = 9, .state = 2, .outcome = a.gfx_output_outcome_validated, .retained = 1 };
        return a.gfx_output_ok;
    }
    fn bootFinish(generation: u64, operation: u32, out: *a.GfxNativeState) callconv(.c) i32 {
        std.debug.assert(held and generation == 9);
        if (operation == 1) {
            std.debug.assert(!effects);
            effects = true;
        } else if (effects) {
            std.debug.assert(operation == 2);
            const callback: *const fn (u64, u64, *const a.GfxNativeBootInfo) callconv(.c) i32 = @ptrFromInt(request.restore_callback);
            if (callback(request.context, generation, &info()) == 1) held = false;
        } else { std.debug.assert(operation == 0); held = false; }
        out.* = .{ .generation = 9, .state = if (held) 2 else 1, .retained = @intFromBool(held),
            .outcome = if (!held) a.gfx_output_outcome_old_preserved else if (operation == 1) a.gfx_output_outcome_validated else a.gfx_output_outcome_lost };
        return a.gfx_output_ok;
    }
    fn create(input: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) callconv(.c) i32 {
        for (&buffers, 0..) |*backing, index| if (backing.* == null) {
            const bytes = std.heap.page_allocator.alloc(u8, @intCast(input.byte_length)) catch return a.gfx_buffer_error_budget;
            @memset(bytes, 0x36);
            backing.* = bytes;
            out.* = .{ .reference = .{ .id = @intCast(index + 1), .generation = 3 } };
            return a.gfx_buffer_result_ok;
        };
        return a.gfx_buffer_error_budget;
    }
    fn bufferMap(input: *const a.GfxBufferHandle, access: u32, offset: u64, bytes: u64, out: *a.GfxBufferMap) callconv(.c) i32 {
        const index = input.id - 1;
        std.debug.assert(index < 2 and buffers[index] != null and !leases[index] and offset == 0 and bytes == buffers[index].?.len);
        std.debug.assert(access == a.gfx_buffer_map_read or access == a.gfx_buffer_map_write);
        leases[index] = true;
        out.* = .{ .lease = .{ .id = 101 + index, .generation = 4 }, .cpu_address = @intFromPtr(buffers[index].?.ptr), .byte_length = bytes };
        return a.gfx_buffer_result_ok;
    }
    fn bufferUnmap(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        const index = input.id - 101;
        std.debug.assert(index < 2 and leases[index]);
        leases[index] = false;
        return a.gfx_buffer_result_ok;
    }
    fn release(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        const index = input.id - 1;
        std.debug.assert(index < 2 and !leases[index] and !(index == 0 and held));
        std.heap.page_allocator.free(buffers[index].?);
        buffers[index] = null;
        return a.gfx_buffer_result_ok;
    }
    fn mapMmio(input: *const a.GfxMmioRequest, out: *a.GfxMmioWindow) callconv(.c) i32 {
        std.debug.assert(input.resource_base == 0xe0000000 and input.resource_bytes == 0x1000000 and
            input.byte_offset + input.byte_length <= registers.len and input.cache_policy == a.gfx_buffer_cache_uncached);
        if (fail_map) return a.gfx_buffer_error_budget;
        const index = input.byte_offset / 4096;
        std.debug.assert(!mapped[index]);
        mapped[index] = true;
        out.* = .{ .handle = .{ .id = @intCast(index + 1), .generation = 3 }, .cpu_address = @intFromPtr(registers.ptr) + input.byte_offset,
            .physical_address = input.resource_base + input.byte_offset, .byte_length = input.byte_length, .cache_policy = input.cache_policy };
        return a.gfx_buffer_result_ok;
    }
    fn unmapMmio(input: *const a.GfxBufferHandle, quiesced: u32) callconv(.c) i32 {
        const index = input.id - 1;
        std.debug.assert(mapped[index] and quiesced == 1);
        if (fail_unmap) return a.gfx_buffer_error_busy;
        mapped[index] = false;
        return a.gfx_buffer_result_ok;
    }
    fn collectBuffers() callconv(.c) i32 { return a.gfx_buffer_result_ok; }
    fn put(address: usize, value: u32) void { std.mem.writeInt(u32, registers[address..][0..4], value, .little); }
};

fn checkBootVramOwner() !void {
    const f = BootVramFixture;
    f.registers = try std.heap.page_allocator.alloc(u8, 0x900000);
    defer std.heap.page_allocator.free(f.registers);
    @memset(f.registers, 0);
    var raw = @import("fwsec_test.zig").preflightFixture();
    raw.put(.bcr, 1);
    raw.put(.riscv_cpuctl, 0x10);
    raw.put(.vga, 0x10e08);
    for (preflight.addresses, raw.values) |address, value| f.put(address, value);
    f.put(0, 0xb76000a1);
    f.put(0x1700, 0xc2000079);
    @memset(f.registers[0x700000..0x720000], 0x5d);
    var api = apiTable();
    api.version = 34;
    api.gfx_memory_query = f.memoryQuery;
    api.gfx_display_query = f.displayQuery;
    api.resource_query = f.resourcesQuery;
    const ctx = r4os.r4dev.DriverContext.init(&api);
    const id = @import("identity.zig");
    var snapshot: id.Snapshot = .{ .pci = .{} };
    snapshot.pci = .{ .bus_kind = 2, .bus = 9, .vendor_id = 0x10de, .device_id = 0x2504, .class_code = 3 };
    snapshot.command = 2;
    snapshot.bars[0] = .{ .kind = .memory32, .base = 0xe0000000, .bytes = 0x1000000 };
    const chip = id.chip(0xb76000a1, 0).?;
    var capture: @import("boot_vram.zig").Capture = .{};
    defer _ = capture.close();
    const report = try capture.capture(&ctx, &snapshot, chip);
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(f.registers[0x700000..0x720000], &expected, .{});
    try t.expectEqualSlices(u8, &expected, &report.sha256);
    try t.expectEqual(@as(u64, 0x10e0000), report.range.address);
    try t.expect(report.window_restored and report.window_writes == 2 and f.held and f.leases[1]);
    // The existing host fixture supplies prepared boot metadata; actual DMA
    // packing/synchronization remains covered by gsp_boot_storage_test.zig.
    // Here the production reservation borrows the actual BO/display capture.
    const boot_storage = @import("gsp_boot_storage.zig");
    const wpr = @import("gsp_wpr.zig");
    const reservation = @import("boot_vram_lease.zig");
    const pack = try std.heap.page_allocator.alloc(u8, boot_storage.pack_bytes);
    defer std.heap.page_allocator.free(pack);
    @memset(pack, 0);
    const desc_fields = [_]u32{ 5, 20480, 2176, 22656, 16, 0, 0, 0, 0, 2048, 2048, 4096, 6144, 10496, 1, 0, 0, 0, 0, 24576, 0 };
    var descriptor: [84]u8 = undefined;
    for (desc_fields, 0..) |value, index| std.mem.writeInt(u32, descriptor[index * 4 ..][0..4], value, .little);
    const prepared = try wpr.prepare(&.{ .chip_id = chip.id, .raw = raw, .image_bytes = wpr.image_bytes,
        .descriptor = &descriptor, .signature_bytes = wpr.signature_bytes });
    @memcpy(pack[boot_storage.metadata_offset..][0..wpr.bytes], &prepared.unbound_template);
    var backing: boot_storage.Storage = .{ .context = ctx, .vram_plan = prepared.plan,
        .allocation = .{ .handle = 31, .cpu_address = @intFromPtr(pack.ptr), .byte_length = pack.len },
        .pin = .{ .handle = 32 }, .mapping = .{ .handle = 33, .pin_handle = 32 },
        .report = .{ .image = .{ .root_address = 0x200000000, .image_bytes = wpr.image_bytes,
            .allocation_bytes = 63676416, .table_bytes = 135168, .mappings = 4, .segments = 4, .bounced = 0 },
            .boot_address = 0x300000000, .signature_address = 0x300006000, .metadata_address = 0x300007000, .pack_bounced = false } };
    var held: reservation.Lease = .{};
    pack[boot_storage.metadata_offset + 19 * 8] ^= 1;
    try t.expectError(error.MetadataChanged, held.acquire(&capture, &backing));
    try t.expect(capture.borrower == 0 and backing.vram_owner == 0 and f.mapped[0x625]);
    pack[boot_storage.metadata_offset + 19 * 8] ^= 1;
    f.put(0x1183a4, (try raw.get(.fb_mb)) - 1024);
    try t.expectError(error.PlanChanged, held.acquire(&capture, &backing));
    try t.expect(capture.borrower == 0 and backing.vram_owner == 0);
    f.put(0x1183a4, try raw.get(.fb_mb));
    try held.acquire(&capture, &backing);
    const frts = try held.binding(.frts);
    try t.expect(held.validates(frts) and frts.range.bytes == 0x100000 and frts.range.offset > 0x100000000);
    try t.expect(!capture.close() and !backing.close() and capture.ready and backing.report != null);
    try t.expect(f.held and f.buffers[0] != null and f.buffers[1] != null and f.leases[0] and f.leases[1]);
    try t.expectError(error.State, capture.reobserve());
    var duplicate: reservation.Lease = .{};
    try t.expectError(error.Owner, duplicate.acquire(&capture, &backing));
    var moved = held;
    try t.expect(!moved.validates(frts) and !moved.releaseBeforeSubmission());
    var wrong = frts;
    wrong.range.offset += 4096;
    try t.expect(!held.validates(wrong));
    pack[boot_storage.metadata_offset + 19 * 8] ^= 1;
    try t.expectError(error.MetadataChanged, held.binding(.frts));
    pack[boot_storage.metadata_offset + 19 * 8] ^= 1;
    backing.execution_owner = 99;
    try t.expect(!held.releaseBeforeSubmission() and !capture.close() and !backing.close());
    backing.execution_owner = 0; // Undo the fixture's unsubmitted execution borrow.
    capture.boot.held_generation += 1;
    try t.expect(!held.validates(frts) and !held.releaseBeforeSubmission());
    capture.boot.held_generation -= 1;
    try t.expect(held.releaseBeforeSubmission() and held.releaseBeforeSubmission());
    try held.acquire(&capture, &backing);
    try t.expect(!held.validates(frts)); // Same display hold, new reservation serial.
    try t.expect(held.validates(try held.binding(.frts)));
    try t.expect(held.releaseBeforeSubmission());
    held.serial = std.math.maxInt(u64);
    try t.expectError(error.Exhausted, held.acquire(&capture, &backing));
    try t.expect(capture.borrower == 0 and backing.vram_owner == 0 and f.mapped[0x625]);
    f.put(0x625f04, 0x10f08); // Unknown display change: retain every required owner.
    try t.expect(!capture.close());
    try t.expect(f.held and f.buffers[0] != null and f.buffers[1] != null and f.mapped[0x700] and f.leases[1]);
    f.put(0x625f04, 0x10e08);
    f.fail_unmap = true;
    try t.expect(!capture.close());
    try t.expect(!f.held and f.buffers[0] == null and f.buffers[1] == null and f.mapped[0x700]);
    f.fail_unmap = false;
    try t.expect(capture.window_writes == 2); // No repeated register restore for cleanup.
    try t.expect(capture.close() and capture.close());
    try t.expect(std.mem.allEqual(bool, &f.mapped, false));
    f.fail_map = true;
    try t.expectError(error.Mapping, capture.capture(&ctx, &snapshot, chip));
    try t.expect(capture.close());
    f.fail_map = false;
    try t.expect(!f.held and f.buffers[0] == null and f.buffers[1] == null and !f.leases[0] and !f.leases[1]);
}
