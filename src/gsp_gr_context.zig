// ExFiles/Reference/GFX/Nvidia/Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/gsp/rm/r535/gr.c
// /*
//  * Copyright 2023 Red Hat Inc.
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
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//  * THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
//  * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
//  * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  * OTHER DEALINGS IN THE SOFTWARE.
//  */
// ExFiles/Reference/GFX/Nvidia/OpenKernelModules-570.144/src/common/sdk/nvidia/inc/ctrl/ctrl0080/ctrl0080fifo.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2006-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// ExFiles/Reference/GFX/Nvidia/OpenKernelModules-570.144/src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080internal.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2020-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// ExFiles/Reference/GFX/Nvidia/OpenKernelModules-570.144/src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080gpu.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2006-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Pinned RM context-buffer requirements, independent of allocation/transport.
const std = @import("std");
pub const Error = error{ Bounds, Unsupported, Descriptor };
pub const max_buffers = 9;
pub const info_bytes = 8 * 26 * 8;
pub const Requirement = struct {
    id: u16 = 0,
    bytes: u64 = 0,
    alignment: u64 = 65536,
    global: bool = false,
    initialize: bool = false,
    readonly: bool = false,
};
pub const Entry = struct {
    physical: u64 = 0,
    address: u64 = 0,
    bytes: u64 = 0,
    id: u16 = 0,
    initialize: bool = false,
    nonmapped: bool = false,
};
pub const Promotion = struct {
    entries: [max_buffers]Entry = @splat(.{}),
    count: u8 = 0,
    golden: bool = false,
    pub fn validate(self: Promotion) Error!void {
        if (self.count == 0 or self.count > max_buffers) return error.Bounds;
        for (self.entries[0..self.count], 0..) |entry, i| {
            if (entry.id != 0 and entry.id != 2 and entry.id != 3 and entry.id != 4 and entry.id != 5 and entry.id != 6 and entry.id != 9 and entry.id != 10 and entry.id != 11) return error.Unsupported;
            for (self.entries[0..i]) |prior| if (prior.id == entry.id) return error.Descriptor;
            if (entry.id == 11 and !self.golden) return error.Descriptor;
            if (entry.nonmapped != (entry.id == 10 and entry.initialize)) return error.Descriptor;
            if (entry.initialize) {
                if (entry.physical == 0 or entry.physical & 4095 != 0 or entry.bytes == 0 or entry.physical > std.math.maxInt(u64) - entry.bytes) return error.Bounds;
            } else if (entry.physical != 0 or entry.bytes != 0) return error.Descriptor;
            if (entry.nonmapped) {
                if (entry.address != 0) return error.Descriptor;
            } else if (entry.address == 0 or entry.address & 4095 != 0 or entry.address >= (@as(u64, 1) << 40)) return error.Bounds;
        }
        for (self.entries[self.count..]) |entry| if (!std.meta.eql(entry, Entry{})) return error.Descriptor;
    }
};
pub const Plan = struct {
    buffers: [max_buffers]Requirement = @splat(.{}),
    count: u8 = 0,
    pub fn decode(data: []const u8) Error!Plan {
        if (data.len != info_bytes) return error.Bounds;
        var result: Plan = .{};
        const rows = [_]struct { index: usize, id: u16, global: bool, initialize: bool }{
            .{ .index = 0, .id = 0, .global = false, .initialize = true },
            .{ .index = 16, .id = 2, .global = false, .initialize = true },
            .{ .index = 17, .id = 3, .global = true, .initialize = false },
            .{ .index = 13, .id = 4, .global = true, .initialize = false },
            .{ .index = 19, .id = 5, .global = true, .initialize = false },
            .{ .index = 20, .id = 6, .global = true, .initialize = false },
            .{ .index = 23, .id = 9, .global = true, .initialize = true },
            .{ .index = 24, .id = 10, .global = true, .initialize = true },
        };
        for (rows) |row| {
            var bytes: u64 = std.mem.readInt(u32, data[row.index * 8..][0..4], .little);
            const reported_alignment: u64 = std.mem.readInt(u32, data[row.index * 8 + 4..][0..4], .little);
            if (bytes == 0) {
                if (row.id == 0 or row.id == 2 or row.id == 10) return error.Unsupported;
                continue;
            }
            if (reported_alignment != 0 and !std.math.isPowerOfTwo(reported_alignment)) return error.Bounds;
            if (row.id == 0) bytes = std.mem.alignForward(u64, bytes, 4096) + 64 * 4096;
            const page: u64 = if (bytes >= 2 * 1024 * 1024) 2 * 1024 * 1024 else 65536;
            const alignment = @max(reported_alignment, if (row.id == 5) std.math.ceilPowerOfTwo(u64, bytes) catch return error.Bounds else page);
            if (alignment > (@as(u64, 1) << 30)) return error.Bounds;
            result.buffers[result.count] = .{ .id = row.id, .bytes = bytes, .alignment = @max(alignment, 65536),
                .global = row.global, .initialize = row.initialize, .readonly = row.id == 10 };
            result.count += 1;
            if (row.id == 10) {
                result.buffers[result.count] = result.buffers[result.count - 1];
                result.buffers[result.count].id = 11;
                result.count += 1;
            }
        }
        return result;
    }
};
