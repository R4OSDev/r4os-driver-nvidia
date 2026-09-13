//! Existing Device-group input BO edge; native allocation/CE/Core/PIO owners
//! remain the production code. Source import/map counters enforce lifetime.
const std = @import("std");
const a = @import("r4os").abi;
pub const Model = struct {
    pub var data: [43 * 160]u8 align(4096) = undefined;
    pub var vram: [524288]u8 = undefined;
    pub var imported = false;
    pub var mapped = false;
    pub var producer = true;
    pub var released: u32 = 0;
    pub var reject_map = false;
    var original: a.GfxDriverMemoryApi = .{};
    pub const reference: a.GfxBufferHandle = .{ .id = 4000, .generation = 9000 };
    const owned: a.GfxBufferHandle = .{ .id = 4001, .generation = 9000 };
    const cpu: a.GfxBufferHandle = .{ .id = 4002, .generation = 9000 };
    pub fn descriptor() a.GfxBufferDescriptor {
        return .{ .width = 37, .height = 43, .byte_length = data.len, .alignment = 4096, .format = a.gfx_buffer_format_argb8888,
            .plane_count = 1, .plane_pitches = .{160,0,0,0}, .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source };
    }
    pub fn install(table: *a.DriverApi) void {
        std.debug.assert(table.gfx_memory_query.?(&original) == a.gfx_buffer_result_ok);
        table.gfx_memory_query = query;
        imported = false; mapped = false; producer = true; released = 0; reject_map = false;
        for (&data, 0..) |*byte, i| byte.* = @truncate(i * 17 + 29);
        @memset(&vram, 0xa5);
    }
    fn query(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = original; out.buffer_import = @intFromPtr(&import); out.buffer_describe = @intFromPtr(&describe);
        out.buffer_map = @intFromPtr(&map); out.buffer_unmap = @intFromPtr(&unmap); out.buffer_release = @intFromPtr(&release);
        return a.gfx_buffer_result_ok;
    }
    fn import(input: *const a.GfxBufferHandle, out: *a.GfxBufferReference) callconv(.c) i32 {
        if (!std.meta.eql(input.*, reference)) {
            const call: *const fn (*const a.GfxBufferHandle, *a.GfxBufferReference) callconv(.c) i32 = @ptrFromInt(original.buffer_import); return call(input, out);
        }
        std.debug.assert(producer and !imported and !mapped);
        imported = true; out.* = .{ .reference = owned, .buffer = .{ .id = 4003, .generation = 9000 } }; return a.gfx_buffer_result_ok;
    }
    fn describe(input: *const a.GfxBufferHandle, out: *a.GfxBufferDescriptor) callconv(.c) i32 {
        if (!std.meta.eql(input.*, owned)) {
            const call: *const fn (*const a.GfxBufferHandle, *a.GfxBufferDescriptor) callconv(.c) i32 = @ptrFromInt(original.buffer_describe); return call(input, out);
        }
        std.debug.assert(imported); out.* = descriptor(); return a.gfx_buffer_result_ok;
    }
    fn map(input: *const a.GfxBufferHandle, access: u32, offset: u64, bytes: u64, out: *a.GfxBufferMap) callconv(.c) i32 {
        if (!std.meta.eql(input.*, owned)) {
            const call: *const fn (*const a.GfxBufferHandle, u32, u64, u64, *a.GfxBufferMap) callconv(.c) i32 = @ptrFromInt(original.buffer_map); return call(input, access, offset, bytes, out);
        }
        std.debug.assert(imported and !mapped and access == a.gfx_buffer_map_read and offset == 0 and bytes == data.len);
        if (reject_map) return a.gfx_buffer_error_busy;
        mapped = true; out.* = .{ .lease = cpu, .cpu_address = @intFromPtr(&data), .byte_length = bytes,
            .cache_policy = a.gfx_buffer_cache_write_back }; return a.gfx_buffer_result_ok;
    }
    fn unmap(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        if (!std.meta.eql(input.*, cpu)) {
            const call: *const fn (*const a.GfxBufferHandle) callconv(.c) i32 = @ptrFromInt(original.buffer_unmap); return call(input);
        }
        std.debug.assert(imported and mapped); mapped = false; return a.gfx_buffer_result_ok;
    }
    fn release(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        if (!std.meta.eql(input.*, owned)) {
            const call: *const fn (*const a.GfxBufferHandle) callconv(.c) i32 = @ptrFromInt(original.buffer_release); return call(input);
        }
        std.debug.assert(imported and !mapped); imported = false; released += 1; return a.gfx_buffer_result_ok;
    }
};
