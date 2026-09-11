//! Bounded GA106 VGA-workspace capture through its GM107 BAR0 window.
//! Only the window register may be written. Firmware/DMA/scanout programming
//! and VGA relocation are outside this operation. The caller serializes the
//! actual device owner, retains the destination and holds the boot display.
// Register/window semantics follow the pinned NVIDIA 570.144 GM107 bus HAL.
// R4OS admission, state machine and failure handling: Apache-2.0.
// Copyright (c) 2004-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2003-2023 NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2017-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//
const std = @import("std");
const identity = @import("identity.zig");
const preflight = @import("fwsec_state.zig");
pub const window_register: u32 = 0x1700;
pub const vga_register: u32 = 0x625f04;
pub const aperture: u32 = 0x700000;
pub const aperture_bytes: u32 = 0x100000;
pub const window_mask: u32 = 0x03ffffff;
pub const Range = struct { address: u64, bytes: u32 };

/// The current workspace, not the target encoded in the GSP WPR metadata.
/// A low VBIOS workspace uses NVIDIA's 128 KB workspace size. An already
/// relocated workspace extends to the reported end of framebuffer memory.
pub fn workspace(chip_id: u16, raw: *const preflight.Raw) !Range {
    if (chip_id != 0x176) return error.Profile;
    const state = try preflight.decode(raw);
    if (!state.display_enabled or !state.vga_valid) return error.Unavailable;
    if (state.wpr_up or state.reset_asserted or state.scrubbing or !state.falcon_halted or
        !state.dma_idle or state.dma_full or !state.riscv_enabled or state.riscv_selected or
        state.riscv_active or !state.riscv_halted or !state.bcr_valid) return error.EngineState;
    const bytes: u64 = if (state.vga_relocation_needed) 0x20000 else state.fb_bytes - state.vga_base;
    if (bytes == 0 or bytes > aperture_bytes or bytes > state.fb_bytes - state.vga_base) return error.Bounds;
    return .{ .address = state.vga_base, .bytes = @intCast(bytes) };
}

