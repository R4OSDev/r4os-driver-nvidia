//! Kernel peer for the existing Device fixture. Only canonical queue
//! snapshots and lifecycle notifications are modeled here; production RM,
//! context, VA, scheduler, ring and completion owners remain in use.
const std = @import("std");
const a = @import("r4os").abi;
const nv = @import("r4nv_binding");
pub const Model = struct {
    pub const binding: a.GfxBackendBinding = .{ .adapter_id = 0x01000000, .milestone = 1, .device_generation = 17, .reset_generation = 21 };
    var original: ?*const fn (*a.GfxDriverQueueApi) callconv(.c) i32 = null;
    var registration: ?a.GfxBackendRegistration = null;
    pub var operations: u64 = 0;
    pub var closed: [8]bool = @splat(false);
    pub var engine_fault: enum { none, topology, compute_class, copy_class, compute_allocate, copy_allocate } = .none;
    pub var engine_allocations: [2]usize = .{ 0, 0 };
    pub var engine_frees: [2]usize = .{ 0, 0 };
    pub var job: ?a.GfxDriverJob = null;
    pub var claimed = false;
    pub var completed: usize = 0;
    pub var result: u32 = 0;
    pub var signaled = false;
    pub var wakes: usize = 0;
    pub var command: [48]u8 = undefined;
    pub var info: a.GfxNativeJobInfo = .{};
    pub var resource: a.GfxNativeBinding = .{};
    var next_point: u64 = 0;
    pub fn install(table: *a.DriverApi) void {
        original = table.gfx_queue_query;
        table.gfx_queue_query = query;
        registration = null;
        operations = 0;
        closed = @splat(false);
        engine_fault = .none;
        engine_allocations = .{ 0, 0 };
        engine_frees = .{ 0, 0 };
        job = null;
        claimed = false;
        completed = 0;
        result = 0;
        next_point = 0;
        signaled = false;
        wakes = 0;
    }
    pub fn dispose(table: *a.DriverApi) void {
        table.gfx_queue_query = original;
    }
    pub fn wake(raw: usize) i32 {
        std.debug.assert(raw != 0);
        wakes += 1;
        return 0;
    }
    fn query(out: *a.GfxDriverQueueApi) callconv(.c) i32 {
        out.* = .{ .size = @sizeOf(a.GfxDriverQueueApi), .register_profile = @intFromPtr(&register), .unregister_backend = @intFromPtr(&unregister), .update_operations = @intFromPtr(&update), .take = @intFromPtr(&take), .complete = @intFromPtr(&complete), .read_native_info = @intFromPtr(&readInfo), .read_native_data = @intFromPtr(&readData), .read_native_binding = @intFromPtr(&readBinding), .queue_owner_info = @intFromPtr(&ownerInfo) };
        return 1;
    }
    fn register(value: *const a.GfxBackendRegistration, profile: *const a.GfxBackendProfile, out: *a.GfxBackendBinding) callconv(.c) i32 {
        std.debug.assert(registration == null and value.operations == 9 and value.context != 0 and value.notify_callback != 0 and
            profile.interface_id_lo == nv.backend_v1_header.interface_id_lo and profile.interface_id_hi == nv.backend_v1_header.interface_id_hi and profile.revision == 1);
        registration = value.*;
        operations = value.operations;
        out.* = binding;
        return 1;
    }
    fn unregister(value: *const a.GfxBackendBinding, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(value.*, binding));
        if (quiesced == 0 or job != null) return a.gfx_queue_error_busy;
        registration = null;
        return 1;
    }
    fn update(value: *const a.GfxBackendBinding, value_operations: u64) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(value.*, binding) and value_operations & ~@as(u64, 2047) == 0);
        operations = value_operations;
        return 1;
    }
    pub fn notify() void {
        const reg = registration.?;
        const call: *const fn (usize) callconv(.c) i32 = @ptrFromInt(reg.notify_callback);
        std.debug.assert(call(reg.context) == 0);
    }
    pub fn enqueue(index: usize, empty: bool, deadline: u64) void {
        std.debug.assert(index < closed.len and !closed[index] and job == null and !claimed);
        next_point += 1;
        job = .{ .size = @sizeOf(a.GfxDriverJob), .operation = a.gfx_queue_operation_native, .deadline_ns = deadline, .producer_kind = 1, .producer_id = 200 + index, .producer_generation = 31, .fence = .{ .adapter_id = binding.adapter_id, .timeline = 100 + index, .point = next_point, .device_generation = binding.device_generation, .reset_generation = binding.reset_generation } };
        const header: nv.R4NvNativeSubmitHeader = .{ .version = nv.native_submit_version, .size = 32, .engine_mask = nv.native_engine_graphics, .push_count = if (empty) 0 else 1, .reserved0 = 0, .reserved1 = 0 };
        const push: nv.R4NvNativePush = .{ .address = resource.address, .byte_length = 4, .flags = nv.native_push_no_prefetch };
        @memcpy(command[0..32], std.mem.asBytes(&header));
        @memcpy(command[32..48], std.mem.asBytes(&push));
        info = .{ .interface_id_lo = nv.backend_v1_header.interface_id_lo, .interface_id_hi = nv.backend_v1_header.interface_id_hi, .revision = 1, .command_bytes = if (empty) 32 else 48, .resource_count = if (empty) 0 else 1 };
        signaled = false;
        notify();
    }
    fn take(value: *const a.GfxBackendBinding, out: *a.GfxDriverJob) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(value.*, binding));
        if (job == null or claimed) return a.gfx_queue_error_busy;
        claimed = true;
        out.* = job.?;
        return 1;
    }
    fn valid(fence: *const a.GfxFence) bool {
        return claimed and job != null and std.meta.eql(job.?.fence, fence.*);
    }
    fn readInfo(fence: *const a.GfxFence, out: *a.GfxNativeJobInfo) callconv(.c) i32 {
        if (!valid(fence)) return -1;
        out.* = info;
        return 1;
    }
    fn readData(fence: *const a.GfxFence, offset: u32, out: [*]u8, length: u32) callconv(.c) i32 {
        if (!valid(fence) or length > 1024 or offset > info.command_bytes or length > info.command_bytes - offset) return -1;
        @memcpy(out[0..length], command[offset..][0..length]);
        return 1;
    }
    fn readBinding(fence: *const a.GfxFence, index: u32, out: *a.GfxNativeBinding) callconv(.c) i32 {
        if (!valid(fence) or index >= info.resource_count) return -1;
        out.* = resource;
        return 1;
    }
    fn ownerInfo(value: *const a.GfxBackendBinding, timeline: u64, out: *a.GfxQueueOwnerInfo) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(value.*, binding));
        if (timeline < 100 or timeline >= 100 + closed.len) return 0;
        const index: usize = @intCast(timeline - 100);
        out.* = .{ .timeline = timeline, .producer_kind = 1, .producer_id = 200 + index, .producer_generation = 31, .closing = @intFromBool(closed[index]), .inflight_jobs = @intFromBool(job != null and job.?.fence.timeline == timeline) };
        return 1;
    }
    fn complete(fence: *const a.GfxFence, status: u32, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(valid(fence) and quiesced == 1 and (status != a.gfx_queue_result_complete or signaled));
        completed += 1;
        result = status;
        job = null;
        claimed = false;
        return 1;
    }
};
