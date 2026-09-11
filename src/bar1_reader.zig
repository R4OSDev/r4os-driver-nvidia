//! Serialized PRAMIN reader borrowed from the live boot-display capture.
//! Only BAR0_WINDOW is written; no bind, page-table mutation or GPU start.
// PF register offsets follow NVIDIA 570.144 dev_vm.h, GPU_VREG_RD32 and
// gpuGetVirtRegPhysOffset_TU102: physical functions add 0xb80000.
// Window selection follows the existing MIT-attributed GM107 PRAMIN path.
// R4OS bounds, ownership and failure policy: Apache-2.0.
// Copyright (c) 2003-2023 NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2021-2024 NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2004-2021 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2004-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
const std = @import("std");
const boot = @import("boot_vram.zig");
const bar0 = @import("bar0.zig");
const walk = @import("bar1_walk.zig");
const state = @import("fwsec_state.zig");
const pramin = @import("pramin.zig");
pub const block_register: u32 = 0xb80f40;
pub const bind_register: u32 = 0xb80f50;
pub const max_read = 4096;
pub const Reader = struct {
    self_address: usize = 0,
    parent: ?*boot.Capture = null,
    access: bar0.Lease = .{},
    epoch: u64 = 0,
    deadline: u64 = 0,
    previous: u64 = 0,
    framebuffer_bytes: u64 = 0,
    boot0: u32 = 0,
    boot1: u32 = 0,
    vga: u32 = 0,
    original: u32 = 0,
    selected: u32 = 0,
    pending: bool = false,
    failure: ?anyerror = null,
    window_writes: u32 = 0,
    scratch: [max_read]u8 = undefined,

    pub fn open(self: *Reader, parent: *boot.Capture) !void {
        if (self.self_address != 0) return error.Busy;
        if (parent.snapshot == null or parent.snapshot.?.pci.function != 0 or
            parent.snapshot.?.bars[0].bytes < bind_register + 4 or !parent.effects_latched) return error.Profile;
        const raw = try parent.reobserve();
        const current = try state.decode(&raw);
        const operation = &parent.operation.?;
        self.self_address = @intFromPtr(self);
        self.parent = parent;
        self.epoch = parent.boot.held_generation;
        self.framebuffer_bytes = current.fb_bytes;
        self.boot0 = operation.options.boot0;
        self.boot1 = operation.options.boot1;
        self.vga = operation.options.vga;
        self.original = operation.original.?;
        errdefer |err| self.failure = err;
        try self.access.acquire(&parent.registers, &parent.context.?, &parent.snapshot.?, parent.chip.?);
        self.deadline = try self.freshDeadline();
        try self.guard(self.deadline);
        try self.identityMatches();
        if (try self.window() != self.original) return error.Unstable;
    }
    fn alive(self: *const Reader) bool {
        const parent = self.parent orelse return false;
        return self.self_address == @intFromPtr(self) and parent.self_address == @intFromPtr(parent) and
            parent.ready and parent.borrower == 0 and parent.boot.held_generation == self.epoch and self.epoch != 0 and
            parent.map.lease.id != 0 and parent.register_access.valid() and self.access.valid() and
            parent.registers.borrowedCount() == 2 and parent.context != null and parent.context.?.api == parent.registers.api;
    }
    fn cast(raw: *anyopaque) *Reader {
        return @ptrCast(@alignCast(raw));
    }
    fn generation(raw: *anyopaque) u64 {
        const self = cast(raw);
        return if (self.alive()) self.epoch else 0;
    }
    fn nowNs(raw: *anyopaque) u64 {
        const parent = cast(raw).parent orelse return std.math.maxInt(u64);
        return if (parent.clock) |clock| clock.nowNs() else std.math.maxInt(u64);
    }
    fn freshDeadline(self: *Reader) !u64 {
        const now = nowNs(self);
        if (now == 0 or now == std.math.maxInt(u64) or now < self.previous) return error.Clock;
        return std.math.add(u64, now, 5 * std.time.ns_per_s) catch error.Clock;
    }
    fn guard(self: *Reader, deadline: u64) !void {
        if (!self.alive()) return error.Stale;
        const now = nowNs(self);
        if (now == 0 or now == std.math.maxInt(u64) or now < self.previous) return error.Clock;
        self.previous = now;
        if (now >= deadline) return error.Deadline;
    }
    fn fence() void {
        asm volatile ("mfence" ::: .{ .memory = true });
    }
    fn read32(self: *Reader, address: u32) !u32 {
        if (address & 3 != 0 or (address != 0 and address != 4 and address != pramin.vga_register and
            address != pramin.window_register and address != block_register and address != bind_register and
            !(address >= pramin.aperture and address < pramin.aperture + pramin.aperture_bytes))) return error.Register;
        const view = try self.access.view(address, 4);
        const pointer: *volatile u32 = @ptrFromInt(view.cpu_address);
        fence();
        const value = pointer.*;
        fence();
        return value;
    }
    fn identityMatches(self: *Reader) !void {
        if (try self.read32(0) != self.boot0 or try self.read32(4) != self.boot1 or
            try self.read32(pramin.vga_register) != self.vga) return error.Unstable;
    }
    fn window(self: *Reader) !u32 {
        const value = try self.read32(pramin.window_register);
        if (!state.readable(value) or (value >> 24) & 3 == 1) return error.Inaccessible;
        return value;
    }
    fn writeWindow(self: *Reader, value: u32) !void {
        if (!self.pending or (value != self.original and value != self.selected)) return error.State;
        const view = try self.access.view(pramin.window_register, 4);
        const target: *volatile u32 = @ptrFromInt(view.cpu_address);
        self.window_writes += 1;
        fence();
        target.* = value;
        fence();
        if (try self.read32(0) != self.boot0) return error.Unstable; // Same-device posted-write drain.
    }
    fn restore(self: *Reader, deadline: u64) !void {
        try self.guard(deadline);
        try self.identityMatches();
        const current = try self.window();
        if (current != self.original) {
            if (!self.pending or current != self.selected) return error.Unstable;
            try self.writeWindow(self.original);
        }
        if (try self.window() != self.original) return error.Unstable;
        try self.identityMatches();
        try self.guard(deadline);
        self.pending = false;
    }
    pub fn controls(self: *Reader) !walk.Control {
        if (self.failure) |err| return err;
        errdefer |err| self.failure = err;
        try self.guard(self.deadline);
        try self.identityMatches();
        if (self.pending or try self.window() != self.original) return error.Unstable;
        const result: walk.Control = .{ .boot0 = self.boot0, .boot1 = self.boot1, .block = try self.read32(block_register), .bind_status = try self.read32(bind_register) };
        try self.guard(self.deadline);
        return result;
    }
    /// Exact aligned bytes, at most one 4-KB block within one 1-MB aperture.
    /// Output is published only after verified restoration. On failure the
    /// child MMIO lease blocks parent cleanup until close restores this window.
    pub fn read(self: *Reader, address: u64, output: []u8) !void {
        if (self.failure) |err| return err;
        errdefer |err| self.failure = err;
        if (output.len == 0 or output.len > max_read or (address | output.len) & 3 != 0 or
            address > self.framebuffer_bytes or output.len > self.framebuffer_bytes - address or
            address >= @as(u64, 1) << 40) return error.Bounds;
        const offset: u32 = @intCast(address & (pramin.aperture_bytes - 1));
        if (output.len > pramin.aperture_bytes - offset) return error.Bounds;
        try self.guard(self.deadline);
        try self.identityMatches();
        if (self.pending or try self.window() != self.original) return error.Unstable;
        self.selected = (self.original & ~pramin.window_mask) | @as(u32, @intCast((address - offset) >> 16));
        if (self.selected != self.original) {
            self.pending = true; // A failing posted write may already have taken effect.
            try self.writeWindow(self.selected);
        }
        try self.guard(self.deadline);
        if (try self.window() != self.selected) return error.Unstable;
        var copied: u32 = 0;
        while (copied < output.len) : (copied += 4)
            std.mem.writeInt(u32, self.scratch[copied..][0..4], try self.read32(pramin.aperture + offset + copied), .little);
        if (try self.window() != self.selected) return error.Unstable;
        try self.restore(self.deadline);
        @memcpy(output, self.scratch[0..output.len]);
    }
    fn readCallback(raw: *anyopaque, address: u64, output: []u8) !void {
        try cast(raw).read(address, output);
    }
    fn controlsCallback(raw: *anyopaque) !walk.Control {
        return cast(raw).controls();
    }
    pub fn port(self: *Reader) walk.Reader {
        return .{ .context = self, .generation = generation, .now_ns = nowNs, .controls = controlsCallback, .read_vram = readCallback };
    }
    pub fn close(self: *Reader) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        if (self.pending) {
            const until = self.freshDeadline() catch return false;
            self.restore(until) catch |err| {
                self.failure = err;
                return false;
            };
        }
        if (!self.access.release()) return false;
        self.* = .{};
        return true;
    }
};
