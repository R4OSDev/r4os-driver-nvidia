// A read-only PROM aperture, admitted only after actual GA106 identity and
// current ReBAR bounds. No PCI shadow selection, PRAMIN writes or ROM execution.
const std = @import("std");
const r4os = @import("r4os");
const identity = @import("identity.zig");
const vbios = @import("vbios.zig");
const a = r4os.abi;
pub const prom_offset = 0x300000;
pub const Error = error{ UnmeasuredRange, Api, Memory, Mapping, Clock, Deadline, Unstable };

pub fn admitted(snapshot: *const identity.Snapshot, chip: identity.Chip) bool {
    const bar = snapshot.bars[0];
    return identity.decision(snapshot) == .identity_words_only and chip.id == 0x176 and
        bar.bytes >= prom_offset + vbios.max_rom_bytes and
        bar.base <= std.math.maxInt(u64) - bar.bytes;
}

pub const Capture = struct {
    heap: ?r4os.r4dev.DriverHeapContext = null,
    memory: ?r4os.driver_memory.Context = null,
    allocation: a.DriverHeapAllocation = .{},
    window: a.GfxMmioWindow = .{},
    cleanup_needed: bool = false,
    complete: bool = false,

    pub fn read(self: *Capture, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip) Error![]const u8 {
        if (!admitted(snapshot, chip)) return error.UnmeasuredRange;
        if (self.heap != null or self.cleanup_needed) return error.Memory;
        const clock = ctx.resources() orelse return error.Api;
        const start = clock.nowNs();
        if (start == 0 or start == std.math.maxInt(u64)) return error.Clock;
        const deadline = std.math.add(u64, start, 10 * std.time.ns_per_s) catch return error.Clock;
        self.heap = ctx.heap() orelse return error.Api;
        self.memory = ctx.memory() orelse return error.Api;
        if (self.heap.?.allocate(vbios.max_rom_bytes, 16, &self.allocation) != a.driver_heap_ok) return error.Memory;
        if (self.allocation.handle == 0 or self.allocation.cpu_address == 0 or
            self.allocation.cpu_address & 15 != 0 or self.allocation.byte_length != vbios.max_rom_bytes or
            self.allocation.cpu_address > std.math.maxInt(u64) - vbios.max_rom_bytes) return error.Memory;
        const request: a.GfxMmioRequest = .{
            .resource_base = snapshot.bars[0].base,
            .resource_bytes = snapshot.bars[0].bytes,
            .byte_offset = prom_offset,
            .byte_length = vbios.max_rom_bytes,
            .cache_policy = a.gfx_buffer_cache_uncached,
        };
        // Even failed maps may retain unpublished pages until collect succeeds.
        self.cleanup_needed = true;
        if (self.memory.?.mmioMap(&request, &self.window) != a.gfx_buffer_result_ok) return error.Mapping;
        if (self.window.handle.id == 0 or self.window.cpu_address == 0 or self.window.cpu_address & 3 != 0 or
            self.window.byte_length != vbios.max_rom_bytes or self.window.physical_address != request.resource_base + prom_offset or
            self.window.cache_policy != a.gfx_buffer_cache_uncached or
            self.window.cpu_address > std.math.maxInt(u64) - vbios.max_rom_bytes) return error.Mapping;
        const words: [*]const volatile u32 = @ptrFromInt(self.window.cpu_address);
        const copy: [*]u32 = @ptrFromInt(self.allocation.cpu_address);
        var previous = start;
        for (0..2) |pass| {
            for (0..vbios.max_rom_bytes / 4) |index| {
                if (index & 255 == 0) {
                    const now = clock.nowNs();
                    if (now == std.math.maxInt(u64) or now < previous) return error.Clock;
                    if (now >= deadline) return error.Deadline;
                    previous = now;
                }
                const value = words[index];
                if (pass == 0) copy[index] = value else if (copy[index] != value) return error.Unstable;
            }
        }
        const finish = clock.nowNs();
        if (finish == std.math.maxInt(u64) or finish < previous) return error.Clock;
        if (finish >= deadline) return error.Deadline;
        self.complete = true;
        const bytes: [*]const u8 = @ptrFromInt(self.allocation.cpu_address);
        return bytes[0..vbios.max_rom_bytes];
    }

    // The caller must finish parsing/logging before close invalidates the view.
    // Failed unmap/collect/free retains its exact state for the same shutdown.
    pub fn close(self: *Capture) bool {
        self.complete = false;
        if (self.memory) |memory| {
            if (self.window.handle.id != 0) {
                if (memory.mmioUnmap(&self.window.handle, 1) != a.gfx_buffer_result_ok) return false;
                self.window = .{};
            }
            if (self.cleanup_needed and memory.collect() != a.gfx_buffer_result_ok) return false;
            self.cleanup_needed = false;
        }
        if (self.allocation.handle != 0) {
            const heap = self.heap orelse return false;
            if (heap.release(self.allocation.handle) != a.driver_heap_ok) return false;
            self.allocation = .{};
        }
        self.* = .{};
        return true;
    }
};
