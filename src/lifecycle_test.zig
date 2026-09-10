const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const driver = @import("main.zig");
const t = std.testing;
const resource_loader = @import("firmware_resources.zig");
const firmware = @import("firmware.zig");

const State = struct {
    present: bool = true,
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
