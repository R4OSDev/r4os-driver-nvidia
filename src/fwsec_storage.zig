// A separately owned, resident CPU image. Its address is never a GPU address.
const std = @import("std");
const r4os = @import("r4os");
const vbios = @import("vbios.zig");
const preparation = @import("fwsec_prepare.zig");
const dma = @import("fwsec_dma.zig");
const vram = @import("boot_vram_lease.zig");
const a = r4os.abi;
pub const Error = preparation.Error || error{ Api, Memory, Busy, Vram };
pub const Image = struct { image: []const u8, metadata: preparation.Prepared };
pub const Storage = struct {
    heap: ?r4os.r4dev.DriverHeapContext = null,
    allocation: a.DriverHeapAllocation = .{},
    device: dma.Mapping = .{},
    complete: bool = false,
    command: u32 = 0x19,
    self_address: usize = 0,
    frts_owner: ?*vram.Lease = null,
    frts_binding: ?vram.Binding = null,

    pub fn prepare(self: *Storage, ctx: *const r4os.r4dev.DriverContext, rom: []const u8, board: *const vbios.Result, fuses: preparation.Fuses) Error!Image {
        if (self.frts_owner != null) return error.Busy;
        return self.prepareCommand(ctx, rom, board, fuses, .sb);
    }

    /// Cold-boot FRTS uses the exact retained VRAM target, never a caller's
    /// bare offset. Failures retain the borrow with any partially allocated
    /// backing until close. This does not execute FWSEC or establish recovery.
    pub fn prepareFrts(self: *Storage, ctx: *const r4os.r4dev.DriverContext, rom: []const u8, board: *const vbios.Result, fuses: preparation.Fuses, owner: *vram.Lease) Error!Image {
        if (self.heap != null or self.allocation.handle != 0 or self.frts_owner != null) return error.Busy;
        const backing = owner.backing orelse return error.Vram;
        if (backing.context == null or backing.context.?.api != ctx.api) return error.Vram;
        const binding = owner.borrowFrts(@intFromPtr(self)) catch return error.Vram;
        self.self_address = @intFromPtr(self);
        self.frts_owner = owner;
        self.frts_binding = binding;
        const result = try self.prepareCommand(ctx, rom, board, fuses, .{ .frts = binding.range.offset });
        if (!self.preparationValid()) {
            self.complete = false;
            return error.Vram;
        }
        return result;
    }

    fn prepareCommand(self: *Storage, ctx: *const r4os.r4dev.DriverContext, rom: []const u8, board: *const vbios.Result, fuses: preparation.Fuses, command: preparation.Command) Error!Image {
        if (self.heap != null or self.allocation.handle != 0) return error.Busy;
        const selection = try preparation.select(rom, board, fuses);
        const payload = try preparation.commandBytes(command);
        if (selection.entry.interface.command_input.bytes < payload.length) return error.Capacity;
        const length = selection.entry.image.bytes;
        self.heap = ctx.heap() orelse return error.Api;
        if (self.heap.?.allocate(length, 256, &self.allocation) != a.driver_heap_ok) return error.Memory;
        if (self.allocation.handle == 0 or self.allocation.cpu_address == 0 or
            self.allocation.cpu_address & 255 != 0 or self.allocation.byte_length != length or self.allocation.alignment < 256 or
            self.allocation.cpu_address > std.math.maxInt(u64) - @as(u64, length)) return error.Memory;
        const data: [*]u8 = @ptrFromInt(self.allocation.cpu_address);
        const image = data[0..length];
        const metadata = try preparation.prepare(rom, board, fuses, command, image);
        self.command = metadata.command;
        self.complete = true;
        return .{ .image = image, .metadata = metadata };
    }

    pub fn preparationValid(self: *const Storage) bool {
        if (!self.complete) return false;
        if (self.frts_owner) |owner| {
            const binding = self.frts_binding orelse return false;
            return self.self_address == @intFromPtr(self) and self.command == 0x15 and owner.holdsFrts(self.self_address, binding);
        }
        return self.command == 0x19 and self.frts_binding == null;
    }

    pub fn close(self: *Storage) bool {
        if (self.device.execution_owner != 0 or (self.self_address != 0 and self.self_address != @intFromPtr(self))) return false;
        self.complete = false;
        if (!self.device.close()) return false;
        if (self.allocation.handle != 0) {
            const heap = self.heap orelse return false;
            if (heap.release(self.allocation.handle) != a.driver_heap_ok) return false;
            self.allocation = .{}; // A subsequent borrow-release failure must not free twice.
        }
        if (self.frts_owner) |owner| {
            const binding = self.frts_binding orelse return false;
            if (!owner.releaseFrtsBeforeSubmission(self.self_address, binding)) return false;
        }
        self.* = .{};
        return true;
    }
};
