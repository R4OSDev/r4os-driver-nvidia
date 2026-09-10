// A separately owned, resident CPU image. Its address is never a GPU address.
const std = @import("std");
const r4os = @import("r4os");
const vbios = @import("vbios.zig");
const preparation = @import("fwsec_prepare.zig");
const dma = @import("fwsec_dma.zig");
const a = r4os.abi;
pub const Error = preparation.Error || error{ Api, Memory, Busy };
pub const Storage = struct {
    heap: ?r4os.r4dev.DriverHeapContext = null,
    allocation: a.DriverHeapAllocation = .{},
    device: dma.Mapping = .{},
    complete: bool = false,

    pub fn prepare(self: *Storage, ctx: *const r4os.r4dev.DriverContext, rom: []const u8, board: *const vbios.Result, fuses: preparation.Fuses) Error!struct { image: []const u8, metadata: preparation.Prepared } {
        if (self.heap != null or self.allocation.handle != 0) return error.Busy;
        const selection = try preparation.select(rom, board, fuses);
        if (selection.entry.interface.command_input.bytes < 24) return error.Capacity;
        const length = selection.entry.image.bytes;
        self.heap = ctx.heap() orelse return error.Api;
        if (self.heap.?.allocate(length, 256, &self.allocation) != a.driver_heap_ok) return error.Memory;
        if (self.allocation.handle == 0 or self.allocation.cpu_address == 0 or
            self.allocation.cpu_address & 255 != 0 or self.allocation.byte_length != length or self.allocation.alignment < 256 or
            self.allocation.cpu_address > std.math.maxInt(u64) - @as(u64, length)) return error.Memory;
        const data: [*]u8 = @ptrFromInt(self.allocation.cpu_address);
        const image = data[0..length];
        // SB needs no invented FB region. FRTS stays a pure encoding facility
        // until an actual GPU allocation and its WPR ownership exist.
        const metadata = try preparation.prepare(rom, board, fuses, .sb, image);
        self.complete = true;
        return .{ .image = image, .metadata = metadata };
    }

    pub fn close(self: *Storage) bool {
        self.complete = false;
        if (!self.device.close()) return false;
        if (self.allocation.handle != 0) {
            const heap = self.heap orelse return false;
            if (heap.release(self.allocation.handle) != a.driver_heap_ok) return false;
        }
        self.* = .{};
        return true;
    }
};
