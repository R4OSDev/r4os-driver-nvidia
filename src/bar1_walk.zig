//! Bounded observation of an existing GA106 BAR1 mapping. No allocation,
//! page-table write, MMIO bind, TLB invalidate, recovery or ownership grant.
//! The reader must hold the device/display and serialize its PRAMIN access.
// BAR1/RAMIN and GMMU v2 layouts follow pinned NVIDIA 570.144 dev_bus.h,
// dev_ram.h, dev_mmu.h and kern_gmmu_fmt_{gp10x,ga10x}.c. The GA106 HAL
// selects kgmmuFmtIsVersionSupported_GP10X (v2 only); v1 is not admitted.
// Original R4OS observation, bounds and lifetime policy: Apache-2.0.
// NVIDIA portions retain their MIT terms:
// Copyright (c) 2003-2023 NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2003-2021 NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2003-2022 NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2014-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
const std = @import("std");
const identity = @import("identity.zig");
const state = @import("fwsec_state.zig");
pub const max_entries = 7;
pub const Control = struct { boot0: u32, boot1: u32, block: u32, bind_status: u32 };
pub const Reader = struct {
    context: *anyopaque,
    generation: *const fn (*anyopaque) u64,
    now_ns: *const fn (*anyopaque) u64,
    controls: *const fn (*anyopaque) anyerror!Control,
    // Exact framebuffer physical bytes, never a CPU pointer or BAR1 offset.
    // At most16 bytes per call. Must restore/retain its PRAMIN window on error.
    read_vram: *const fn (*anyopaque, u64, []u8) anyerror!void,
};
pub const Request = struct {
    epoch: u64,
    deadline: u64,
    boot0: u32,
    boot1: u32,
    bar: identity.Bar,
    framebuffer_bytes: u64,
    cpu_physical: u64,
    bytes: u64,
};
pub const Format = enum { physical, v2 };
pub const Level = enum { instance, pd3, pd2, pd1, pd0, big, small };
pub const Entry = struct { address: u64 = 0, bytes: u8 = 0, level: Level = .instance, value: [16]u8 = @splat(0) };
pub const Span = struct { address: u64, bytes: u64 };
pub const Report = struct {
    control: Control,
    format: Format = .physical,
    bar_offset: u64,
    mapped: Span = .{ .address = 0, .bytes = 0 },
    leaf_shift: u6 = 0,
    instance: ?Span = null,
    entries: [max_entries]Entry = @splat(.{}),
    entry_count: usize = 0,
};
const Walk = struct {
    request: Request,
    reader: Reader,
    report: Report,
    previous: u64 = 0,
    fn guard(self: *Walk) !void {
        if (self.reader.generation(self.reader.context) != self.request.epoch) return error.Stale;
        const now = self.reader.now_ns(self.reader.context);
        if (now == 0 or now == std.math.maxInt(u64) or now < self.previous) return error.Clock;
        if (now >= self.request.deadline) return error.Deadline;
        self.previous = now;
    }
    fn controls(self: *Walk) !Control {
        try self.guard();
        const value = try self.reader.controls(self.reader.context);
        try self.guard();
        if (value.boot0 != self.request.boot0 or value.boot1 != self.request.boot1) return error.Identity;
        if (!state.readable(value.block) or !state.readable(value.bind_status)) return error.Inaccessible;
        if (value.bind_status & 3 != 0) return error.BindPending;
        return value;
    }
    fn span(self: *const Walk, address: u64, bytes: u64) !void {
        if (bytes == 0 or address > self.request.framebuffer_bytes or bytes > self.request.framebuffer_bytes - address) return error.Bounds;
    }
    fn read(self: *Walk, address: u64, bytes: u8, level: Level) !*const Entry {
        if ((bytes != 8 and bytes != 16) or address & 7 != 0 or self.report.entry_count == max_entries) return error.State;
        try self.span(address, bytes);
        try self.guard();
        const record = &self.report.entries[self.report.entry_count];
        record.* = .{ .address = address, .bytes = bytes, .level = level };
        try self.reader.read_vram(self.reader.context, address, record.value[0..bytes]);
        try self.guard();
        self.report.entry_count += 1;
        return record;
    }
    fn finish(self: *Walk) !Report {
        // Repeat the complete dependency path, not only the final PTE. This
        // observes stability under the reader's hold, not GPU quiescence.
        for (self.report.entries[0..self.report.entry_count]) |*entry| {
            var bytes: [16]u8 = undefined;
            try self.guard();
            try self.reader.read_vram(self.reader.context, entry.address, bytes[0..entry.bytes]);
            try self.guard();
            if (!std.mem.eql(u8, entry.value[0..entry.bytes], bytes[0..entry.bytes])) return error.Unstable;
        }
        const control = try self.controls();
        if (!std.meta.eql(self.report.control, control)) return error.Unstable;
        return self.report;
    }
    fn leaf(self: *Walk, raw: u64, shift: u6) !Span {
        if (raw & 1 == 0) return error.Unmapped;
        // Linear local VRAM only. Reject peer/sysmem, encryption, read/
        // write protection, compression/kinds and reserved address bits.
        if (raw & ~@as(u64, 0x00000001ffffff89) != 0) return error.Pte;
        const address = ((raw >> 8) & 0x1ffffff) << 12;
        const leaf_bytes = @as(u64, 1) << shift;
        if (address & (leaf_bytes - 1) != 0) return error.Alignment;
        try self.span(address, leaf_bytes);
        const within = self.report.bar_offset & (leaf_bytes - 1);
        return .{ .address = address + within, .bytes = @min(self.request.bytes, leaf_bytes - within) };
    }
    fn table(raw: u64, big: bool) !?u64 {
        if (raw & 1 != 0) return error.Pde;
        const aperture = (raw >> 1) & 3;
        if (aperture == 0) {
            if (raw & 8 != 0) return error.Unmapped; // Sparse blocks fallback.
            return null;
        }
        if (aperture != 1) return error.Aperture;
        const mask: u64 = if (big) 0x1fffffff0 else 0x1ffffff00;
        if (raw & ~(mask | 0xe) != 0) return error.Pde;
        return (raw & mask) << 4;
    }
    fn choose(self: *Walk, big: ?u64, small: ?u64, big_shift: u6, coverage_shift: u6) !void {
        var found: ?Span = null;
        var selected: u6 = 0;
        const mask = (@as(u64, 1) << coverage_shift) - 1;
        for ([_]?u64{ big, small }, [_]u6{ big_shift, 12 }, [_]Level{ .big, .small }) |base, shift, level| {
            const address = base orelse continue;
            const index = (self.report.bar_offset & mask) >> shift;
            const entry = word(try self.read(try std.math.add(u64, address, index * 8), 8, level), 0);
            if (entry & 1 == 0) {
                if (entry & 8 != 0) return error.Unmapped;
                continue;
            }
            const mapped = try self.leaf(entry, shift);
            if (found != null) return error.Ambiguous;
            found = mapped;
            selected = shift;
        }
        self.report.mapped = found orelse return error.Unmapped;
        self.report.leaf_shift = selected;
    }
    fn virtual(self: *Walk, instance: u64) !void {
        try self.span(instance, 4096);
        self.report.instance = .{ .address = instance, .bytes = 4096 };
        const header = try self.read(instance + 0x200, 16, .instance);
        const root_raw = word(header, 0);
        if (root_raw & 3 != 0) return error.Aperture;
        if (root_raw & 0xfff & ~@as(u64, 0xc34) != 0) return error.Instance;
        const root = root_raw & ~@as(u64, 4095);
        const big_shift: u6 = if (root_raw & 0x800 != 0) 16 else 17;
        if (root_raw & 0x400 == 0) return error.Format;
        self.report.format = .v2;
        const limit = word(header, 8) | 4095;
        const address_limit = @as(u64, 1) << 49;
        if (limit >= address_limit or self.report.bar_offset > limit or self.request.bytes - 1 > limit - self.report.bar_offset) return error.Bounds;
        try self.span(root, 4096);
        var current = root;
        for ([_]u6{ 47, 38, 29 }, [_]u64{ 3, 511, 511 }, [_]Level{ .pd3, .pd2, .pd1 }) |shift, mask, level| {
            const raw = word(try self.read(current + ((self.report.bar_offset >> shift) & mask) * 8, 8, level), 0);
            if (raw & 1 != 0) {
                if (level != .pd1) return error.Pde;
                self.report.mapped = try self.leaf(raw, 29); // GA10x 512-MB leaf.
                self.report.leaf_shift = 29;
                return;
            }
            current = try table(raw, false) orelse return error.Unmapped;
        }
        const dual = try self.read(current + ((self.report.bar_offset >> 21) & 255) * 16, 16, .pd0);
        const big = word(dual, 0);
        const small = word(dual, 8);
        if (big & 1 != 0) {
            if (small != 0) return error.Ambiguous;
            self.report.mapped = try self.leaf(big, 21);
            self.report.leaf_shift = 21;
            return;
        }
        try self.choose(try table(big, true), try table(small, false), big_shift, 21);
    }
};
fn word(entry: *const Entry, offset: usize) u64 {
    return std.mem.readInt(u64, entry.value[offset..][0..8], .little);
}

