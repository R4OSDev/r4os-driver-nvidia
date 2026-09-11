//! Original R4OS interval plan for immutable local display-memory backups.
//! Physical aliases/overlaps share bytes; rejected additions leave it intact.
const std = @import("std");
const context = @import("display_context.zig");
const scanout = @import("boot_scanout.zig");
const assets = @import("display_assets.zig");
pub const max_spans = scanout.max_windows * 6 + assets.max_assets;
pub const max_bytes = 256 * 1024 * 1024;
pub const Span = context.Span;
pub const Plan = struct {
    spans: [max_spans]Span = undefined,
    count: usize = 0,
    bytes: usize = 0,

    pub fn add(self: *Plan, value: Span, framebuffer_bytes: u64) !void {
        if (value.bytes == 0 or (value.address | value.bytes) & 3 != 0) return error.PayloadBounds;
        var end = std.math.add(u64, value.address, value.bytes) catch return error.PayloadBounds;
        if (end > framebuffer_bytes or end > @as(u64, 1) << 40) return error.PayloadBounds;
        var begin = value.address;
        var first: usize = 0;
        while (first < self.count and self.spans[first].address + self.spans[first].bytes < begin) : (first += 1) {}
        var last = first;
        var replaced_bytes: usize = 0;
        while (last < self.count and self.spans[last].address <= end) : (last += 1) {
            begin = @min(begin, self.spans[last].address);
            end = @max(end, self.spans[last].address + self.spans[last].bytes);
            replaced_bytes += @intCast(self.spans[last].bytes);
        }
        const count = self.count - (last - first) + 1;
        if (count > max_spans) return error.PayloadCapacity;
        const bytes = self.bytes - replaced_bytes + end - begin;
        if (bytes > max_bytes) return error.PayloadBudget;
        // All fallible validation precedes the in-place interval replacement.
        if (last == first) {
            std.mem.copyBackwards(Span, self.spans[first + 1 .. count], self.spans[first..self.count]);
        } else {
            std.mem.copyForwards(Span, self.spans[first + 1 .. count], self.spans[last..self.count]);
        }
        self.spans[first] = .{ .address = begin, .bytes = end - begin };
        self.count = count;
        self.bytes = @intCast(bytes);
    }

    /// Find the exact byte offset in the concatenation of unique intervals.
    pub fn offset(self: *const Plan, value: Span) !usize {
        if (value.bytes == 0) return error.PayloadBounds;
        const end = std.math.add(u64, value.address, value.bytes) catch return error.PayloadBounds;
        var prior: usize = 0;
        for (self.spans[0..self.count]) |*span| {
            if (value.address >= span.address and end <= span.address + span.bytes)
                return prior + @as(usize, @intCast(value.address - span.address));
            prior += @intCast(span.bytes);
        }
        return error.PayloadMissing;
    }
};
