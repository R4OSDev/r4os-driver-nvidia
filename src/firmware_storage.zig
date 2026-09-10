// CPU-only GSP container ownership. No GPU DMA mapping or engine admission.
// The memory table is cached before shutdown closes allocation admission.
const std = @import("std");
const r4os = @import("r4os");
const firmware = @import("firmware.zig");
const resources = @import("firmware_resources.zig");
const a = r4os.abi;

pub const Error = firmware.Error || resources.Error || error{ Api, Memory, Mapping };
pub const Storage = struct {
    memory: ?r4os.driver_memory.Context = null,
    reference: a.GfxBufferReference = .{},
    mapping: a.GfxBufferMap = .{},
    reader: ?resources.Reader = null,
    load: ?firmware.Load = null,
    cleanup_needed: bool = false,
    reads: usize = 0,

    pub fn begin(self: *Storage, ctx: *const r4os.r4dev.DriverContext, family: firmware.Family, timeout_ns: u64) Error!void {
        if (self.memory != null or self.cleanup_needed) return error.BadState;
        const source = ctx.resources() orelse return error.Api;
        const now = source.nowNs();
        const deadline = std.math.add(u64, now, timeout_ns) catch return error.InvalidDeadline;
        if (timeout_ns == 0 or deadline == std.math.maxInt(u64)) return error.InvalidDeadline;
        self.reader = try resources.Reader.init(source, family, deadline);
        self.memory = ctx.memory() orelse return error.Api;
        const memory = self.memory.?;
        const bytes = firmware.specification(family).bytes;
        // Even a failed create can leave unpublished VM pages awaiting TLB
        // acknowledgement. Collect must report that exact owner as retained.
        self.cleanup_needed = true;
        const descriptor: a.GfxBufferDescriptor = .{ .byte_length = bytes };
        if (memory.bufferCreate(&descriptor, &self.reference) != a.gfx_buffer_result_ok or self.reference.reference.id == 0) return error.Memory;
        if (memory.bufferMap(&self.reference.reference, a.gfx_buffer_map_write, 0, bytes, &self.mapping) != a.gfx_buffer_result_ok) return error.Mapping;
        if (self.mapping.lease.id == 0 or self.mapping.cpu_address == 0 or self.mapping.byte_length != bytes or self.mapping.cache_policy != a.gfx_buffer_cache_write_back) return error.Mapping;
        const data: [*]u8 = @ptrFromInt(self.mapping.cpu_address);
        self.load = try firmware.Load.begin(family, data[0..bytes], now, timeout_ns);
        self.reads = 0;
    }

    pub fn step(self: *Storage) Error!firmware.Load.State {
        const load = if (self.load) |*value| value else return error.BadState;
        const reader = if (self.reader) |*value| value else return error.BadState;
        self.reads += 1;
        return load.step(reader);
    }

    // This borrowed view lives only until close. Only complete SHA/ELF/ABI
    // admission produces one; neither a mapped buffer nor a short read does.
    pub fn ready(self: *const Storage) ?firmware.Verified {
        if (self.load) |*load| return load.ready();
        return null;
    }

    pub fn close(self: *Storage) bool {
        if (self.load) |*load| load.close();
        self.load = null;
        self.reader = null;
        const memory = self.memory orelse {
            self.* = .{};
            return true;
        };
        if (self.mapping.lease.id != 0) {
            if (memory.bufferUnmap(&self.mapping.lease) != a.gfx_buffer_result_ok) return false;
            self.mapping = .{};
        }
        if (self.reference.reference.id != 0) {
            if (memory.bufferRelease(&self.reference.reference) != a.gfx_buffer_result_ok) return false;
            self.reference = .{};
        }
        if (self.cleanup_needed and memory.collect() != a.gfx_buffer_result_ok) return false;
        self.* = .{};
        return true;
    }
};
