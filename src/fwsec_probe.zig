// GA106-only, read-only security fuse measurement. Addresses and HAL dispatch
// come from NVIDIA 570.144; the measured BAR extent must cover both pages.
const std = @import("std");
const r4os = @import("r4os");
const identity = @import("identity.zig");
const fwsec = @import("fwsec.zig");
const preparation = @import("fwsec_prepare.zig");
const a = r4os.abi;
pub const debug_register: u32 = 0x82074c;
pub const version_register: u32 = 0x8241c0;
pub const Error = preparation.Error || error{ UnmeasuredRange, Api, Mapping, Clock, Deadline, Unstable, Busy };

pub const Capture = struct {
    memory: ?r4os.driver_memory.Context = null,
    windows: [2]a.GfxMmioWindow = .{ .{}, .{} },
    cleanup_needed: bool = false,

    pub fn read(self: *Capture, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip, catalog: *const fwsec.Catalog) Error!preparation.Fuses {
        const bar = snapshot.bars[0];
        if (identity.decision(snapshot) != .identity_words_only or chip.id != 0x176 or
            bar.bytes < 0x825000 or bar.base > std.math.maxInt(u64) - bar.bytes) return error.UnmeasuredRange;
        if (catalog.count > catalog.entries.len) return error.Limit;
        var supported = false;
        for (catalog.entries[0..catalog.count]) |*entry| supported = supported or preparation.supported(entry);
        if (!supported) return error.Unsupported;
        if (self.memory != null or self.cleanup_needed) return error.Busy;
        const clock = ctx.resources() orelse return error.Api;
        const start = clock.nowNs();
        if (start == 0 or start == std.math.maxInt(u64)) return error.Clock;
        const deadline = std.math.add(u64, start, std.time.ns_per_s) catch return error.Clock;
        var previous = start;
        self.memory = ctx.memory() orelse return error.Api;
        try self.map(0, bar.base, bar.bytes, debug_register & ~@as(u32, 0xfff));
        try checkClock(clock, &previous, deadline);
        const debug = self.word(0, debug_register);
        const entry = try preparation.variant(catalog, try preparation.debugEnabled(debug));
        const address = version_register + 4 * (@as(u32, entry.ucode_id) - 1);
        try self.map(1, bar.base, bar.bytes, address & ~@as(u32, 0xfff));
        try checkClock(clock, &previous, deadline);
        const version = self.word(1, address);
        if (self.word(0, debug_register) != debug or self.word(1, address) != version) return error.Unstable;
        try checkClock(clock, &previous, deadline);
        _ = try preparation.fuseVersion(version);
        return .{ .debug_disable_raw = debug, .ucode_version_raw = version, .ucode_id = entry.ucode_id };
    }

    fn map(self: *Capture, index: usize, base: u64, bytes: u64, offset: u32) Error!void {
        const request: a.GfxMmioRequest = .{ .resource_base = base, .resource_bytes = bytes, .byte_offset = offset, .byte_length = 4096, .cache_policy = a.gfx_buffer_cache_uncached };
        self.cleanup_needed = true; // Failed maps can retain unpublished pages.
        const window = &self.windows[index];
        if (self.memory.?.mmioMap(&request, window) != a.gfx_buffer_result_ok) return error.Mapping;
        if (window.handle.id == 0 or window.cpu_address == 0 or window.cpu_address & 3 != 0 or
            window.cpu_address > std.math.maxInt(u64) - 4096 or window.byte_length != 4096 or
            window.physical_address != base + offset or window.cache_policy != a.gfx_buffer_cache_uncached) return error.Mapping;
    }
    fn word(self: *const Capture, index: usize, address: u32) u32 {
        const words: [*]const volatile u32 = @ptrFromInt(self.windows[index].cpu_address);
        return words[(address & 0xfff) / 4];
    }

    pub fn close(self: *Capture) bool {
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
