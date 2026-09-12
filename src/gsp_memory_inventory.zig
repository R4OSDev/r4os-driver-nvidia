// NVIDIA memory-region semantics retain their original MIT notices.
// Resident ownership, interval screening and integration: R4OS Apache-2.0.
// src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080fb.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2006-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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

// src/nvidia/src/kernel/gpu/mem_mgr/mem_mgr_gsp_client.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2019-2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Resident memory observations under the actual retained boot reservation.
//! No allocation, GPU mapping or CPU aperture access follows from this view.
//! In particular, RM's speculative reserved byte count has no fixed address.
const std = @import("std");
const static = @import("gsp_static.zig");
const vram = @import("boot_vram_lease.zig");
const mapping = @import("boot_mapping.zig");
const payload = @import("display_memory.zig");
const identity = @import("identity.zig");
pub const Span = struct { base: u64, bytes: u64 };
// Whole firmware envelope, old VGA, surface extents, full dependency pages,
// display instance and unique image/cursor/LUT payloads. No truncation.
pub const max_spans = 3 + mapping.max_ranges + mapping.max_pages + payload.max_spans;
pub const Window = struct {
    pci_index: u8,
    base: u64,
    bytes: u64,
    prefetchable: bool,
    status: enum { absent, unmeasured, disabled, measured },
};
pub const Summary = struct {
    epoch: u64 = 0,
    boot_epoch: u64 = 0,
    physical_bytes: u64 = 0,
    reported_bytes: u64 = 0,
    region_bytes: u64 = 0,
    region_holes: u64 = 0,
    speculative_reserved: u64 = 0,
    retained_bytes: u64 = 0,
    screened_bytes: u64 = 0,
    region_count: usize = 0,
    retained_count: usize = 0,
    surface_extents: usize = 0,
    table_pages: usize = 0,
    payload_extents: usize = 0,
    instance_active: bool = false,
    rebar_present: bool = false,
    firmware_layout_matches: bool = false,
    non_wpr_heap: u64 = 0,
    frts: u64 = 0,
    bar1_pdb: u64 = 0,
    bar2_pdb: u64 = 0,
    windows: [3]Window = undefined,
};
pub const Placement = enum {
    invalid,
    region_gap,
    protected,
    rm_reserved,
    boot_retained,
    firmware_layout_changed,
    // Necessary interval screening only. A future RM allocation and mapping
    // owner must establish actual ownership and device visibility separately.
    requires_rm_allocation,
};
pub const Owner = struct {
    self_address: usize = 0,
    lease: ?*const vram.Lease = null,
    binding: ?vram.Binding = null,
    state: enum { detached, prepared, published, invalidated } = .detached,
    data: Summary = .{},
    regions: [static.max_regions]static.Region = undefined,
    retained: [max_spans]Span = undefined,

    /// Build in resident storage before the static response ACK; neither a
    /// partial interval union nor unacknowledged metadata is published.
    pub fn prepare(self: *Owner, lease: *const vram.Lease, info: *const static.Info, epoch: u64) !void {
        if (self.self_address != 0 or epoch == 0) return error.MemoryState;
        const binding = try lease.binding(.metadata);
        const plan = &lease.plan.?;
        const display = lease.display.?;
        const pci = if (display.snapshot) |*value| value else return error.MemoryBinding;
        const map = lease.boot_mapping.?;
        const context = lease.boot_context.?;
        const vga = if (display.operation) |*value| &value.options.range else return error.MemoryBinding;
        if (info.region_count == 0 or info.region_count > static.max_regions or
            map.range_count == 0 or map.range_count > mapping.max_ranges or map.page_count > mapping.max_pages or
            map.framebuffer_bytes != plan.fb_bytes or context.framebuffer_bytes != plan.fb_bytes or
            context.payload_plan.count > payload.max_spans) return error.MemoryBinding;
        self.self_address = @intFromPtr(self);
        self.lease = lease;
        self.binding = binding;
        errdefer self.state = .invalidated;
        self.data = .{ .epoch = epoch, .boot_epoch = binding.epoch, .physical_bytes = plan.fb_bytes, .reported_bytes = info.fb_bytes, .region_count = info.region_count, .surface_extents = map.range_count, .table_pages = map.page_count, .payload_extents = context.payload_plan.count, .instance_active = context.instance_active, .rebar_present = pci.caps.rebar != 0, .firmware_layout_matches = info.non_wpr_heap == plan.non_wpr_heap.offset and info.frts == plan.frts.offset, .non_wpr_heap = info.non_wpr_heap, .frts = info.frts, .bar1_pdb = info.bar1_pdb, .bar2_pdb = info.bar2_pdb };
        if (info.fb_bytes == 0 or info.fb_bytes > plan.fb_bytes) return error.MemoryBounds;
        for ([_]u8{ 0, 1, 3 }, 0..) |index, slot|
            self.data.windows[slot] = try window(pci, index);
        for (info.regions[0..info.region_count], 0..) |*region, index| {
            try self.bounds(.{ .base = region.base, .bytes = region.bytes });
            if (region.reserved > region.bytes) return error.MemoryBounds;
            for (info.regions[0..index]) |*prior|
                if (overlap(.{ .base = region.base, .bytes = region.bytes }, .{ .base = prior.base, .bytes = prior.bytes }) != 0)
                    return error.MemoryRegion;
            self.regions[index] = region.*;
            self.data.region_bytes += region.bytes;
            self.data.speculative_reserved += region.reserved;
        }
        self.data.region_holes = plan.fb_bytes - self.data.region_bytes;
        try self.add(.{ .base = plan.reserved.offset, .bytes = plan.reserved.bytes });
        try self.add(.{ .base = vga.address, .bytes = vga.bytes });
        var surface_bytes: u64 = 0;
        for (map.ranges[0..map.range_count]) |*span| {
            try self.add(.{ .base = span.address, .bytes = span.bytes });
            surface_bytes = try std.math.add(u64, surface_bytes, span.bytes);
        }
        if (display.original_boot == null or surface_bytes != display.original_boot.?.byte_length or
            surface_bytes != map.surface_bytes) return error.MemoryBinding;
        for (map.pages[0..map.page_count]) |base| {
            if (base & 4095 != 0) return error.MemoryBounds;
            try self.add(.{ .base = base, .bytes = 4096 });
        }
        if (context.instance_active) try self.add(.{ .base = context.span.address, .bytes = context.span.bytes });
        for (context.payload_plan.spans[0..context.payload_plan.count]) |*span|
            try self.add(.{ .base = span.address, .bytes = span.bytes });
        // Firmware regions may have gaps or appear out of address order.
        // Fully protect every speculative/protected region: never invent a
        // reserved tail from an amount. Unknown layout changes screen no bytes.
        if (self.data.firmware_layout_matches) for (self.regions[0..self.data.region_count]) |*region| {
            if (region.protected or region.reserved != 0) continue;
            var bytes = region.bytes;
            for (self.retained[0..self.data.retained_count]) |span|
                bytes -= overlap(.{ .base = region.base, .bytes = region.bytes }, span);
            self.data.screened_bytes += bytes;
        };
        self.state = .prepared;
    }
    pub fn publish(self: *Owner) !void {
        if (self.state != .prepared or !self.bound()) return error.MemoryStale;
        self.state = .published;
    }
    pub fn invalidate(self: *Owner) void {
        if (self.self_address == @intFromPtr(self)) self.state = .invalidated;
    }
    fn bound(self: *const Owner) bool {
        return self.self_address != 0 and self.self_address == @intFromPtr(self) and
            self.lease != null and self.binding != null and self.lease.?.validates(self.binding.?);
    }
    /// Borrowed by the serialized driver worker, only until its next step.
    pub fn snapshot(self: *const Owner) ?*const Summary {
        return if (self.state == .published and self.bound()) &self.data else null;
    }
    pub fn placement(self: *const Owner, span: Span) !Placement {
        if (self.snapshot() == null) return error.MemoryStale;
        self.bounds(span) catch return .invalid;
        if (!self.data.firmware_layout_matches) return .firmware_layout_changed;
        for (self.retained[0..self.data.retained_count]) |retained|
            if (overlap(span, retained) != 0) return .boot_retained;
        for (self.regions[0..self.data.region_count]) |*region| {
            if (span.base < region.base or span.base + span.bytes > region.base + region.bytes) continue;
            if (region.protected) return .protected;
            if (region.reserved != 0) return .rm_reserved;
            return .requires_rm_allocation;
        }
        return .region_gap;
    }
    fn bounds(self: *const Owner, span: Span) !void {
        if (span.bytes == 0 or span.base >= self.data.physical_bytes or span.bytes > self.data.physical_bytes - span.base)
            return error.MemoryBounds;
    }
    /// Sorted, disjoint byte union; aliases and adjacent reservations count
    /// once. Build directly in the resident owner, never on the driver stack.
    fn add(self: *Owner, span: Span) !void {
        try self.bounds(span);
        var begin = span.base;
        var end = begin + span.bytes;
        var first: usize = 0;
        while (first < self.data.retained_count and self.retained[first].base + self.retained[first].bytes < begin) : (first += 1) {}
        var last = first;
        var replaced: u64 = 0;
        while (last < self.data.retained_count and self.retained[last].base <= end) : (last += 1) {
            begin = @min(begin, self.retained[last].base);
            end = @max(end, self.retained[last].base + self.retained[last].bytes);
            replaced += self.retained[last].bytes;
        }
        const count = self.data.retained_count - (last - first) + 1;
        if (count > max_spans) return error.MemoryCapacity;
        if (last == first)
            std.mem.copyBackwards(Span, self.retained[first + 1 .. count], self.retained[first..self.data.retained_count])
        else
            std.mem.copyForwards(Span, self.retained[first + 1 .. count], self.retained[last..self.data.retained_count]);
        self.retained[first] = .{ .base = begin, .bytes = end - begin };
        self.data.retained_count = count;
        self.data.retained_bytes = self.data.retained_bytes - replaced + end - begin;
    }
};
fn overlap(a: Span, b: Span) u64 {
    return @min(a.base + a.bytes, b.base + b.bytes) -| @max(a.base, b.base);
}
fn window(pci: *const identity.Snapshot, index: u8) !Window {
    const bar = pci.bars[index];
    if (bar.bytes != 0 and (bar.kind != .memory32 and bar.kind != .memory64 or
        bar.base == 0 or bar.base > std.math.maxInt(u64) - bar.bytes)) return error.MemoryAperture;
    return .{ .pci_index = index, .base = bar.base, .bytes = bar.bytes, .prefetchable = bar.prefetchable, .status = if (bar.kind == .absent) .absent else if (bar.bytes == 0) .unmeasured else if (pci.command & 2 == 0) .disabled else .measured };
}
