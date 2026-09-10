const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;

// The private C hooks in rm/memory.h use the same actual R4D heap service in
// init and work callbacks. This immutable table is published before work and
// cleared only after callbacks have quiesced. It grants no caller ownership.
var context: ?r4os.r4dev.DriverHeapContext = null;
var failed_releases: u64 = 0;
const Header = extern struct { handle: u64, cookie: u64 };
const cookie_mask: u64 = 0x52344E5648454150;
comptime {
    if (@sizeOf(Header) != 16) @compileError("RM heap CPU alignment prefix drift");
}

pub fn bind(ctx: *const r4os.r4dev.DriverContext) void {
    context = ctx.heap();
    @atomicStore(u64, &failed_releases, 0, .monotonic);
}
pub fn unbind() void {
    context = null;
}
pub fn available() bool {
    return context != null;
}
pub fn releaseFailures() u64 {
    return @atomicLoad(u64, &failed_releases, .monotonic);
}

pub export fn r4nv_heap_allocate(bytes: u64) callconv(.c) ?*anyopaque {
    const ctx = context orelse return null;
    const requested = std.math.add(u64, @max(bytes, 1), @sizeOf(Header)) catch return null;
    var allocation: a.DriverHeapAllocation = .{};
    if (ctx.allocate(requested, 16, &allocation) != a.driver_heap_ok) return null;
    if (allocation.handle == 0 or allocation.cpu_address == 0 or allocation.cpu_address & 15 != 0 or
        allocation.byte_length != requested or allocation.cpu_address > std.math.maxInt(u64) - requested)
    {
        if (allocation.handle != 0 and ctx.release(allocation.handle) != a.driver_heap_ok) _ = @atomicRmw(u64, &failed_releases, .Add, 1, .monotonic);
        return null;
    }
    const header: *Header = @ptrFromInt(allocation.cpu_address);
    header.* = .{ .handle = allocation.handle, .cookie = allocation.handle ^ allocation.cpu_address ^ cookie_mask };
    return @ptrFromInt(allocation.cpu_address + @sizeOf(Header));
}

pub export fn r4nv_heap_free(pointer: ?*anyopaque) callconv(.c) void {
    const address = @intFromPtr(pointer orelse return);
    const ctx = context orelse return;
    if (address < @sizeOf(Header) or address & 15 != 0) {
        _ = @atomicRmw(u64, &failed_releases, .Add, 1, .monotonic);
        return;
    }
    // Like the upstream free contract, the caller must supply a live pointer
    // from this allocator. The cookie detects damaged prefix metadata, not
    // arbitrary or already freed pointers. Never dereference after release.
    const header: *const Header = @ptrFromInt(address - @sizeOf(Header));
    const handle = header.handle;
    if (handle == 0 or header.cookie != (handle ^ (address - @sizeOf(Header)) ^ cookie_mask) or ctx.release(handle) != a.driver_heap_ok) {
        // Failed free retains the exact kernel-owned allocation for retry or
        // quiesced owner cleanup, despite the upstream void return type.
        _ = @atomicRmw(u64, &failed_releases, .Add, 1, .monotonic);
    }
}
