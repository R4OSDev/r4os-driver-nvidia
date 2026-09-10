const r4os = @import("r4os");
const a = r4os.abi;

// Published before callbacks; retained until all workers and dedicated native
// invocations are retired. The kernel derives the real current driver owner.
var api: ?*const a.DriverApi = null;
var records: u64 = 0;
pub fn bind(ctx: *const r4os.r4dev.DriverContext) void {
    api = ctx.api;
    @atomicStore(u64, &records, 0, .monotonic);
}
pub fn unbind() void {
    api = null;
}
pub fn recordCount() u64 {
    return @atomicLoad(u64, &records, .monotonic);
}
pub export fn r4nv_log(severity: u32, text: ?[*:0]const u8) callconv(.c) i32 {
    const bound = api orelse return -1;
    const input = text orelse return -1;
    if (severity > 2) return -1;
    // Bounded copy also makes out_string safe for the kernel's lookahead.
    // Its caller still owes a readable C string; this is not a pointer probe.
    var buffer: [513:0]u8 = undefined;
    var length: usize = 0;
    while (length < 512 and input[length] != 0) : (length += 1) {
        buffer[length] = input[length];
    }
    if (length == 512) {
        const marker = " [truncated]";
        @memcpy(buffer[512 - marker.len .. 512], marker);
    }
    buffer[length] = 0;
    const ctx = r4os.r4dev.DriverContext.init(bound);
    switch (severity) {
        0 => ctx.logInfo(@ptrCast(&buffer)),
        1 => ctx.logWarn(@ptrCast(&buffer)),
        2 => ctx.logError(@ptrCast(&buffer)),
        else => unreachable,
    }
    _ = @atomicRmw(u64, &records, .Add, 1, .monotonic);
    return @intCast(length);
}
