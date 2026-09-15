const std = @import("std");
const r4os = @import("r4os");
const firmware = @import("firmware.zig");
const a = r4os.abi;
const Context = r4os.r4dev.DriverResourceContext;
pub const lock_bytes = @embedFile("firmware-lock.json");
pub const Error = error{ Resource, Lock, Size, Clock, Name, Generation };

pub const Location = struct { resource: []const u8, total: usize, offset: usize };
// The embedded, validated lock is the directory. Bundles have no separately
// trusted index: 18 original files in this order, each starting on 16 bytes.
// Only the requested slice is read and checked against its original hash.
pub fn artifacts(profile: *const firmware.BootGeneration) [18]*const firmware.Artifact {
    var out: [18]*const firmware.Artifact = undefined;
    out[0..3].* = .{ &profile.boot.image, &profile.boot.descriptor, &profile.boot.license };
    var next: usize = 3;
    for (&profile.booters) |*item| inline for (.{ "image", "header", "signatures", "patch_location", "patch_signature", "patch_metadata", "signature_count" }) |field| {
        out[next] = &@field(item.*, field);
        next += 1;
    };
    out[17] = &profile.booter_license.artifact;
    return out;
}
pub fn location(spec: *const firmware.Artifact) Error!Location {
    for (&firmware.lock.boot_generations) |*profile| {
        var offset: usize = 0;
        var found: ?usize = null;
        for (artifacts(profile)) |item| {
            offset = std.mem.alignForward(usize, offset, 16);
            if (item.bytes == 0 or offset > profile.pack.bytes or item.bytes > profile.pack.bytes - offset) return error.Size;
            if (std.mem.eql(u8, item.resource, spec.resource)) {
                if (found != null or item.bytes != spec.bytes or !std.mem.eql(u8, item.sha256, spec.sha256)) return error.Size;
                found = offset;
            }
            offset += item.bytes;
        }
        if (profile.pack.bytes > 2 * 1024 * 1024 or offset != profile.pack.bytes) return error.Size;
        if (found) |base| return .{ .resource = profile.pack.resource, .total = profile.pack.bytes, .offset = base };
    }
    return .{ .resource = spec.resource, .total = spec.bytes, .offset = 0 };
}
pub fn openArtifact(context: Context, spec: *const firmware.Artifact, generation: u64) Error!struct { info: a.DriverResourceInfo, offset: usize } {
    const where = try location(spec);
    var info: a.DriverResourceInfo = .{};
    if (context.stat(where.resource, &info) != a.driver_resource_ok) return error.Resource;
    if (info.version != 1 or info.size < @sizeOf(a.DriverResourceInfo) or info.handle == 0 or info.byte_length != where.total) return error.Size;
    if (generation == 0 or info.module_generation != generation) return error.Generation;
    return .{ .info = info, .offset = where.offset };
}

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
    // The generation catalog grows with supported chips. Keep the driver's
    // stack bounded; immutable module resources permit a chunk comparison.
    var actual: [1024]u8 = undefined;
    var offset: usize = 0;
    var last = started;
    while (offset < lock_bytes.len) {
        const length = @min(actual.len, lock_bytes.len - offset);
        if (context.readAt(info.handle, offset, actual[0..length], deadline_ns) != length) return error.Resource;
        const ended = context.nowNs();
        if (ended < last or ended >= deadline_ns) return error.Clock;
        if (!std.mem.eql(u8, actual[0..length], lock_bytes[offset..][0..length])) return error.Lock;
        offset += length; last = ended;
    }
    return info.module_generation;
}
