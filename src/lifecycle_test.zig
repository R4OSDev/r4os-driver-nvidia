const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const driver = @import("main.zig");
const t = std.testing;
const resource_loader = @import("firmware_resources.zig");
const firmware = @import("firmware.zig");
const cpu_provider = @import("rm_heap.zig");
const clock_provider = @import("rm_clock.zig");

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
    std.debug.assert(alignment == 16 and output.version == 1 and output.size == @sizeOf(a.DriverHeapAllocation));
    cpu_calls += 1;
    cpu_requested = bytes;
    output.* = .{};
    if (cpu_closed) return a.driver_heap_error_closed;
    if (bytes > 8192) return a.driver_heap_error_memory;
    std.debug.assert(cpu_backing == null);
    const backing = t.allocator.alignedAlloc(u8, .@"16", @intCast(bytes)) catch return a.driver_heap_error_memory;
    cpu_backing = backing;
    cpu_handle += 1;
    output.* = .{ .handle = cpu_handle, .cpu_address = @intFromPtr(backing.ptr), .byte_length = bytes, .alignment = 16 };
    return 0;
}
fn cpuRelease(handle: u64) callconv(.c) i32 {
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
}
fn resources(output: *a.DriverResourceApi) callconv(.c) i32 {
    output.* = .{ .stat = @intFromPtr(&resourceStat), .read_at = @intFromPtr(&resourceRead), .now_ns = @intFromPtr(&resourceNow) };
    return 0;
}
fn resourceNow() callconv(.c) u64 {
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
        4 => 2,
        8 => 0x030000a1,
        0x10 => 0xe0000000,
        0x2c => 0x12341458,
        else => 0,
    };
}
fn memory(output: *a.GfxDriverMemoryApi) callconv(.c) i32 {
    state.queries += 1;
    output.* = .{ .mmio_map = @intFromPtr(&map), .mmio_unmap = @intFromPtr(&unmap), .collect = @intFromPtr(&collect) };
    return a.gfx_buffer_result_ok;
}
fn map(request: *const a.GfxMmioRequest, output: *a.GfxMmioWindow) callconv(.c) i32 {
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
    std.debug.assert(handle.id == 1 and handle.generation == 11 and quiesced == 1 and state.mapping);
    state.unmaps += 1;
    if (state.fail_unmap) return -1;
    state.mapping = false;
    return a.gfx_buffer_result_ok;
}
fn collect() callconv(.c) i32 {
    state.collects += 1;
    if (state.fail_collect) return -1;
    state.private_mapping = false;
    return a.gfx_buffer_result_ok;
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
}
