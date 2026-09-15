//! Restore the reserved console memory after proven old-generation GPU stop.
//! Rebuild scanout separately through C67D; BAR1 completion is not a display
//! receipt. The console and its new firmware/channel graph remain resident.
// BAR1 bind/poll follows NVIDIA 570.144 kern_bus_tu102.c and dev_vm.h.
// Copyright (c) 2017-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
const std = @import("std");
const a = @import("r4os").abi;
const vram = @import("boot_vram_lease.zig");
const reset = @import("gsp_reset.zig");
const reader = @import("bar1_reader.zig");
const walk = @import("bar1_walk.zig");
const pramin = @import("pramin.zig");
const image = @import("gsp_display_image.zig");
pub const Io = struct {
    context: *anyopaque,
    generation: *const fn (*anyopaque) u64,
    now_ns: *const fn (*anyopaque) u64,
    read32: *const fn (*anyopaque, u32) anyerror!u32,
    write32: *const fn (*anyopaque, u32, u32) anyerror!void,
};
pub const Owner = struct {
    self_address: usize = 0,
    lease: ?*vram.Lease = null,
    reservation: ?vram.Binding = null,
    io: ?Io = null,
    epoch: u64 = 0,
    stopped_epoch: u64 = 0,
    phase: enum { detached, pages, pixels, staged, bind, wait_bind, verify_pages, verify_map, ready, failed } = .detached,
    deadline: u64 = 0,
    last_clock: u64 = 0,
    cursor: u64 = 0,
    physical: u64 = 0,
    bytes: u64 = 0,
    boot: a.GfxNativeBootInfo = .{},
    control: walk.Control = undefined,
    consumer: usize = 0,
    confirmed: bool = false,
    callback_generation: u64 = 0,
    scratch: [4096]u8 = undefined,

    pub fn open(self: *Owner, lease: *vram.Lease, proof: reset.Quiescence, io: Io) !void {
        if (self.self_address != 0 or lease.console_owner != 0) return error.Busy;
        const reservation = try lease.binding(.vga);
        const held = lease.display.?;
        const map = lease.boot_mapping.?;
        const boot = held.original_boot orelse return error.Stale;
        const bytes = try std.math.mul(u64, boot.pitch, boot.height);
        if (!proof.valid(proof.epoch) or io.generation(io.context) != proof.epoch or held.firmware_owner == 0 or
            !held.boot.native_adopted or !held.register_access.valid() or map.range_count != 1 or
            map.page_count > @import("boot_mapping.zig").max_pages or map.control == null or
            map.surface_bytes != boot.byte_length or map.ranges[0].bytes != boot.byte_length or
            boot.byte_length == 0 or bytes > boot.byte_length or bytes > held.boot.read.byte_length or
            held.boot.read.cpu_address == 0 or held.boot.read.lease.id == 0 or
            boot.format != a.gfx_buffer_format_xrgb8888 or map.ranges[0].address & 4095 != 0) return error.Unsupported;
        const descriptor: image.Image = .{ .dma = 1, .channel = 1, .width = boot.width, .height = boot.height,
            .pitch = boot.pitch, .format = boot.format, .bytes = boot.byte_length, .offset = 0 };
        try image.validate(descriptor);
        if (map.control.?.bind_status & 3 != 0 or map.control.?.block & 0x70000000 != 0 or
            map.ranges[0].address > map.framebuffer_bytes or boot.byte_length > map.framebuffer_bytes - map.ranges[0].address)
            return error.Descriptor;
        const now = io.now_ns(io.context);
        if (now == 0 or now == std.math.maxInt(u64)) return error.Clock;
        self.* = .{ .self_address = @intFromPtr(self), .lease = lease, .reservation = reservation, .io = io,
            .epoch = proof.epoch, .stopped_epoch = proof.epoch, .phase = .pages, .last_clock = now,
            .deadline = try std.math.add(u64, now, 10 * std.time.ns_per_s), .physical = map.ranges[0].address,
            .bytes = bytes, .boot = boot, .control = map.control.? };
        lease.console_owner = self.self_address;
    }
    pub fn valid(self: *const Owner, epoch: u64) bool {
        const lease = self.lease orelse return false;
        return self.self_address == @intFromPtr(self) and self.phase != .failed and self.epoch == epoch and epoch != 0 and
            lease.console_owner == self.self_address and lease.validates(self.reservation orelse return false) and
            self.io.?.generation(self.io.?.context) == epoch and lease.display.?.register_access.valid() and
            std.meta.eql(lease.display.?.original_boot, @as(?a.GfxNativeBootInfo, self.boot));
    }
    fn guard(self: *Owner) !void {
        if (!self.valid(self.epoch)) return error.Stale;
        const io = self.io.?;
        const now = io.now_ns(io.context);
        if (now == 0 or now == std.math.maxInt(u64) or now < self.last_clock) return error.Clock;
        self.last_clock = now;
        if (now >= self.deadline) return error.Deadline;
        if (try io.read32(io.context, 0) != self.control.boot0 or try io.read32(io.context, 4) != self.control.boot1) return error.Identity;
    }
    fn read(self: *Owner, address: u32) !u32 { return self.io.?.read32(self.io.?.context, address); }
    fn write(self: *Owner, address: u32, value: u32) !void {
        try self.io.?.write32(self.io.?.context, address, value);
        if (try self.read(0) != self.control.boot0) return error.Identity;
    }
    /// One exact page-sized PRAMIN transfer, with same-device readback and
    /// restoration of the worker's current window before any other work runs.
    fn transfer(self: *Owner, physical: u64, bytes: []u8, source: ?[]const u8) !void {
        if (bytes.len == 0 or bytes.len > 4096 or (physical | bytes.len) & 3 != 0 or
            physical >= self.lease.?.plan.?.fb_bytes or bytes.len > self.lease.?.plan.?.fb_bytes - physical) return error.Bounds;
        const offset: u32 = @intCast(physical & (pramin.aperture_bytes - 1));
        if (bytes.len > pramin.aperture_bytes - offset) return error.Bounds;
        try self.guard();
        const original = try self.read(pramin.window_register);
        if (original == 0xffffffff or (original >> 24) & 3 == 1) return error.Inaccessible;
        const selected = (original & ~pramin.window_mask) | @as(u32, @intCast((physical - offset) >> 16));
        // Once a posted selection was attempted, retain on any uncertainty.
        errdefer self.phase = .failed;
        if (selected != original) try self.write(pramin.window_register, selected);
        errdefer self.write(pramin.window_register, original) catch {};
        if (try self.read(pramin.window_register) != selected) return error.Unstable;
        var i: usize = 0;
        while (i < bytes.len) : (i += 4) {
            const address = pramin.aperture + offset + @as(u32, @intCast(i));
            if (source) |data| try self.io.?.write32(self.io.?.context, address, std.mem.readInt(u32, data[i..][0..4], .little));
            std.mem.writeInt(u32, bytes[i..][0..4], try self.read(address), .little);
        }
        if (try self.read(pramin.window_register) != selected) return error.Unstable;
        if (selected != original) try self.write(pramin.window_register, original);
        if (try self.read(pramin.window_register) != original) return error.Unstable;
        try self.guard();
        if (source) |data| if (!std.mem.eql(u8, data, bytes)) return error.Verification;
    }
    fn backupPage(self: *Owner, index: usize) ![]const u8 {
        const map = self.lease.?.boot_mapping.?;
        if (index >= map.page_count or map.map.lease.id == 0 or map.map.cpu_address == 0 or
            (index + 1) * 4096 > map.map.byte_length) return error.Descriptor;
        const pointer: [*]const u8 = @ptrFromInt(map.map.cpu_address);
        return pointer[index * 4096 ..][0..4096];
    }
    /// Old DMA must remain stopped throughout every restore slice. All page
    /// and pixel writes are restricted to the independently retained capture.
    pub fn stage(self: *Owner, proof: reset.Quiescence) !bool {
        if (!proof.valid(self.stopped_epoch) or self.epoch != self.stopped_epoch) return error.Retained;
        errdefer self.invalidate();
        try self.guard();
        const map = self.lease.?.boot_mapping.?;
        switch (self.phase) {
            .pages => {
                if (self.cursor < map.page_count) {
                    try self.transfer(map.pages[self.cursor], &self.scratch, try self.backupPage(@intCast(self.cursor)));
                    self.cursor += 1;
                } else { self.cursor = 0; self.phase = .pixels; }
            },
            .pixels => {
                const length: usize = @intCast(@min(self.bytes - self.cursor, 4096));
                if (length != 0) {
                    const pointer: [*]const u8 = @ptrFromInt(self.lease.?.display.?.boot.read.cpu_address);
                    try self.transfer(self.physical + self.cursor, self.scratch[0..length], pointer[self.cursor..][0..length]);
                    self.cursor += length;
                } else { self.cursor = 0; self.phase = .staged; }
            },
            .staged => return true,
            else => return error.State,
        }
        return self.phase == .staged;
    }
    pub fn activate(self: *Owner, epoch: u64) !void {
        if (self.phase != .staged or epoch <= self.stopped_epoch or self.io.?.generation(self.io.?.context) != epoch) return error.Stale;
        self.epoch = epoch;
    }
    pub fn imageInfo(self: *const Owner, epoch: u64, dma: u32, channel: u32) !image.Image {
        if (!self.valid(epoch) or self.epoch <= self.stopped_epoch or self.phase == .pages or self.phase == .pixels) return error.Stale;
        const value: image.Image = .{ .dma = dma, .channel = channel, .width = self.boot.width, .height = self.boot.height,
            .pitch = self.boot.pitch, .format = self.boot.format, .bytes = self.boot.byte_length, .offset = 0 };
        try image.validate(value); return value;
    }
    pub fn bindStep(self: *Owner) !bool {
        errdefer self.invalidate();
        if (self.phase == .staged) {
            const now = self.io.?.now_ns(self.io.?.context);
            if (now < self.last_clock or now == std.math.maxInt(u64)) return error.Clock;
            self.deadline = try std.math.add(u64, now, 5 * std.time.ns_per_s);
            self.phase = .bind;
        }
        try self.guard();
        const map = self.lease.?.boot_mapping.?;
        switch (self.phase) {
            .bind => { try self.write(reader.block_register, self.control.block); self.phase = .wait_bind; },
            .wait_bind => {
                if (try self.read(reader.bind_register) & 3 != 0) return false;
                if (try self.read(reader.block_register) != self.control.block) return error.Unstable;
                self.cursor = 0; self.phase = .verify_pages;
            },
            .verify_pages => {
                if (self.cursor < map.page_count) {
                    try self.transfer(map.pages[self.cursor], &self.scratch, null);
                    if (!std.mem.eql(u8, &self.scratch, try self.backupPage(@intCast(self.cursor)))) return error.Verification;
                    self.cursor += 1;
                } else { self.cursor = 0; self.phase = .verify_map; }
            },
            .verify_map => {
                const part = try walk.resolve(.{ .epoch = self.epoch, .deadline = self.deadline, .boot0 = self.control.boot0,
                    .boot1 = self.control.boot1, .bar = self.lease.?.display.?.snapshot.?.bars[1],
                    .framebuffer_bytes = map.framebuffer_bytes, .cpu_physical = self.boot.physical_address + self.cursor,
                    .bytes = self.boot.byte_length - self.cursor }, self.walkPort());
                if (part.mapped.address != self.physical + self.cursor or part.format != map.format or
                    part.control.block != self.control.block) return error.Verification;
                self.cursor += part.mapped.bytes;
                if (self.cursor == self.boot.byte_length) self.phase = .ready;
            },
            .ready => return true,
            else => return error.State,
        }
        return self.phase == .ready;
    }
    pub fn invalidate(self: *Owner) void { self.phase = .failed; self.confirmed = false; }
    pub fn authorize(self: *Owner, generation: u64, boot: *const a.GfxNativeBootInfo) bool {
        if (self.phase != .ready or !self.confirmed or self.consumer == 0 or !self.valid(self.epoch) or
            generation != self.callback_generation or boot.generation != generation or
            boot.width != self.boot.width or boot.height != self.boot.height or boot.pitch != self.boot.pitch or
            boot.format != self.boot.format or boot.physical_address != self.boot.physical_address or boot.byte_length != self.boot.byte_length) return false;
        return (self.read(reader.block_register) catch return false) == self.control.block and
            (self.read(reader.bind_register) catch return false) & 3 == 0;
    }
    fn cast(raw: *anyopaque) *Owner { return @ptrCast(@alignCast(raw)); }
    fn walkGeneration(raw: *anyopaque) u64 { const self = cast(raw); return if (self.valid(self.epoch)) self.epoch else 0; }
    fn walkNow(raw: *anyopaque) u64 { const io = cast(raw).io.?; return io.now_ns(io.context); }
    fn controls(raw: *anyopaque) !walk.Control {
        const self = cast(raw);
        return .{ .boot0 = try self.read(0), .boot1 = try self.read(4), .block = try self.read(reader.block_register), .bind_status = try self.read(reader.bind_register) };
    }
    fn readVram(raw: *anyopaque, address: u64, output: []u8) !void { try cast(raw).transfer(address, output, null); }
    fn walkPort(self: *Owner) walk.Reader { return .{ .context = self, .generation = walkGeneration, .now_ns = walkNow, .controls = controls, .read_vram = readVram }; }
};
