//! Public native BO producer. Driver Work only; existing GSP exchanges own
//! physical allocation and unwind. A cancelled request never proves DMA idle.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const runtime = @import("gsp_runtime.zig");
pub fn operationDeadline(instant: u64, request_deadline: u64) !u64 {
    if (instant == 0 or instant == std.math.maxInt(u64)) return error.Clock;
    if (instant >= request_deadline) return error.Timeout;
    return std.math.add(u64, instant, 5 * std.time.ns_per_s);
}
pub const Owner = struct {
    handle: a.GfxBufferHandle = .{},
    memory: ?r4os.driver_memory.Context = null,
    requested: bool = false,
    closing: bool = false,
    pending: ?struct { job: a.GfxNativeJob, buffer: ?runtime.BufferHandle = null } = null,

    fn notify(raw: usize) callconv(.c) i32 {
        const self: *Owner = @ptrFromInt(raw);
        if (!self.closing) self.requested = true;
        return 0;
    }
    pub fn step(self: *Owner, running: *runtime.Owner) !bool {
        if (self.closing or running.failure != null or running.graph_closing or running.nativeAddressSpace() == null) return false;
        if (self.memory == null) {
            const memory = running.ctx.?.memory() orelse return false;
            if (memory.table.size < @offsetOf(a.GfxDriverMemoryApi, "native_complete") + 8 or memory.table.native_register == 0 or memory.table.native_take == 0 or
                memory.table.native_complete == 0 or memory.table.native_unregister == 0) return false;
            self.memory = memory;
        }
        const memory = self.memory.?;
        if (self.handle.id == 0) {
            const rc = memory.nativeRegister(&.{ .adapter_id = running.adapter_id, .memory_generation = running.epoch, .notify = @intFromPtr(&notify), .context = @intFromPtr(self) }, &self.handle);
            if (rc == a.gfx_buffer_error_busy or rc == a.gfx_buffer_error_unavailable) return false;
            if (rc != 1) return error.Api;
            return true;
        }
        if (self.pending == null) {
            if (!self.requested) return false;
            var job: a.GfxNativeJob = .{};
            const rc = memory.nativeTake(&self.handle, &job);
            if (rc == a.gfx_buffer_error_busy) {
                self.requested = false;
                return false;
            }
            if (rc != 1) return error.Api;
            self.pending = .{ .job = job };
        }
        const pending = &self.pending.?;
        if (pending.buffer) |handle| {
            const status = running.nativeBufferStatus(handle) catch return error.Retained;
            if (status.state != .handed_off) return false;
            const result: i32 = if (status.info != null) 1 else status.host_rejected orelse a.gfx_buffer_error_oom;
            const reference: a.GfxBufferHandle = if (status.info) |info| info.reference.reference else .{};
            if (memory.nativeComplete(&self.handle, &pending.job.request, result, &reference) != 1) return error.Retained;
            // Complete only borrows this reference. Common imports survive
            // the initial close and feed queuedInfo in the existing CE path.
            try running.releaseNativeBuffer(handle);
            self.pending = null;
            return true;
        }
        const request = pending.job.allocation;
        const clock = running.ctx.?.resources() orelse return error.Api;
        const instant = clock.nowNs();
        if (instant >= request.deadline_ns) {
            if (memory.nativeComplete(&self.handle, &pending.job.request, a.gfx_queue_error_wait_timeout, &.{}) != 1) return error.Retained;
            self.pending = null;
            return true;
        }
        // The application's deadline closes its logical result. A submitted
        // RM exchange keeps its own finite budget for completion and unwind.
        const operation_deadline = try operationDeadline(instant, request.deadline_ns);
        pending.buffer = allocate(running, request, operation_deadline) catch |err| {
            if (err == error.Busy) return false;
            const result: i32 = switch (err) {
                error.Unsupported => a.gfx_buffer_error_unsupported,
                error.Budget => a.gfx_buffer_error_budget,
                error.Exhausted, error.Memory => a.gfx_buffer_error_oom,
                error.Overflow, error.Bounds => a.gfx_buffer_error_overflow,
                else => a.gfx_buffer_error_invalid,
            };
            // openNativeBuffer returns a handle once firmware work is owned.
            // A transport failure is retained by running.stop, never hidden.
            if (running.failure != null) return error.Retained;
            if (memory.nativeComplete(&self.handle, &pending.job.request, result, &.{}) != 1) return error.Retained;
            self.pending = null;
            return true;
        };
        return true;
    }
    fn allocate(running: *runtime.Owner, request: a.GfxNativeAllocation, deadline: u64) !runtime.BufferHandle {
        if (request.adapter_id != running.adapter_id or request.memory_generation != running.epoch) return error.Invalid;
        if (request.kind == 0) {
            if (request.usage != 12 or request.layout != 0) return error.Unsupported;
            return running.allocateNativeBuffer(request.byte_length, deadline);
        }
        const format = std.enums.fromInt(runtime.vram.surface.Format, request.format) orelse return error.Unsupported;
        const surface: runtime.vram.surface.Request = .{ .width = request.width, .height = request.height, .format = format, .usage = request.usage, .layout = if (request.layout == 0) .linear else .blocklinear };
        // The common descriptor remains renderable. Only the scanout role
        // requests a verified contiguous physical extent from RM.
        if (request.usage & a.gfx_buffer_usage_scanout != 0)
            return running.allocateDisplaySurface(surface, deadline);
        return running.allocateNativeSurface(surface, deadline);
    }
    pub fn close(self: *Owner) void {
        self.closing = true;
        const memory = self.memory orelse return;
        if (self.pending) |pending| if (pending.buffer == null) {
            if (memory.nativeComplete(&self.handle, &pending.job.request, a.gfx_queue_error_device_lost, &.{}) == 1) self.pending = null;
        };
        if (self.handle.id != 0 and memory.nativeUnregister(&self.handle) == 1) self.handle = .{};
    }
};
