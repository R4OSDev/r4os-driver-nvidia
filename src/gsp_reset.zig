//! Bounded GA106 function reset on the retained worker owner. No bus reset,
//! unowned sibling, register discovery, allocation or firmware RPC is involved.
//! A pre-firmware PCI snapshot and retired IRQ endpoint are prerequisites.
//! Completion leaves bus mastering OFF. It proves neither restored scanout
//! nor validity of old RM handles; a new firmware generation must rebuild them.
// NVIDIA570.144 kbifDoFunctionLevelReset_TU102, GA100 full-chip/counter HAL,
// GM107 configuration restore and gpuWaitForGfwBootComplete_TU102, under MIT.
// SPDX-FileCopyrightText: Copyright (c) 2013-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 2018-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: MIT
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
// Original R4OS lifetime, pacing and postcondition policy: Apache-2.0.
const std = @import("std");
const identity = @import("identity.zig");
const core = @import("gsp_core.zig");
pub const layout = @import("gsp_reset_layout.zig");
pub const quiet_ns = 100 * std.time.ns_per_ms;
pub const budget_ns = 5 * std.time.ns_per_s;
pub const reg = struct {
    pub const device_capability: u16 = 0x7c;
    pub const device_control: u16 = 0x80;
    pub const downstream: u16 = 0x84c;
    pub const config_base: u32 = 0x88000;
    pub const gfw_permission: u32 = 0x118128;
    pub const gfw_progress: u32 = 0x118234;
};
const bus_master: u32 = 4;
const intx_disable: u32 = 1 << 10;
const flr_supported: u32 = 1 << 28;
const flr_trigger: u32 = 1 << 15;
const pending: u32 = 1 << 21;
const downstream_reset: u32 = 1 << 9;
pub const Io = struct {
    context: *anyopaque,
    generation: *const fn (*anyopaque) u64,
    now_ns: *const fn (*anyopaque) u64,
    /// The production owner checks stable boot/DMA holds and retired IRQs.
    admit: *const fn (*anyopaque, u64) anyerror!void,
    pci_read: *const fn (*anyopaque, u16) anyerror!u32,
    pci_write: *const fn (*anyopaque, u16, u32) anyerror!void,
    read32: *const fn (*anyopaque, u32) anyerror!u32,
    write32: *const fn (*anyopaque, u32, u32) anyerror!void,
};
pub const Config = struct {
    self_address: usize = 0,
    ready: bool = false,
    identity_word: u32 = 0,
    boot0: u32 = 0,
    boot1: u32 = 0,
    msi: u8 = 0,
    msix: u8 = 0,
    words: [1024]u32 = @splat(0),

    /// Before first firmware submission, not in the fault handler. Reads the
    /// fixed GA102/GA106 vendor map once; never scans PCI or sizes a BAR.
    pub fn capture(self: *Config, snapshot: *const identity.Snapshot, boot0: u32, boot1: u32, io: Io) !void {
        if (self.self_address != 0) return error.Busy;
        const chip = identity.chip(boot0, boot1) orelse return error.Profile;
        if (!@import("generation.zig").ga102Hal(chip.id) or !identity.isDisplay(snapshot.pci) or snapshot.pci.function != 0 or
            snapshot.pci.bus_kind != 2 or snapshot.caps.pcie != 0x78 or snapshot.caps.power_state != 0 or
            snapshot.command & 2 == 0) return error.Unsupported;
        const word = @as(u32, snapshot.pci.device_id) << 16 | snapshot.pci.vendor_id;
        if (try io.pci_read(io.context, 0) != word or try io.pci_read(io.context, 0x78) & 0xff != 0x10)
            return error.IdentityChanged;
        const capability = try io.pci_read(io.context, reg.device_capability);
        if (capability == 0xffffffff or capability & flr_supported == 0) return error.Unsupported;
        self.self_address = @intFromPtr(self);
        self.identity_word = word;
        self.boot0 = boot0; self.boot1 = boot1;
        self.msi = snapshot.caps.msi; self.msix = snapshot.caps.msix;
        for (0..1024) |index| {
            const offset: u16 = @intCast(index * 4);
            if (layout.contains(&layout.valid, offset)) self.words[index] = try io.pci_read(io.context, offset);
        }
        if (self.words[0] != word or self.words[1] & 0xffff != snapshot.command or
            self.words[reg.device_control / 4] & flr_trigger != 0 or
            (self.msi != 0 and self.words[self.msi / 4] & (1 << 16) != 0) or
            (self.msix != 0 and self.words[self.msix / 4] & (1 << 31) != 0)) return error.Configuration;
        for (&snapshot.bars, 0..) |*bar, index|
            if (self.words[4 + index] != bar.raw) return error.Configuration;
        if (try io.pci_read(io.context, 0) != word or
            try io.pci_read(io.context, 4) & 0xffff != snapshot.command) return error.IdentityChanged;
        self.ready = true;
    }
    pub fn valid(self: *const Config) bool {
        return self.self_address != 0 and self.self_address == @intFromPtr(self) and self.ready;
    }
    fn command(self: *const Config) u32 {
        // Status is W1C. Never echo it or enable DMA during configuration.
        return (self.words[1] & 0xffff & ~bus_master) | intx_disable;
    }
    fn restoreWord(self: *const Config, offset: u16) u32 {
        var value = self.words[offset / 4];
        if (offset == reg.device_control) value &= 0x7fff; // no status W1C or new FLR
        if (offset == self.msi and self.msi != 0) value &= ~@as(u32, 1 << 16);
        if (offset == self.msix and self.msix != 0) value = (value & ~@as(u32, 1 << 31)) | (1 << 30);
        if (offset == reg.downstream) value &= ~downstream_reset;
        return value;
    }
};
pub const Phase = enum { detached, disable_dma, drain, trigger, quiet, config_wait, bars, command,
    restore, gfw, counter_trigger, counter_wait, verify, complete, failed };
