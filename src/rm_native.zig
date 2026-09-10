const r4os = @import("r4os");
const a = r4os.abi;

// The caller owns each invocation until its dedicated Task has retired. The
// entry check also rejects queued ordinary calls after a latched failure.
// Already admitted callbacks finish cooperatively; cleanup is explicit.
pub const Invocation = struct {
    handler: *const fn (usize) callconv(.c) i32,
    context: usize,
    cleanup: bool = false,
};
pub const aborted: i32 = -76001;
var threads: ?r4os.r4dev.DriverThreadContext = null;
var first_fault: u64 = 0;
var faults: u64 = 0;

pub fn bind(ctx: *const r4os.r4dev.DriverContext) void {
    const candidate = ctx.threads();
    threads = if (candidate != null and candidate.?.canAbort()) candidate else null;
    @atomicStore(u64, &first_fault, 0, .release);
    @atomicStore(u64, &faults, 0, .monotonic);
}
pub fn unbind() void {
    // The owner must first join and retire every invocation, including any
    // interrupted callback's peers. This never releases their resources.
    threads = null;
}
pub fn available() bool {
    return threads != null;
}
pub fn firstFault() u64 {
    return @atomicLoad(u64, &first_fault, .acquire);
}
pub fn faultCount() u64 {
    return @atomicLoad(u64, &faults, .monotonic);
}
pub fn start(invocation: *const Invocation, flags: u32, handle: *u64) i32 {
    handle.* = 0;
    const service = threads orelse return a.err_no_fn;
    if (!invocation.cleanup and firstFault() != 0) return a.driver_thread_error_closed;
    return service.start(enter, @intFromPtr(invocation), flags | a.driver_thread_flag_abortable, handle);
}
fn enter(context: usize) callconv(.c) i32 {
    const invocation: *const Invocation = @ptrFromInt(context);
    if (!invocation.cleanup and firstFault() != 0) return a.driver_thread_error_closed;
    return invocation.handler(invocation.context);
}

pub export fn r4nv_native_fault(operation: u32, result: i32) callconv(.c) noreturn {
    const encoded = (@as(u64, operation) << 32) | @as(u32, @bitCast(result));
    // All defined operations are nonzero. Zero would lose the fault latch.
    if (operation == 0) @trap();
    _ = @cmpxchgStrong(u64, &first_fault, 0, encoded, .acq_rel, .acquire);
    _ = @atomicRmw(u64, &faults, .Add, 1, .monotonic);
    if (threads) |service| _ = service.abortCurrent(aborted);
    // Reaching here is a programming/ABI violation: missing boundary, IRQ,
    // kernel critical section, or non-abortable Task. A legitimate admitted
    // fault returns through the kernel's Task epilogue and cannot reach this.
    // Never return a fake permit or park an unfinishable callback forever.
    @trap();
}
