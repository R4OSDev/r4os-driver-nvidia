//! Post-halt FWSEC checks from kgspExecuteFwsec_TU102, NVIDIA 570.144.
//! The caller must perform the actual admitted reset/upload/start/halt first.
//! These register results prove neither global GPU quiescence nor GSP readiness.
// SPDX-FileCopyrightText: Copyright (c) 2021-2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// Original R4OS bounded observation and lifetime interfaces: Apache-2.0.
const state = @import("fwsec_state.zig");
pub const Command = @import("fwsec_prepare.zig").Command;
pub const Error = error{ State, Address, RegisterUnavailable, FrtsError, WprMissing, WprTarget, SbProtection, SbProgress, SbError };
// Original TU102 published dev_bus/dev_fb/dev_gc6_island(+addendum) headers.
pub const frts_registers = [3]u32{ 0x1438, 0x1fa828, 0x1fa824 };
pub const sb_registers = [3]u32{ 0x118128, 0x118234, 0x1454 };
pub const Report = struct {
    command: Command,
    // Exact words in command-specific read order, including unrelated bits.
    // WPR HI is a 4-KB address field, not an exclusive extent end.
    raw: [3]u32,
};
pub const Observer = struct {
    command: Command,
    raw: [3]u32 = @splat(0),
    observed: u8 = 0,
    failure: ?Error = null,

    pub fn init(command: Command) Error!Observer {
        if (command == .frts) {
            const offset = command.frts;
            // GA106 WPR address fields are 28 bits in 4-KB units. Reject
            // truncation of the complete fixed 1-MB target before any reset.
            if (offset == 0 or offset & 4095 != 0 or offset > (@as(u64, 1) << 40) - 0x100000) return error.Address;
        }
        return .{ .command = command };
    }
    pub fn nextRegister(self: *const Observer) ?u32 {
        if (self.failure != null or self.observed >= 3) return null;
        return (if (self.command == .frts) frts_registers else sb_registers)[self.observed];
    }
    pub fn accept(self: *Observer, value: u32) Error!bool {
        if (self.nextRegister() == null) return error.State;
        errdefer |err| self.failure = err;
        const index = self.observed;
        self.raw[index] = value;
        self.observed += 1; // Preserve even a failing raw observation.
        if (!state.readable(value)) return error.RegisterUnavailable;
        switch (self.command) {
            .frts => |offset| switch (index) {
                0 => if (value >> 16 != 0) return error.FrtsError,
                1 => if (value >> 4 == 0) return error.WprMissing,
                2 => if (@as(u64, value >> 4) != offset >> 12) return error.WprTarget,
                else => unreachable,
            },
            .sb => switch (index) {
                0 => if (value & 1 == 0) return error.SbProtection,
                1 => if (value & 0xff != 0xff) return error.SbProgress,
                2 => if (value & 0xffff != 0) return error.SbError,
                else => unreachable,
            },
        }
        return self.observed == 3;
    }
    pub fn report(self: *const Observer) Error!Report {
        if (self.failure != null or self.observed != 3) return error.State;
        return .{ .command = self.command, .raw = self.raw };
    }
};