/// Borrowed proof, valid only while this exact reset owner remains complete
/// and bus mastering has not been resumed. It cannot authorize display output.
pub const Quiescence = struct {
    owner: *const Reset,
    epoch: u64,
    pub fn valid(self: Quiescence, epoch: u64) bool {
        return epoch != 0 and self.epoch == epoch and self.owner.self_address == @intFromPtr(self.owner) and
            self.owner.phase == .complete and self.owner.failure == null and self.owner.epoch == epoch and
            self.owner.triggered and !self.owner.resumed and self.owner.io != null and
            self.owner.io.?.generation(self.owner.io.?.context) == epoch;
    }
};
pub const Reset = struct {
    self_address: usize = 0,
    config: ?*const Config = null,
    io: ?Io = null,
    epoch: u64 = 0,
    phase: Phase = .detached,
    failed_phase: ?Phase = null,
    failure: ?anyerror = null,
    deadline: u64 = 0,
    last_clock: u64 = 0,
    trigger_time: u64 = 0,
    cursor: u16 = 0,
    triggered: bool = false,
    resumed: bool = false,
    pci_status: u32 = 0,
    gfw_status: u32 = 0,
    falcon_status: u32 = 0,

    pub fn open(self: *Reset, config: *const Config, epoch: u64, io: Io) !void {
        if (self.self_address != 0) return error.Busy; // one attempt for this device lifetime
        if (!config.valid()) return error.Unsupported;
        if (epoch == 0 or epoch != io.generation(io.context)) return error.Stale;
        try io.admit(io.context, epoch);
        const current = io.now_ns(io.context);
        if (current == 0 or current == std.math.maxInt(u64)) return error.Clock;
        self.* = .{ .self_address = @intFromPtr(self), .config = config, .io = io,
            .epoch = epoch, .phase = .disable_dma, .last_clock = current,
            .deadline = try std.math.add(u64, current, budget_ns) };
    }
    pub fn step(self: *Reset) !bool {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.resumed) return error.State;
        if (self.failure) |err| return err;
        return self.advance() catch |err| {
            self.failure = err; self.failed_phase = self.phase; self.phase = .failed;
            return err;
        };
    }
    fn advance(self: *Reset) !bool {
        const io = self.io orelse return error.State;
        const config = self.config orelse return error.State;
        if (!config.valid() or self.epoch != io.generation(io.context)) return error.Stale;
        try io.admit(io.context, self.epoch);
        const current = io.now_ns(io.context);
        if (current == std.math.maxInt(u64) or current < self.last_clock) return error.Clock;
        self.last_clock = current;
        if (self.phase == .complete) return true;
        if (current >= self.deadline) return error.Timeout;
        switch (self.phase) {
            .disable_dma => {
                if (try io.pci_read(io.context, 0) != config.identity_word) return error.IdentityChanged;
                const capability = try io.pci_read(io.context, reg.device_capability);
                if (capability == 0xffffffff or capability & flr_supported == 0) return error.Unsupported;
                // Failed acknowledgement retains resources even if this write reached hardware.
                const command = try io.pci_read(io.context, 4);
                if (command == 0xffffffff) return error.Disappeared;
                try io.pci_write(io.context, 4, (command & 0xffff & ~bus_master) | intx_disable);
                if (try io.pci_read(io.context, 4) & (bus_master | intx_disable) != intx_disable) return error.BusMaster;
                self.phase = .drain;
            },
            .drain => {
                self.pci_status = try io.pci_read(io.context, reg.device_control);
                if (self.pci_status == 0xffffffff) return error.Disappeared;
                if (self.pci_status & pending != 0) return false;
                self.phase = .trigger;
            },
            .trigger => {
                if (try io.pci_read(io.context, 4) & bus_master != 0) return error.BusMaster;
                self.triggered = true; // retain before a potentially posted write
                self.trigger_time = current;
                try io.pci_write(io.context, reg.device_control, (self.pci_status & 0x7fff) | flr_trigger);
                self.phase = .quiet;
            },
            .quiet => {
                // No configuration or BAR access during the mandatory100ms.
                if (current - self.trigger_time < quiet_ns) return false;
                self.phase = .config_wait;
            },
            .config_wait => {
                const word = try io.pci_read(io.context, 0);
                if (word == 0xffffffff or word == 0xffff0001 or word == 1) return false;
                if (word != config.identity_word) return error.IdentityChanged;
                self.cursor = 0; self.phase = .bars;
            },
            .bars => {
                // Restore the exact previously mapped BARs, without sizing or remapping.
                const offset: u16 = 0x10 + self.cursor * 4;
                try io.pci_write(io.context, offset, config.words[offset / 4]);
                if (try io.pci_read(io.context, offset) != config.words[offset / 4]) return error.Configuration;
                self.cursor += 1;
                if (self.cursor == 6) self.phase = .command;
            },
            .command => {
                try io.pci_write(io.context, 4, config.command());
                if (try io.pci_read(io.context, 4) & 0xffff != config.command()) return error.Configuration;
                if (try io.read32(io.context, 0) != config.boot0 or
                    try io.read32(io.context, 4) != config.boot1) return error.IdentityChanged;
                self.cursor = 0; self.phase = .restore;
            },
            .restore => {
                // One vendor-approved dword per worker slice. Fn0 uses the
                // PCFG BAR0 mirror, as the GA106 inherited restore HAL does.
                while (self.cursor < 4096) {
                    const offset = self.cursor; self.cursor += 4;
                    if (offset == 4 or !layout.contains(&layout.writable, offset)) continue;
                    try io.write32(io.context, reg.config_base + offset, config.restoreWord(offset));
                    return false;
                }
                self.phase = .gfw;
            },
            .gfw => {
                self.falcon_status = try io.read32(io.context, core.reg.cpuctl);
                if (self.falcon_status == 0xffffffff) return error.Disappeared;
                const permission = try io.read32(io.context, reg.gfw_permission);
                if (permission == 0xffffffff) return error.Disappeared;
                if (permission & 1 == 0) return false; // no protected scratch read
                self.gfw_status = try io.read32(io.context, reg.gfw_progress);
                if (self.gfw_status == 0xffffffff) return error.Disappeared;
                if (self.falcon_status & core.bits.halted == 0 or self.gfw_status & 0xff != 0xff) return false;
                self.phase = .counter_trigger;
            },
            .counter_trigger => {
                const value = try io.pci_read(io.context, reg.downstream);
                if (value == 0xffffffff) return error.Disappeared;
                try io.pci_write(io.context, reg.downstream, value | downstream_reset);
                self.phase = .counter_wait;
            },
            .counter_wait => {
                const value = try io.pci_read(io.context, reg.downstream);
                if (value == 0xffffffff) return error.Disappeared;
                if (value & downstream_reset != 0) return false;
                self.phase = .verify;
            },
            .verify => {
                if (try io.pci_read(io.context, 0) != config.identity_word or
                    try io.read32(io.context, 0) != config.boot0 or try io.read32(io.context, 4) != config.boot1)
                    return error.IdentityChanged;
                if (try io.pci_read(io.context, 4) & 0xffff != config.command()) return error.BusMaster;
                self.pci_status = try io.pci_read(io.context, reg.device_control);
                if (self.pci_status == 0xffffffff or self.pci_status & (pending | flr_trigger) != 0) return error.Transactions;
                for (0..6) |index| if (try io.pci_read(io.context, @intCast(0x10 + index * 4)) != config.words[4 + index])
                    return error.Configuration;
                self.phase = .complete;
                return true;
            },
            else => return error.State,
        }
        return false;
    }
    pub fn quiescence(self: *const Reset) ?Quiescence {
        const proof: Quiescence = .{ .owner = self, .epoch = self.epoch };
        return if (proof.valid(self.epoch)) proof else null;
    }
    /// Call only after all old DMA owners have consumed their quiescence and
    /// the fresh firmware generation has been staged. Invalidates every proof
    /// before the first possible bus-master effect, including failed writes.
    pub fn resumeDma(self: *Reset) !void {
        const proof = self.quiescence() orelse return error.State;
        const io = self.io.?;
        try io.admit(io.context, proof.epoch);
        if (try io.pci_read(io.context, 4) & bus_master != 0) return error.BusMaster;
        self.resumed = true;
        try io.pci_write(io.context, 4, self.config.?.command() | bus_master);
        if (try io.pci_read(io.context, 4) & 0xffff != self.config.?.command() | bus_master) return error.BusMaster;
    }
};
