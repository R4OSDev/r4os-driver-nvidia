//! One-shot firmware teardown on the actual retained native port and run.
//! FWSEC-SB precedes normal Booter Unload, following kgspTeardown_TU102.
//! This is not console restoration or a GPU-DMA quiescence/release proof.
// NVIDIA teardown ordering, RM570.144 kernel_gsp_tu102.c, under MIT:
// SPDX-FileCopyrightText: Copyright (c) 2017-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// Original R4OS binding, lifetime and bounded execution: Apache-2.0.
const std = @import("std");
const native = @import("gsp_sequencer_port.zig");
const memory = @import("gsp_run_memory.zig");
const logs = @import("gsp_logs.zig");
const firmware = @import("falcon_run.zig");
const booter = @import("booter_result.zig");
pub const Phase = enum { sb, unload, complete };
pub const Report = struct { sb: firmware.Result, unload: firmware.Result };
pub const Recovery = struct {
    self_address: usize = 0,
    device: ?*native.Port = null,
    backing: ?*memory.Lease = null,
    reader: ?*logs.Reader = null,
    epoch: u64 = 0,
    deadline: u64 = 0,
    phase: Phase = .sb,
    options: [2]firmware.Options = undefined,
    operation: ?firmware.Operation = null,
    sb_result: ?firmware.Result = null,
    report: ?Report = null,
    failure: ?anyerror = null,

    /// Same serialized init/work owner as the native port. No allocations or
    /// new mappings. A healthy runtime must first perform its orderly RM
    /// unload; this operation supplies the remaining firmware teardown, also
    /// after an unrecoverable startup/transport failure. No automatic retry.
    pub fn open(self: *Recovery, device: *native.Port, reader: *logs.Reader, deadline: u64) !void {
        if (self.self_address != 0) return error.Busy;
        const owner = device.owner orelse return error.State;
        const backing = owner.queue_memory orelse return error.Unsupported;
        const inputs = try backing.retainedInputs();
        const epoch = backing.queue.epoch;
        if (reader.self_address == 0 or reader.self_address != @intFromPtr(reader) or reader.memory != backing or
            reader.epoch != epoch or backing.log_owner != reader.self_address or reader.busy) return error.Logs;
        const options = try commands(device.boot0, epoch, deadline, &inputs);
        for (options) |command| _ = try firmware.Operation.init(command);
        self.* = .{ .self_address = @intFromPtr(self), .device = device, .backing = backing,
            .reader = reader, .epoch = epoch, .deadline = deadline, .options = options };
        errdefer |err| {
            self.failure = err;
            if (device.recovery_owner == self.self_address and device.recovery_failure == null) device.recovery_failure = err;
        }
        try reader.setPolling(false);
        try device.beginRecovery(self.self_address, deadline);
        if (try device.recoveryRead(self.self_address, 0) != device.boot0 or
            try device.recoveryRead(self.self_address, 4) != device.boot1) return error.IdentityChanged;
        try self.check();
        // No old operation is cleared: the native port keeps its original
        // failure, partial firmware/core state and outstanding receipt.
        self.operation = try firmware.Operation.init(self.options[0]);
    }
    fn commands(boot0: u32, epoch: u64, deadline: u64, inputs: *const memory.Inputs) ![2]firmware.Options {
        if (inputs.booters[1].prepared.operation != .unload) return error.Binding;
        return .{
            .{ .engine = .gsp, .boot0 = boot0, .epoch = epoch, .deadline = deadline,
                .plan = inputs.fwsec_sb, .fwsec = .sb },
            .{ .engine = .sec2, .boot0 = boot0, .epoch = epoch, .deadline = deadline,
                .plan = inputs.booters[1].plan, .booter = .normal_unload,
                .mailboxes = try booter.arguments(.normal_unload), .keep_logs_suspended = true },
        };
    }
    fn check(self: *Recovery) !void {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.failure != null) return error.State;
        const device = self.device orelse return error.State;
        const backing = self.backing orelse return error.State;
        const reader = self.reader orelse return error.State;
        try device.checkRecovery(self.self_address);
        if (device.recoveryEpoch(self.self_address) != self.epoch or device.recovery_deadline != self.deadline or
            device.owner.?.queue_memory != backing or reader.self_address != @intFromPtr(reader) or
            reader.memory != backing or reader.epoch != self.epoch or reader.enabled or reader.busy or
            backing.log_owner != reader.self_address) return error.Binding;
        const inputs = try backing.recoveryInputs(self.self_address);
        if (!std.meta.eql(self.options, try commands(device.boot0, self.epoch, self.deadline, &inputs))) return error.Binding;
    }
    pub fn step(self: *Recovery) !bool {
        // A moved/copied observer cannot poison or mutate its real owner.
        if (self.self_address == 0 or self.self_address != @intFromPtr(self)) return error.State;
        return self.advance() catch |err| {
            if (self.failure == null) self.failure = err;
            if (self.device) |device| if (device.recovery_owner == self.self_address and device.recovery_failure == null) {
                device.recovery_failure = err;
            };
            self.report = null;
            return err;
        };
    }
    fn advance(self: *Recovery) !bool {
        try self.check();
        if (self.phase == .complete) return true;
        const operation = if (self.operation) |*value| value else return error.State;
        const index: usize = if (self.phase == .sb) 0 else 1;
        if (!std.meta.eql(operation.options, self.options[index])) return error.Binding;
        if (!try operation.step(.{ .context = self, .generation = generation, .now_ns = now,
            .admit = admit, .read32 = read, .write32 = write, .log_polling = polling })) return false;
        const result = operation.result orelse return error.State;
        try self.check();
        if (self.phase == .sb) {
            if (result.fwsec == null or result.fwsec.?.command != .sb) return error.State;
            self.sb_result = result;
            self.operation = try firmware.Operation.init(self.options[1]);
            self.phase = .unload;
            return false;
        }
        if (result.booter == null or result.booter.?.command != .normal_unload) return error.State;
        self.report = .{ .sb = self.sb_result orelse return error.State, .unload = result };
        self.phase = .complete;
        // Keep the final operation, all DMA backing, mapping and display
        // owners. Neither WPR-down nor a Falcon halt makes them reusable.
        return true;
    }
    fn from(raw: *anyopaque) *Recovery { return @ptrCast(@alignCast(raw)); }
    fn generation(raw: *anyopaque) u64 {
        const self = from(raw);
        self.check() catch return 0;
        return self.epoch;
    }
    fn now(raw: *anyopaque) u64 {
        const self = from(raw);
        return self.device.?.clock.?.nowNs();
    }
    fn admit(raw: *anyopaque, options: *const firmware.Options) !void {
        const self = from(raw);
        try self.check();
        const index: usize = switch (self.phase) { .sb => 0, .unload => 1, .complete => return error.State };
        if (!std.meta.eql(options.*, self.options[index])) return error.Binding;
        if (self.phase == .unload and self.sb_result == null) return error.State;
    }
    fn read(raw: *anyopaque, address: u32) !u32 {
        const self = from(raw);
        try self.check();
        return self.device.?.recoveryRead(self.self_address, address);
    }
    fn write(raw: *anyopaque, address: u32, value: u32) !void {
        const self = from(raw);
        try self.check();
        try self.device.?.recoveryWrite(self.self_address, address, value);
    }
    fn polling(raw: *anyopaque, enabled: bool) !void {
        const self = from(raw);
        try self.check();
        if (enabled) return error.Logs;
        try self.reader.?.setPolling(false);
    }
};
