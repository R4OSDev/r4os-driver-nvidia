const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const heap = @import("rm_heap.zig");

// Private C ABI in rm/semaphore.h. The immutable service table is published
// before callbacks start and unbound only after they have quiesced. Handles
// stay in resident CPU allocations; they are never encoded as fake pointers.
pub const ok: i32 = 0;
pub const retry: i32 = 1;
pub const invalid_context: i32 = 2;
pub const invalid: i32 = 3;
pub const irq: u32 = 1;
pub const sleepable: u32 = 2;
var context: ?r4os.r4dev.DriverSemaphoreContext = null;
var failures: u64 = 0;
const Box = extern struct { handle: u64, cookie: u64 };
const cookie_mask: u64 = 0x52344e5653454d41;

pub fn bind(ctx: *const r4os.r4dev.DriverContext) void {
    context = ctx.semaphores();
    @atomicStore(u64, &failures, 0, .monotonic);
}
pub fn unbind() void {
    context = null;
}
pub fn faultCount() u64 {
    return @atomicLoad(u64, &failures, .monotonic);
}
pub fn available() bool {
    return context != null and heap.available() and faultCount() == 0;
}
fn fault() i32 {
    _ = @atomicRmw(u64, &failures, .Add, 1, .monotonic);
    return invalid;
}
fn result(code: i32) i32 {
    return switch (code) {
        a.driver_semaphore_ok => ok,
        a.driver_semaphore_error_timeout, a.driver_semaphore_error_busy => retry,
        a.driver_semaphore_error_context => invalid_context,
        else => fault(),
    };
}
fn box(pointer: ?*anyopaque) ?*Box {
    const address = @intFromPtr(pointer orelse return null);
    if (address & 15 != 0) return null;
    // Trusted live allocation contract, matching RM free. This cookie does not
    // validate arbitrary addresses, ownership races, or already freed memory.
    const value: *Box = @ptrCast(@alignCast(pointer.?));
    return if (value.cookie == address ^ cookie_mask) value else null;
}
pub export fn r4nv_semaphore_create(initial: u32) callconv(.c) ?*anyopaque {
    if (!available()) return null;
    const ctx = if (context) |*value| value else return null;
    if (ctx.contextFlags() & a.driver_semaphore_context_sleepable == 0) return null;
    const pointer = heap.r4nv_heap_allocate(@sizeOf(Box)) orelse return null;
    var handle: u64 = 0;
    const code = ctx.create(initial, std.math.maxInt(u32), &handle);
    if (code != a.driver_semaphore_ok or handle == 0) {
        if (code == a.driver_semaphore_ok or (code != a.driver_semaphore_error_closed and code != a.driver_semaphore_error_memory)) _ = fault();
        if (!heap.release(pointer)) _ = fault();
        return null;
    }
    const value: *Box = @ptrCast(@alignCast(pointer));
    value.* = .{ .handle = handle, .cookie = @intFromPtr(pointer) ^ cookie_mask };
    return pointer;
}
pub export fn r4nv_semaphore_free(pointer: ?*anyopaque) callconv(.c) i32 {
    if (pointer == null) return ok;
    const ctx = if (context) |*value| value else return invalid_context;
    const value = box(pointer) orelse return fault();
    if (value.handle != 0) {
        const code = ctx.destroy(value.handle);
        if (code != a.driver_semaphore_ok) return result(code);
        // The semaphore is gone. If freeing the CPU box fails, retry only that
        // allocation; never destroy the stale kernel semaphore handle again.
        value.handle = 0;
    }
    return if (heap.release(pointer)) ok else fault();
}
pub export fn r4nv_semaphore_acquire(pointer: ?*anyopaque, timeout_ticks: u64) callconv(.c) i32 {
    const ctx = if (context) |*value| value else return invalid_context;
    const value = box(pointer) orelse return fault();
    if (value.handle == 0) return fault();
    return result(ctx.acquire(value.handle, timeout_ticks));
}
pub export fn r4nv_semaphore_release(pointer: ?*anyopaque) callconv(.c) i32 {
    const ctx = if (context) |*value| value else return invalid_context;
    const value = box(pointer) orelse return fault();
    if (value.handle == 0) return fault();
    return result(ctx.release(value.handle));
}
pub export fn r4nv_semaphore_context_flags() callconv(.c) u32 {
    const ctx = if (context) |*value| value else return 0;
    const flags = ctx.contextFlags();
    return (if (flags & a.driver_semaphore_context_irq != 0) irq else @as(u32, 0)) |
        (if (flags & a.driver_semaphore_context_sleepable != 0) sleepable else @as(u32, 0));
}
