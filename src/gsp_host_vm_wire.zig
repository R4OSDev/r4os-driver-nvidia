// src/common/sdk/nvidia/inc/ctrl/ctrl0080/ctrl0080dma.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2006-2018 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// src/common/sdk/nvidia/inc/nvos.h
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
//! Original RM controls for binding and unbinding an external PDB.
//! No fabricated MAP_MEMORY_DMA reply and no inferred publication/retirement.
const std = @import("std");
const exchange = @import("gsp_exchange.zig");
const page = @import("gsp_host_page.zig");
pub const Error = exchange.Error || page.Error;
pub const function: u32 = 76;
pub const header_bytes = 24;
pub const max_bytes = header_bytes + 32;
pub const external_vaspace_flags: u32 = 8;
// NV0080 DMA_INVALIDATE_TLB follows the RM walker's root, which is separate
// from pExternalPDB, and its outer handler discards the void invalidator's
// outcome. It cannot replace the actual host-owned MMIO completion path.
pub const Operation = enum { bind, unbind };
pub const Binding = struct { epoch: u64, client: u32, device: u32, vaspace: u32, root_dma: u64 };
pub const Reply = union(enum) { ok, rejected: u32 };
pub fn command(operation: Operation) u32 {
    return switch (operation) { .bind => 0x801813, .unbind => 0x801814 };
}
pub fn length(operation: Operation) usize {
    return header_bytes + @as(usize, if (operation == .bind) 32 else 8);
}
fn put(out: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, out[at..][0..4], value, .little);
}
pub fn validate(binding: Binding) Error!void {
    if (binding.epoch == 0 or binding.client == 0 or binding.device == 0 or binding.vaspace == 0 or
        binding.client == binding.device or binding.client == binding.vaspace or binding.device == binding.vaspace) return error.Handle;
    _ = try page.directory(binding.root_dma);
}
pub fn encode(binding: Binding, operation: Operation, output: []u8) Error![]const u8 {
    try validate(binding);
    const size = length(operation);
    if (output.len < size) return error.Bounds;
    const out = output[0..size];
    @memset(out, 0);
    put(out, 0, binding.client);
    put(out, 4, binding.device);
    put(out, 8, command(operation));
    put(out, 16, @intCast(size - header_bytes));
    if (operation == .bind) {
        std.mem.writeInt(u64, out[24..32], binding.root_dma, .little);
        put(out, 32, page.count(.root));
        // SYS_COH and ALL_CHANNELS; neither EXTEND_VASPACE nor IGNORE_BUSY.
        put(out, 36, 9);
        put(out, 40, binding.vaspace);
    } else put(out, 24, binding.vaspace);
    return out;
}
pub fn decode(binding: Binding, operation: Operation, record: exchange.message.Record) Error!Reply {
    if (record.rpc.function != function or record.rpc.cpu_rm_gfid != 0) return error.Unexpected;
    if (record.rpc.result == exchange.message.pending) return error.Payload;
    if (record.rpc.result != 0) return error.FirmwareResult;
    var request: [max_bytes]u8 = undefined;
    const expected = try encode(binding, operation, &request);
    if (record.payload.len != expected.len) return error.Payload;
    for (expected, record.payload, 0..) |before, after, i| {
        if (i >= 12 and i < 16) continue;
        if (before != after) return error.Unexpected;
    }
    const status = std.mem.readInt(u32, record.payload[12..16], .little);
    return if (status == 0) .ok else .{ .rejected = status };
}
