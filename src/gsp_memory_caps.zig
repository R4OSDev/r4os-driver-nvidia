// NVIDIA 570.144 memory capability definitions and interpretation (MIT).
// NVIDIA570.144/src/common/sdk/nvidia/inc/ctrl/ctrl0080/ctrl0080fb.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2004-2017 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// NVIDIA570.144/src/nvidia/src/kernel/gpu/mem_mgr/mem_mgr_ctrl.c
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
// NVIDIA570.144/src/nvidia-modeset/kapi/src/nvkms-kapi.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2015-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Device framebuffer capabilities from the pinned RM control, not PCI names.
//! These are memory-layout facts; engine and display-mode admission is separate.
const std = @import("std");
const exchange = @import("gsp_exchange.zig");
pub const function: u32 = 76;
pub const command: u32 = 0x801307;
pub const bytes: usize = 27; // 24-byte raw RPC header + 3-byte fixed caps table.
pub const Error = exchange.Error;
pub const Binding = struct { epoch: u64, client: u32, device: u32 };
pub const Info = struct {
    binding: Binding,
    raw: [3]u8,

    pub fn gpuCachedSystem(self: Info) bool {
        return self.raw[0] & 8 != 0;
    }
    pub fn renderSystem(self: Info) bool {
        return self.raw[0] & 1 != 0;
    }
    pub fn scanoutSystem(self: Info) bool {
        return self.raw[0] & 4 != 0;
    }
    pub fn blocklinear(self: Info) bool {
        return self.raw[0] & 2 != 0;
    }
    // Absence of the 512-byte flag does not prove a different GOB geometry.
    pub fn gobBytes(self: Info) u16 {
        return if (self.blocklinear() and self.raw[1] & 1 != 0) 512 else 0;
    }
    // Same selection as pinned NVKMS KAPI. This never enables compression.
    pub fn genericPageKind(self: Info) u8 {
        return if (self.raw[1] & 0x80 != 0) 0x06 else 0xfe;
    }
    pub fn vidmemCleared(self: Info) bool {
        return self.raw[2] & 2 != 0;
    }
    pub fn partialUnmap(self: Info) bool {
        return self.raw[2] & 0x10 != 0;
    }
};
pub const Reply = union(enum) { ok: Info, rejected: u32 };
fn put(out: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, out[offset..][0..4], value, .little);
}
pub fn encode(binding: Binding, output: []u8) Error![]const u8 {
    if (binding.epoch == 0 or binding.client == 0 or binding.device == 0 or binding.client == binding.device) return error.Handle;
    if (output.len < bytes) return error.Bounds;
    const out = output[0..bytes];
    @memset(out, 0);
    put(out, 0, binding.client);
    put(out, 4, binding.device);
    put(out, 8, command);
    put(out, 16, 3);
    return out;
}
pub fn decode(binding: Binding, record: exchange.message.Record) Error!Reply {
    if (record.rpc.function != function or record.rpc.cpu_rm_gfid != 0) return error.Unexpected;
    if (record.rpc.result == exchange.message.pending) return error.Payload;
    // An actual RPC failure has no successful capability result. Do not
    // synthesize support or keep driving an uncertain protocol channel.
    if (record.rpc.result != 0) return error.FirmwareResult;
    if (record.payload.len != bytes) return error.Payload;
    var request: [bytes]u8 = undefined;
    _ = try encode(binding, &request);
    for (record.payload[0..24], 0..) |value, i| {
        if (i >= 12 and i < 16) continue; // NV_STATUS
        if (value != request[i]) return error.Unexpected;
    }
    const status = std.mem.readInt(u32, record.payload[12..16], .little);
    return if (status != 0) .{ .rejected = status } else .{ .ok = .{ .binding = binding, .raw = record.payload[24..27].* } };
}
