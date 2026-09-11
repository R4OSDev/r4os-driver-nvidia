//! Boot inputs from the current R4D's immutable resource table only. The
//! complete license and production image/descriptor share the validated lock's
//! module generation. No filesystem path, download or substitute is accepted.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const firmware = @import("firmware.zig");
const resources = @import("firmware_resources.zig");
const boot = @import("gsp_boot.zig");
const Context = r4os.r4dev.DriverResourceContext;
const capacity = @max(boot.image.bytes, firmware.lock.boot.license.bytes);
pub const Error = boot.Error || resources.Error || error{ Api, Busy, InvalidDeadline, Timeout, ClockRegression, Generation, ShortRead };
pub const View = struct { image: []const u8, descriptor: []const u8, info: boot.Info };
pub const Inputs = struct {
    data: [capacity]u8 = @splat(0),
    descriptor: [boot.descriptor.bytes]u8 = @splat(0),
    active: bool = false,
    admitted: bool = false,
    generation: u64 = 0,
    reads: usize = 0,
    last_clock: u64 = 0,

    fn checkClock(self: *Inputs, ctx: Context, deadline: u64) Error!void {
        const now = ctx.nowNs();
        if (now == std.math.maxInt(u64)) return error.InvalidDeadline;
        if (now < self.last_clock) return error.ClockRegression;
        if (now >= deadline) return error.Timeout;
        self.last_clock = now;
    }
    fn read(self: *Inputs, ctx: Context, spec: *const firmware.Artifact, output: []u8, deadline: u64) Error!void {
        try self.checkClock(ctx, deadline);
        if (output.len != spec.bytes) return error.Size;
        var info: a.DriverResourceInfo = .{};
        if (ctx.stat(spec.resource, &info) != a.driver_resource_ok) return error.Resource;
        if (info.version != 1 or info.size < @sizeOf(a.DriverResourceInfo) or info.handle == 0 or info.byte_length != spec.bytes) return error.Size;
        if (info.module_generation != self.generation) return error.Generation;
        try self.checkClock(ctx, deadline);
        self.reads += 1;
        const count = ctx.readAt(info.handle, 0, output, deadline);
        if (count < 0) return error.Resource;
        if (count != output.len) return error.ShortRead;
        try self.checkClock(ctx, deadline);
        if (!firmware.digestMatches(output, spec.sha256)) return error.WrongHash;
        try self.checkClock(ctx, deadline);
    }

    /// The returned view borrows these resident inputs until close. The DMA
    /// boot owner copies them; no input pointer is ever a device address.
    pub fn load(self: *Inputs, driver: *const r4os.r4dev.DriverContext, timeout_ns: u64) Error!View {
        if (self.active) return error.Busy;
        self.active = true;
        const ctx = driver.resources() orelse return error.Api;
        self.last_clock = ctx.nowNs();
        const deadline = std.math.add(u64, self.last_clock, timeout_ns) catch return error.InvalidDeadline;
        if (timeout_ns == 0 or deadline == std.math.maxInt(u64)) return error.InvalidDeadline;
        self.generation = try resources.validateLock(ctx, deadline);
        // Reuse the image storage for license admission before loading code.
        try self.read(ctx, &firmware.lock.boot.license, self.data[0..firmware.lock.boot.license.bytes], deadline);
        try self.read(ctx, &boot.image, self.data[0..boot.image.bytes], deadline);
        try self.read(ctx, &boot.descriptor, &self.descriptor, deadline);
        const info = try boot.verify(self.data[0..boot.image.bytes], &self.descriptor);
        try self.checkClock(ctx, deadline);
        self.admitted = true;
        return .{ .image = self.data[0..boot.image.bytes], .descriptor = &self.descriptor, .info = info };
    }

    pub fn close(self: *Inputs) void {
        @memset(&self.data, 0);
        @memset(&self.descriptor, 0);
        self.active = false;
        self.admitted = false;
        self.generation = 0;
        self.reads = 0;
        self.last_clock = 0;
    }
};

test "firmware CPU storage boot resource reads keep exact generation, hash and deadline admission" {
    const t = std.testing;
    const Fault = enum { none, stat, header, size, generation, read, short, hash, regression, timeout };
    const Mock = struct {
        var fault: Fault = .none;
        var clock: u64 = 100;
        const body = "synthetic-boot-resource";
        fn now() callconv(.c) u64 {
            return clock;
        }
        fn query(out: *a.DriverResourceApi) callconv(.c) i32 {
            out.* = .{ .stat = @intFromPtr(&stat), .read_at = @intFromPtr(&read), .now_ns = @intFromPtr(&now) };
            return 0;
        }
        fn stat(name: [*]const u8, length: u32, out: *a.DriverResourceInfo) callconv(.c) i32 {
            std.debug.assert(std.mem.eql(u8, name[0..length], "BOOT-FIXTURE.bin"));
            if (fault == .stat) return a.driver_resource_error_not_found;
            out.* = .{ .handle = 3, .byte_length = body.len, .module_generation = 7 };
            switch (fault) {
                .header => out.version = 2,
                .size => out.byte_length += 1,
                .generation => out.module_generation += 1,
                else => {},
            }
            return 0;
        }
        fn read(handle: u64, offset: u64, output: [*]u8, length: u32, deadline: u64) callconv(.c) i32 {
            std.debug.assert(handle == 3 and offset == 0 and length == body.len and deadline == 1100);
            @memcpy(output[0..length], body);
            switch (fault) {
                .read => return a.driver_resource_error_io,
                .short => return @as(i32, @intCast(length)) - 1,
                .hash => output[0] ^= 1,
                .regression => clock = 99,
                .timeout => clock = 1100,
                else => {},
            }
            return @intCast(length);
        }
    };
    var table: a.DriverApi = undefined;
    table.magic = a.driver_magic;
    table.version = 34;
    table.size = @sizeOf(a.DriverApi);
    table.resource_query = Mock.query;
    const driver = r4os.r4dev.DriverContext.init(&table);
    const ctx = driver.resources().?;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(Mock.body, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    const spec = firmware.Artifact{ .file = "fixture.bin", .resource = "BOOT-FIXTURE.bin", .bytes = Mock.body.len, .sha256 = &hash };
    for (std.enums.values(Fault)) |case| {
        Mock.fault = case;
        Mock.clock = 100;
        var inputs: Inputs = .{ .active = true, .generation = 7, .last_clock = 100 };
        const result = inputs.read(ctx, &spec, inputs.data[0..Mock.body.len], 1100);
        const expected: ?anyerror = switch (case) {
            .stat, .read => error.Resource,
            .header, .size => error.Size,
            .generation => error.Generation,
            .short => error.ShortRead,
            .hash => error.WrongHash,
            .regression => error.ClockRegression,
            .timeout => error.Timeout,
            .none => null,
        };
        if (expected) |failure| try t.expectError(failure, result) else {
            try result;
            try t.expectEqualStrings(Mock.body, inputs.data[0..Mock.body.len]);
        }
        try t.expect(!inputs.admitted);
        try t.expectError(error.Busy, inputs.load(&driver, 1000));
        inputs.close();
        inputs.close();
        try t.expect(!inputs.active and !inputs.admitted and inputs.generation == 0);
        try t.expect(std.mem.allEqual(u8, &inputs.data, 0));
        try t.expect(std.mem.allEqual(u8, &inputs.descriptor, 0));
    }
    Mock.clock = 100;
    var inputs: Inputs = .{};
    try t.expectError(error.InvalidDeadline, inputs.load(&driver, 0));
    inputs.close();
}
