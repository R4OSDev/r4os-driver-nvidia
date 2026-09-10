const std = @import("std");
const r4os = @import("r4os");
const firmware = @import("firmware.zig");
const a = r4os.abi;
const Context = r4os.r4dev.DriverResourceContext;
pub const lock_bytes = @embedFile("firmware-lock.json");
pub const Error = error{ Resource, Lock, Size, Clock, Name };

// Caller supplies the absolute deadline and final CPU storage to firmware.Load.
// This adapter never opens a path or substitutes a different firmware package.
pub const Reader = struct {
    context: Context,
    name: []const u8,
    info: a.DriverResourceInfo,
    last_status: i32 = 0,

    pub fn init(context: Context, family: firmware.Family, deadline_ns: u64) Error!Reader {
        const generation = try validateLock(context, deadline_ns);
        const specification = firmware.specification(family);
        var info: a.DriverResourceInfo = .{};
        if (context.stat(specification.resource, &info) != a.driver_resource_ok) return error.Resource;
        if (info.byte_length != specification.bytes or info.handle == 0 or info.module_generation != generation) return error.Size;
        return .{ .context = context, .name = specification.resource, .info = info };
    }
    pub fn nowNs(self: *const Reader) u64 {
        return self.context.nowNs();
    }
    pub fn readAt(self: *Reader, name: []const u8, offset: usize, output: []u8, deadline_ns: u64) Error!usize {
        if (!std.mem.eql(u8, name, self.name)) return error.Name;
        self.last_status = self.context.readAt(self.info.handle, offset, output, deadline_ns);
        if (self.last_status < 0) return error.Resource;
        return @intCast(self.last_status);
    }
};

pub fn validateLock(context: Context, deadline_ns: u64) Error!u64 {
    const started = context.nowNs();
    if (deadline_ns == 0 or deadline_ns == std.math.maxInt(u64) or started >= deadline_ns) return error.Clock;
    var info: a.DriverResourceInfo = .{};
    if (context.stat("NVFW-LOCK.json", &info) != a.driver_resource_ok) return error.Resource;
    if (info.byte_length != lock_bytes.len or info.handle == 0 or info.module_generation == 0) return error.Lock;
    var actual: [lock_bytes.len]u8 = undefined;
    if (context.readAt(info.handle, 0, &actual, deadline_ns) != actual.len) return error.Resource;
    const ended = context.nowNs();
    if (ended < started or ended >= deadline_ns) return error.Clock;
    if (!std.mem.eql(u8, &actual, lock_bytes)) return error.Lock;
    return info.module_generation;
}
