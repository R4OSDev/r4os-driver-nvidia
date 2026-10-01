//! Driver-owned application VRAM, serialized by the existing GSP worker.
//! The static region table assigns nonreserved FB to the host (570.144
//! memmgrInitBaseFbRegions_FWCLIENT); GSP's NV01_MEMORY_LOCAL_USER allocator
//! owns its separate reserved heap. Boot/firmware exclusions remain leased.
//! Resident intrusive ranges need no second allocation or fixed slot limit.
const std = @import("std");
const inventory = @import("gsp_memory_inventory.zig");
pub const Error = error{ Stale, Bounds, Memory, Retained, Exhausted };
pub const Range = struct {
    self_address: usize = 0,
    owner: ?*Owner = null,
    previous: ?*Range = null,
    next: ?*Range = null,
    span: inventory.Span = .{ .base = 0, .bytes = 0 },
    stamp: inventory.Span = .{ .base = 0, .bytes = 0 },
};
pub const Owner = struct {
    self_address: usize = 0,
    view: ?*const inventory.Owner = null,
    epoch: u64 = 0,
    first: ?*Range = null,
    bytes: u64 = 0,
    count: usize = 0,

    pub fn reserve(self: *Owner, view: *const inventory.Owner, epoch: u64, range: *Range, bytes: u64, alignment: u64) Error!u64 {
        if (self.self_address != 0 and (self.self_address != @intFromPtr(self) or self.view != view or self.epoch != epoch)) return error.Stale;
        if (!std.meta.eql(range.*, Range{})) return error.Stale;
        const data = view.snapshot() orelse return error.Stale;
        if (epoch == 0 or data.epoch != epoch) return error.Stale;
        if (bytes == 0 or bytes & 65535 != 0 or alignment < 65536 or !std.math.isPowerOfTwo(alignment)) return error.Bounds;
        if (!data.firmware_layout_usable) return error.Memory;
        const base = try self.choose(view, bytes, alignment);
        const address_limit = @import("gsp_host_page.zig").video_limit;
        if (base >= address_limit or bytes > address_limit - base) return error.Bounds;
        const total = std.math.add(u64, self.bytes, bytes) catch return error.Exhausted;
        const count = std.math.add(usize, self.count, 1) catch return error.Exhausted;
        var previous: ?*Range = null;
        var next = self.first;
        while (next) |entry| {
            try self.validate(entry);
            if (entry.span.base > base) break;
            previous = entry;
            next = entry.next;
        }
        const span: inventory.Span = .{ .base = base, .bytes = bytes };
        self.self_address = @intFromPtr(self); self.view = view; self.epoch = epoch;
        range.* = .{ .self_address = @intFromPtr(range), .owner = self, .previous = previous, .next = next, .span = span, .stamp = span };
        if (previous) |entry| entry.next = range else self.first = range;
        if (next) |entry| entry.previous = range;
        self.bytes = total; self.count = count;
        return base;
    }
    fn choose(self: *const Owner, view: *const inventory.Owner, bytes: u64, alignment: u64) Error!u64 {
        for (view.regions[0..view.data.region_count]) |region| {
            // Conservatively exclude the WHOLE partially reserved region.
            // ISO/compression support is also required for reusable images.
            if (region.reserved != 0 or region.protected or !region.iso or !region.compressed) continue;
            const limit = region.base + region.bytes;
            var base = alignUp(region.base, alignment) catch continue;
            var retained: usize = 0;
            var allocated = self.first;
            // Merge both sorted exclusion lists in one bounded traversal.
            while (base < limit and bytes <= limit - base) {
                const held = if (retained < view.data.retained_count) view.retained[retained] else null;
                const node = allocated;
                if (node) |entry| try self.validate(entry);
                const use_held = held != null and (node == null or held.?.base <= node.?.span.base);
                const occupied = if (use_held) held.? else if (node) |entry| entry.span else break;
                if (use_held) retained += 1 else allocated = node.?.next;
                if (occupied.base >= base + bytes) break;
                const end = occupied.base + occupied.bytes;
                if (end > base) base = alignUp(end, alignment) catch { base = limit; break; };
            }
            if (base < limit and bytes <= limit - base) {
                if ((view.placement(.{ .base = base, .bytes = bytes }) catch return error.Stale) != .requires_host_allocation) return error.Stale;
                return base;
            }
        }
        return error.Memory;
    }
    fn validate(self: *const Owner, range: *const Range) Error!void {
        if (self.self_address != @intFromPtr(self) or self.epoch == 0 or self.view == null or
            range.self_address != @intFromPtr(range) or range.owner != self or !std.meta.eql(range.span, range.stamp) or
            range.span.bytes == 0 or self.bytes < range.span.bytes or self.count == 0) return error.Stale;
        if (range.previous) |prior| {
            if (prior.owner != self or prior.next != range or prior.span.base + prior.span.bytes > range.span.base) return error.Stale;
        } else if (self.first != range) return error.Stale;
        if (range.next) |next| if (next.owner != self or next.previous != range or range.span.base + range.span.bytes > next.span.base) return error.Stale;
    }
    /// Only the backing owner calls this after exact last-use release and
    /// acknowledged PTE removal, or after independent whole-device quiescence.
    /// An invalidated inventory blocks new placement, never confirmed release.
    pub fn release(self: *Owner, range: *Range, quiesced: bool) Error!void {
        try self.validate(range);
        if (!quiesced) return error.Retained;
        if (range.previous) |prior| prior.next = range.next else self.first = range.next;
        if (range.next) |next| next.previous = range.previous;
        self.bytes -= range.span.bytes; self.count -= 1;
        range.* = .{};
    }
    pub fn empty(self: *const Owner) bool {
        return (self.self_address == 0 or self.self_address == @intFromPtr(self)) and self.first == null and self.bytes == 0 and self.count == 0;
    }
    pub fn owns(self: *const Owner, range: *const Range) bool {
        self.validate(range) catch return false;
        return true;
    }
};
fn alignUp(value: u64, alignment: u64) Error!u64 {
    return (std.math.add(u64, value, alignment - 1) catch return error.Bounds) & ~(alignment - 1);
}
