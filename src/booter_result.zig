//! Normal GA106 cold-load/unload arguments and results, RM 570.144.
//! Suspend/resume and GC6 need their own retained state and are not selected
//! by this normal-boot profile. No result here grants device quiescence.
// Adapted from kernel_gsp_booter_tu102.c and kgspIsWpr2Up_TU102.
// SPDX-FileCopyrightText: Copyright (c) 2022-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// Original R4OS admission/report interfaces: Apache-2.0.
const state = @import("fwsec_state.zig");
const radix = @import("gsp_radix.zig");
pub const Command = union(enum) { normal_load: u64, normal_unload };
pub const Error = error{ Address, Mailbox, BooterError, RegisterUnavailable };
pub const wpr_hi_register: u32 = 0x1fa828;
pub const Report = struct {
    command: Command,
    skipped: bool = false,
    wpr_hi_before: ?u32 = null,
    wpr_hi_after: ?u32 = null,
};

pub fn arguments(command: Command) Error![2]?u32 {
    return switch (command) {
        .normal_load => |address| blk: {
            // The normal R4OS WPR metadata occupies one retained DMA page.
            // Never replace its device address with a CPU pointer or VRAM.
            if (address == 0 or address & (radix.page_bytes - 1) != 0 or
                address > radix.dma_mask or radix.page_bytes - 1 > radix.dma_mask - address) return error.Address;
            break :blk .{ @truncate(address), @truncate(address >> 32) };
        },
        .normal_unload => .{ 0xff, 0xff },
    };
}
pub fn wprUp(value: u32) Error!bool {
    if (!state.readable(value)) return error.RegisterUnavailable;
    return value >> 4 != 0;
}
pub fn checkMailboxes(values: [2]?u32) Error!void {
    const code = values[0] orelse return error.Mailbox;
    if (values[1] == null) return error.Mailbox;
    // Mailboxes are raw firmware data: even all-one/sentinel-looking values
    // in mailbox1 have no documented failure meaning. Mailbox0 must be zero.
    if (code != 0) return error.BooterError;
}
