//! Common-broker peer for the existing actual Device test. RM responses are
//! still driven through the real runtime below this peer; no GPU is modeled.
const std = @import("std");
const a = @import("r4os").abi;
pub const Model = struct {
    var original: a.DriverApi = undefined;
    var config: ?a.GfxNativeProvider = null;
    pub var closing = false;
    pub var queued: ?a.GfxVirtualJob = null;
    pub var claim: ?a.GfxVirtualJob = null;
    pub var completion: ?a.GfxVirtualCompletion = null;
    pub var completed: usize = 0;
    const Resource = struct { job: a.GfxVirtualJob, token: a.GfxVirtualToken };
    var live: [4]?Resource = @splat(null);
    const provider: a.GfxBufferHandle = .{ .id = 37, .generation = 91 };
    pub fn install(table: *a.DriverApi) void {
        original = table.*; table.gfx_memory_query = memory;
        config = null; closing = false; queued = null; claim = null; completion = null;
        completed = 0; live = @splat(null);
    }
    pub fn dispose(table: *a.DriverApi) void { table.* = original; }
    fn memory(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        if (original.gfx_memory_query.?(out) != 1) return -1;
        out.virtual_register = @intFromPtr(&register); out.virtual_unregister = @intFromPtr(&unregister);
        out.virtual_take = @intFromPtr(&take); out.virtual_complete = @intFromPtr(&complete);
        return 1;
    }
    fn register(input: *const a.GfxNativeProvider, out: *a.GfxBufferHandle) callconv(.c) i32 {
        std.debug.assert(config == null and input.adapter_id == 0x01000000 and input.memory_generation != 0 and input.notify != 0);
        config = input.*; out.* = provider; return 1;
    }
    fn unregister(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        std.debug.assert(config != null and std.meta.eql(input.*, provider));
        closing = true;
        if (queued != null or claim != null) return a.gfx_buffer_error_busy;
        for (&live) |*value| if (value.* != null) return a.gfx_buffer_error_busy;
        config = null; return 1;
    }
    pub fn submit(job: a.GfxVirtualJob) void {
        std.debug.assert(config != null and queued == null and claim == null and !closing);
        queued = job; completion = null;
        const notify: *const fn (usize) callconv(.c) i32 = @ptrFromInt(config.?.notify);
        std.debug.assert(notify(config.?.context) == 0);
    }
    fn take(input: *const a.GfxBufferHandle, out: *a.GfxVirtualJob) callconv(.c) i32 {
        std.debug.assert(config != null and std.meta.eql(input.*, provider) and claim == null);
        if (closing and queued == null) {
            // Parent retirement follows every child's physical completion.
            for ([_]u32{ 2, 1 }) |kind| {
                for (&live) |*value| if (value.*) |entry| {
                    if (entry.job.request.kind != kind) continue;
                    queued = entry.job; queued.?.operation = 1; queued.?.token = entry.token;
                    break;
                };
                if (queued != null) break;
            }
        }
        const job = queued orelse return a.gfx_buffer_error_busy;
        queued = null; claim = job; out.* = job; return 1;
    }
    fn complete(input: *const a.GfxBufferHandle, result: *const a.GfxVirtualCompletion) callconv(.c) i32 {
        std.debug.assert(config != null and std.meta.eql(input.*, provider));
        const job = claim.?;
        std.debug.assert(std.meta.eql(job.resource, result.resource) and job.operation == result.operation);
        if (job.operation == 1) {
            std.debug.assert(result.result == 1 and result.address == 0 and std.meta.eql(job.token, result.token));
            var found = false;
            for (&live) |*value| if (value.*) |entry| {
                if (!std.meta.eql(entry.token, job.token)) continue;
                value.* = null; found = true; break;
            };
            std.debug.assert(found);
        } else if (result.result == 1) {
            std.debug.assert(result.address != 0 and result.token.opaque0 == job.request.memory_generation and result.token.opaque1 != 0);
            var stored = false;
            for (&live) |*value| if (value.* == null) { value.* = .{ .job = job, .token = result.token }; stored = true; break; };
            std.debug.assert(stored);
        } else std.debug.assert(result.result < 0 and std.meta.eql(result.token, a.GfxVirtualToken{}) and result.address == 0);
        completion = result.*; claim = null; completed += 1;
        return 1;
    }
};
