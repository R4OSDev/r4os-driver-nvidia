// src/nvidia/src/kernel/gpu/mmu/arch/pascal/kern_gmmu_fmt_gp10x.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2014-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// src/common/inc/swref/published/turing/tu102/dev_mmu.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2003-2022 NVIDIA CORPORATION & AFFILIATES
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
// src/common/inc/swref/published/pascal/gp100/dev_mmu.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2003-2022 NVIDIA CORPORATION & AFFILIATES
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
//! GA106 MMU v2 entries for an externally owned GPU address space.
//! This codec neither allocates pages nor publishes an entry or a TLB receipt.
//! Source constants: pinned NVIDIA570.144 Pascal MMU v2/Turing page kinds.
const std = @import("std");
pub const Error = error{ Address, Alignment, Kind, Level, Bounds };
pub const page_bytes: u64 = 4096;
pub const va_limit: u64 = @as(u64, 1) << 49;
// Match the direct DMA lease mask used by the existing private control BOs.
pub const system_limit: u64 = @as(u64, 1) << 47;
pub const video_limit: u64 = @as(u64, 1) << 37;
pub const Level = enum(u3) { root, pd2, pd1, dual, leaf };
pub const Aperture = enum { video, system_coherent };
pub const Policy = struct {
    aperture: Aperture,
    kind: u8 = 0,
    cached: bool = false,
    read_only: bool = false,
    privileged: bool = false,
    atomic: bool = false,
};
pub fn shift(level: Level) u6 {
    return switch (level) { .root => 47, .pd2 => 38, .pd1 => 29, .dual => 21, .leaf => 12 };
}
pub fn count(level: Level) u16 {
    return switch (level) { .root => 4, .dual => 256, else => 512 };
}
pub fn stride(level: Level) u8 {
    return if (level == .dual) 16 else 8;
}
pub fn extent(address: u64, length: u64) Error!void {
    if (length == 0 or address >= va_limit or length > va_limit - address) return error.Bounds;
    if ((address | length) & (page_bytes - 1) != 0) return error.Alignment;
}
pub fn index(level: Level, address: u64) Error!u16 {
    if (address >= va_limit) return error.Address;
    return @intCast((address >> shift(level)) & (count(level) - 1));
}
pub fn byteOffset(level: Level, address: u64) Error!usize {
    return @as(usize, try index(level, address)) * stride(level);
}
pub fn tableKey(level: Level, address: u64) Error!u64 {
    if (address >= va_limit) return error.Address;
    if (level == .root) return 0;
    const parent: Level = @enumFromInt(@intFromEnum(level) - 1);
    // Low three bits distinguish all five levels without losing VA bits.
    return ((address >> shift(parent)) << 3) | @intFromEnum(level);
}
fn physical(address: u64, aperture: Aperture) Error!void {
    const limit = if (aperture == .video) video_limit else system_limit;
    if (address >= limit or (aperture == .system_coherent and address == 0)) return error.Address;
    if (address & (page_bytes - 1) != 0) return error.Alignment;
}
/// Child directories and small-page tables live in held coherent system BOs.
/// In a dual PDE this word belongs at byte8; the big-page word stays zero.
pub fn directory(address: u64) Error!u64 {
    try physical(address, .system_coherent);
    return (address >> 4) | 0x0c; // APERTURE=SYS_COH, VOL=true, not a leaf.
}
pub fn page(address: u64, policy: Policy) Error!u64 {
    try physical(address, policy.aperture);
    // Only the existing uncompressed pitch/generic/depth kinds are admitted.
    if (policy.kind > 6) return error.Kind;
    return (address >> 4) | 1 |
        @as(u64, if (policy.aperture == .system_coherent) 4 else 0) |
        @as(u64, if (policy.cached) 0 else 8) |
        @as(u64, if (policy.read_only) 0x40 else 0) |
        @as(u64, if (policy.privileged) 0x20 else 0) |
        @as(u64, if (policy.atomic) 0 else 0x80) |
        (@as(u64, policy.kind) << 56);
}
pub fn empty(table: []const u8, level: Level) Error!bool {
    const size = @as(usize, count(level)) * stride(level);
    if (table.len != page_bytes) return error.Bounds;
    // Root padding is also owned and must remain zero; hidden garbage must
    // not qualify a page for later reuse even though HW uses only32 bytes.
    return std.mem.allEqual(u8, table[0..size], 0) and std.mem.allEqual(u8, table[size..], 0);
}