/// Resolve one contiguous part of a requested CPU physical BAR1 span. Virtual
/// results stop at the current leaf; callers advance by mapped.bytes. At most
/// seven8/16-byte entries, repeated once, plus two control observations. The
/// complete path is returned for future preservation, not as a recovery token.
pub fn resolve(request: Request, reader: Reader) !Report {
    const chip = identity.chip(request.boot0, request.boot1) orelse return error.Profile;
    if (chip.id != 0x176 or request.epoch == 0 or request.deadline == 0 or request.deadline == std.math.maxInt(u64)) return error.Profile;
    const bar = request.bar;
    if ((bar.kind != .memory32 and bar.kind != .memory64) or !bar.prefetchable or bar.base == 0 or bar.bytes == 0 or (bar.base | bar.bytes) & 4095 != 0 or
        bar.base > std.math.maxInt(u64) - bar.bytes or request.cpu_physical < bar.base or request.bytes == 0 or
        request.framebuffer_bytes == 0 or request.framebuffer_bytes > (@as(u64, 1) << 40)) return error.Bounds;
    const offset = request.cpu_physical - bar.base;
    if (offset >= bar.bytes or request.bytes > bar.bytes - offset) return error.Bounds;
    var walk: Walk = .{ .request = request, .reader = reader, .report = .{ .control = undefined, .bar_offset = offset } };
    const control = try walk.controls();
    walk.report.control = control;
    if (control.block & 0x70000000 != 0) return error.Aperture;
    if (control.block & 0x80000000 == 0) {
        try walk.span(offset, request.bytes);
        walk.report.mapped = .{ .address = offset, .bytes = request.bytes };
    } else try walk.virtual(@as(u64, control.block & 0xfffffff) << 12);
    return walk.finish();
}
