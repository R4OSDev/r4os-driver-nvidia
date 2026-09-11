// Bounded read-only GA106 GSP/VRAM preflight. No memory ports, command writes,
// write-only aliases, reset, DMA submission or address-window remapping.
const std = @import("std");
const r4os = @import("r4os");
const identity = @import("identity.zig");
const state = @import("fwsec_state.zig");
const bar0 = @import("bar0.zig");
const a = r4os.abi;
pub const Error = bar0.Error || error{ UnmeasuredRange, Api, Mapping, Clock, Deadline, Unstable, Busy };
pub const Capture = struct {
    memory: ?r4os.driver_memory.Context = null,
    windows: [state.pages.len]a.GfxMmioWindow = @splat(.{}),
    cleanup_needed: bool = false,
    shared: bar0.Lease = .{},

    pub fn read(self: *Capture, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip) Error!state.Raw {
        return self.readUsing(ctx, snapshot, chip, null);
    }

    /// One real BAR0 borrow covers every observed page. No second MMIO alias
    /// or unowned copied kernel handle; failures retain this borrow until close.
    pub fn readShared(self: *Capture, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip, shared: *bar0.Owner) Error!state.Raw {
        return self.readUsing(ctx, snapshot, chip, shared);
    }
    fn readUsing(self: *Capture, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip, shared: ?*bar0.Owner) Error!state.Raw {
        const bar = snapshot.bars[0];
        if (identity.decision(snapshot) != .identity_words_only or chip.id != 0x176 or
            bar.bytes < 0x821000 or bar.base > std.math.maxInt(u64) - bar.bytes) return error.UnmeasuredRange;
        if (self.memory != null or self.cleanup_needed) return error.Busy;
        const clock = ctx.resources() orelse return error.Api;
        var previous = clock.nowNs();
        if (previous == 0 or previous == std.math.maxInt(u64)) return error.Clock;
        const deadline = std.math.add(u64, previous, std.time.ns_per_s) catch return error.Clock;
        self.memory = ctx.memory() orelse return error.Api;
        if (shared) |owner| try self.shared.acquire(owner, ctx, snapshot, chip);
        var first: state.Raw = .{};
        var second: state.Raw = .{};
        for ([_]*state.Raw{ &first, &second }, 0..) |raw, pass| {
            for (state.pages, 0..) |page, page_index| {
                // Read core capabilities and display fuse before their dependent
                // windows. Inaccessible capabilities never enable more reads.
                if (page == 0x111000 and !raw.riscvEnabled()) continue;
                if (page == 0x625000 and !raw.displayEnabled()) continue;
                try checkClock(clock, &previous, deadline);
                const window = &self.windows[page_index];
                if (self.shared.owner == null) {
                    if (pass == 0) {
                        const request: a.GfxMmioRequest = .{ .resource_base = bar.base, .resource_bytes = bar.bytes, .byte_offset = page, .byte_length = 4096, .cache_policy = a.gfx_buffer_cache_uncached };
                        self.cleanup_needed = true;
                        if (self.memory.?.mmioMap(&request, window) != a.gfx_buffer_result_ok) return error.Mapping;
                        if (window.handle.id == 0 or window.cpu_address == 0 or window.cpu_address & 3 != 0 or
                            window.cpu_address > std.math.maxInt(u64) - 4096 or window.byte_length != 4096 or
                            window.physical_address != bar.base + page or window.cache_policy != a.gfx_buffer_cache_uncached) return error.Mapping;
                    } else if (window.handle.id == 0) return error.Unstable;
                }
                for (state.addresses, 0..) |address, index| {
                    if (address & ~@as(u32, 0xfff) != page) continue;
                    try checkClock(clock, &previous, deadline);
                    const cpu = if (self.shared.owner != null) (try self.shared.view(page, 4096)).cpu_address else window.cpu_address;
                    const words: [*]const volatile u32 = @ptrFromInt(cpu);
                    const value = words[(address & 0xfff) / 4];
                    const reg: state.Register = @enumFromInt(index);
                    raw.put(reg, value);
                    if (pass == 1 and (!first.has(reg) or first.values[index] != value)) return error.Unstable;
                }
            }
        }
        try checkClock(clock, &previous, deadline);
        if (first.present != second.present) return error.Unstable;
        return first;
    }

    pub fn close(self: *Capture) bool {
        if (self.shared.owner != null) {
            if (!self.shared.release()) return false;
            self.* = .{};
            return true;
        }
        if (self.memory) |memory| {
            var remaining = self.windows.len;
            while (remaining != 0) {
                remaining -= 1;
                const window = &self.windows[remaining];
                if (window.handle.id == 0) continue;
                if (memory.mmioUnmap(&window.handle, 1) != a.gfx_buffer_result_ok) return false;
                window.* = .{};
            }
            if (self.cleanup_needed and memory.collect() != a.gfx_buffer_result_ok) return false;
        }
        self.* = .{};
        return true;
    }
};

fn checkClock(clock: r4os.r4dev.DriverResourceContext, previous: *u64, deadline: u64) Error!void {
    const now = clock.nowNs();
    if (now == std.math.maxInt(u64) or now < previous.*) return error.Clock;
    if (now >= deadline) return error.Deadline;
    previous.* = now;
}
