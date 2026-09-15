// /*
//  * SPDX-FileCopyrightText: Copyright (c) 1993-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//  * SPDX-License-Identifier: MIT
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be included in
//  * all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
//! Exact rational PBN admission and one shared63-slot 8b/10b link budget.
//! NVIDIA570.144 dp_watermark.cpp and dp_linkconfig.cpp supply the public
//! PBN/downspread/blanking rules. The transaction owner supplies actual path
//! resources; this pure planner produces neither an ACT nor a live stream.
const std = @import("std");
const links = @import("r4gfx_edid").links;
pub const Error = error{ Descriptor, Unsupported, Bandwidth, Duplicate };
pub const Link = struct {
    rate: u8,
    lanes: u8,
    pub fn pbnPerSlot(self: Link) Error!u16 {
        const bits = links.dp8b10bPayload(self.rate, self.lanes) catch return error.Unsupported;
        return @intCast((bits / 8 / 64) / 843750);
    }
};
pub const Timing = struct { clock: links.Clock, width: u32, total: u32, bpc: u8 };
pub const Demand = struct { pbn: u16, slots: u8, timeslice_pbn: u16, hblank: u32, vblank: u32, audio_48k: bool };
fn ceil(n: u128, d: u128) u128 {
    return (n + d - 1) / d;
}
pub fn demand(link: Link, timing: Timing) Error!Demand {
    const per_slot = try link.pbnPerSlot();
    if (!timing.clock.atMost(4_000_000_000) or timing.width <= 60 or timing.total <= timing.width or timing.total > 65535 or
        (timing.bpc != 8 and timing.bpc != 10)) return error.Descriptor;
    const bpp: u64 = @as(u64, timing.bpc) * 3;
    // Downspread0.6% is included once in PBN demand, not subtracted again
    // from nominal slot capacity. Slot0 is reserved for the MST header.
    const pbn = ceil(@as(u128, timing.clock.numerator) * bpp * 1006 * 64, @as(u128, timing.clock.denominator) * 8 * 54_000_000 * 1000);
    const slots = ceil(pbn, per_slot);
    if (pbn == 0 or pbn > 65535 or slots == 0 or slots > 63) return error.Bandwidth;
    const pclk: u64 = timing.clock.ceilHz() catch return error.Descriptor;
    const link_hz = @as(u64, link.rate) * 27_000_000 * 994 / 1000;
    var blank_bits: u64 = (if (timing.width % 4 == 0) @as(u64, 0) else (4 - @as(u64, timing.width % 4)) * bpp) + 184;
    blank_bits += 32 - blank_bits % 32;
    const min_blank = (blank_bits + bpp - 1) / bpp;
    if (min_blank > timing.total - timing.width) return error.Bandwidth;
    const hdelay: u64 = 4 + @as(u64, if (link.lanes == 1) 9 else if (link.lanes == 2) 6 else 3);
    const hblank = ((timing.total - timing.width - min_blank) * link_hz / pclk) -| hdelay;
    const vdelay: u64 = 1 + @as(u64, if (link.lanes == 1) 39 else if (link.lanes == 2) 21 else 12);
    const vblank = ((@as(u64, timing.width) - 40) * link_hz / pclk) -| vdelay;
    const samples: u64 = @intCast(ceil(48_000 * @as(u128, timing.total), pclk));
    const audio_symbols = 10 * (samples + 2 - samples % 2) + 16;
    // A video-only mode remains useful when this exact timing cannot also
    // transport 48kHz stereo. Audio publication uses this same capability.
    return .{ .pbn = @intCast(pbn), .slots = @intCast(slots), .timeslice_pbn = @intCast(slots * per_slot), .hblank = std.math.cast(u32, hblank) orelse return error.Bandwidth, .vblank = std.math.cast(u32, vblank) orelse return error.Bandwidth, .audio_48k = hblank >= audio_symbols };
}
pub const Path = struct { total_pbn: u16, free_pbn: u16, owned_pbn: u16 = 0 };
pub const Wanted = struct {
    display_id: u32,
    payload_id: u8,
    head: u8,
    timing: Timing,
    path_count: u8,
    path: [15]u8 = @splat(0),
};
pub const Allocation = struct { display_id: u32 = 0, payload_id: u8 = 0, head: u8 = 0, start: u8 = 0, demand: Demand = .{ .pbn = 0, .slots = 0, .timeslice_pbn = 0, .hblank = 0, .vblank = 0, .audio_48k = false } };
pub const Table = struct {
    count: u8 = 0,
    slots: u8 = 0,
    used_pbn: u16 = 0,
    allocations: [8]Allocation = @splat(.{}),
};
/// Recompute the complete root budget before touching an old stream. Every
/// traversed branch output contributes a shared quota; two sibling streams
/// can exhaust their upstream path even when the root still has free slots.
pub fn plan(link: Link, paths: []const Path, wanted: []const Wanted) Error!Table {
    _ = try link.pbnPerSlot();
    if (wanted.len > 8 or paths.len > 120) return error.Unsupported;
    var used: [120]u32 = @splat(0);
    for (paths) |path| if (path.free_pbn > path.total_pbn or path.owned_pbn > path.total_pbn or
        @as(u32, path.free_pbn) + path.owned_pbn > path.total_pbn) return error.Descriptor;
    var result: Table = .{};
    var displays: u32 = 0;
    var payloads: u64 = 0;
    var heads: u8 = 0;
    for (wanted) |item| {
        if (item.display_id == 0 or item.display_id & (item.display_id - 1) != 0 or item.payload_id == 0 or item.payload_id > 63 or
            item.head >= 8 or item.path_count == 0 or item.path_count > item.path.len) return error.Descriptor;
        const payload_bit = @as(u64, 1) << @as(u6, @intCast(item.payload_id));
        const head_bit = @as(u8, 1) << @as(u3, @intCast(item.head));
        if (displays & item.display_id != 0 or payloads & payload_bit != 0 or heads & head_bit != 0) return error.Duplicate;
        const required = try demand(link, item.timing);
        if (@as(u16, result.slots) + required.slots > 63) return error.Bandwidth;
        var seen: [120]bool = @splat(false);
        for (item.path[0..item.path_count]) |index| {
            if (index >= paths.len or seen[index]) return error.Descriptor;
            seen[index] = true;
            used[index] += required.pbn;
            if (used[index] > @as(u32, paths[index].free_pbn) + paths[index].owned_pbn) return error.Bandwidth;
        }
        result.allocations[result.count] = .{ .display_id = item.display_id, .payload_id = item.payload_id, .head = item.head, .start = result.slots + 1, .demand = required };
        result.slots += required.slots;
        result.used_pbn += required.pbn;
        result.count += 1;
        displays |= item.display_id;
        payloads |= payload_bit;
        heads |= head_bit;
    }
    return result;
}