pub const Port = struct {
    context: *anyopaque,
    generation: *const fn (*anyopaque) u64,
    now_ns: *const fn (*anyopaque) u64,
    // Must retain the real display/device owner before a possible write.
    retain: *const fn (*anyopaque) anyerror!void,
    read32: *const fn (*anyopaque, u32) anyerror!u32,
    // Includes ordering and a same-device posted-write flush.
    write32: *const fn (*anyopaque, u32, u32) anyerror!void,
};
pub const Options = struct { epoch: u64, deadline: u64, boot0: u32, boot1: u32, vga: u32, range: Range };
pub const Phase = enum { observe, retain, select, copy, restore, done };
pub const Capture = struct {
    options: Options,
    phase: Phase = .observe,
    original: ?u32 = null,
    selected: u32 = 0,
    copied: u32 = 0,
    effects_possible: bool = false,
    restored: bool = false,
    failure: ?anyerror = null,
    self_address: usize = 0,
    output_address: usize = 0,
    previous_clock: u64 = 0,

    pub fn init(options: Options) !Capture {
        if ((identity.chip(options.boot0, options.boot1) orelse return error.Profile).id != 0x176) return error.Profile;
        const range = options.range;
        if (options.epoch == 0 or options.deadline == 0 or options.deadline == std.math.maxInt(u64) or
            !preflight.readable(options.vga) or options.vga & 8 == 0 or
            range.address != @as(u64, options.vga >> 8) << 16 or range.address >= @as(u64, 1) << 40 or
            range.bytes == 0 or range.bytes > aperture_bytes or range.bytes & 3 != 0 or
            range.address > (@as(u64, 1) << 40) - range.bytes) return error.Options;
        return .{ .options = options };
    }

    fn guard(self: *Capture, port: Port, deadline: u64) !void {
        if (self.self_address != @intFromPtr(self) or port.generation(port.context) != self.options.epoch) return error.Stale;
        const now = port.now_ns(port.context);
        if (now == 0 or now == std.math.maxInt(u64) or now < self.previous_clock) return error.Clock;
        self.previous_clock = now;
        if (deadline == std.math.maxInt(u64) or now >= deadline) return error.Deadline;
    }
    fn identityMatches(self: *Capture, port: Port) !void {
        if (try port.read32(port.context, 0) != self.options.boot0 or
            try port.read32(port.context, 4) != self.options.boot1 or
            try port.read32(port.context, vga_register) != self.options.vga) return error.Unstable;
    }
    fn currentWindow(port: Port) !u32 {
        const value = try port.read32(port.context, window_register);
        if (!preflight.readable(value) or (value >> 24) & 3 == 1) return error.Inaccessible;
        return value;
    }

    /// At most one 4 KB block per step. A failed capture is never replayed;
    /// restore remains a separate bounded action against the same owner.
    pub fn step(self: *Capture, port: Port, output: []u8) !bool {
        if (self.failure) |err| return err;
        errdefer |err| self.failure = err;
        if (self.self_address == 0) {
            self.self_address = @intFromPtr(self);
            self.output_address = @intFromPtr(output.ptr);
        }
        if (output.len != self.options.range.bytes or @intFromPtr(output.ptr) != self.output_address) return error.Destination;
        try self.guard(port, self.options.deadline);
        switch (self.phase) {
            .observe => {
                try self.identityMatches(port);
                const value = try currentWindow(port);
                if (try currentWindow(port) != value) return error.Unstable;
                self.original = value;
                self.selected = (value & ~window_mask) | @as(u32, @intCast(self.options.range.address >> 16));
                self.phase = .retain;
            },
            .retain => {
                // The retention callback may partially succeed. No cleanup
                // may infer that its owner remained untouched on an error.
                try port.retain(port.context);
                self.phase = .select;
            },
            .select => {
                try self.identityMatches(port);
                if (try currentWindow(port) != self.original.?) return error.Unstable;
                if (self.selected != self.original.?) {
                    self.effects_possible = true;
                    try port.write32(port.context, window_register, self.selected);
                }
                if (try currentWindow(port) != self.selected) return error.Unstable;
                self.phase = .copy;
            },
            .copy => {
                try self.identityMatches(port);
                if (try currentWindow(port) != self.selected) return error.Unstable;
                const end = @min(self.copied + 4096, self.options.range.bytes);
                while (self.copied != end) : (self.copied += 4) {
                    const value = try port.read32(port.context, aperture + self.copied);
                    // All bit patterns are legitimate VRAM data, including
                    // 0xffffffff and values resembling PRI error sentinels.
                    std.mem.writeInt(u32, output[self.copied..][0..4], value, .little);
                }
                if (try currentWindow(port) != self.selected) return error.Unstable;
                if (self.copied == self.options.range.bytes) self.phase = .restore;
            },
            .restore => {
                try self.restore(port, self.options.deadline);
                self.phase = .done;
            },
            .done => {},
        }
        try self.guard(port, self.options.deadline);
        return self.phase == .done;
    }

    /// A fresh cleanup deadline may outlive the failed capture deadline.
    /// Only the same stable object/epoch may restore its saved window. This
    /// cannot reset a GPU, execute firmware, relocate VGA or stop device DMA.
    pub fn restore(self: *Capture, port: Port, deadline: u64) !void {
        try self.guard(port, deadline);
        try self.identityMatches(port);
        if (self.original) |original| {
            const current = try currentWindow(port);
            if (current != original) {
                if (!self.effects_possible or self.restored or current != self.selected) return error.Unstable;
                try port.write32(port.context, window_register, original);
            }
            if (try currentWindow(port) != original) return error.Unstable;
        } else if (self.effects_possible) return error.State;
        try self.identityMatches(port);
        try self.guard(port, deadline);
        self.restored = true;
    }
};
