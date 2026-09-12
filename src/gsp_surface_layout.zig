// NVIDIA570.144/src/nvidia-modeset/src/nvkms-headsurface.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2017-2020 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// NVIDIA570.144/src/nvidia-modeset/include/nvkms-types.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2010-2020 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// NVIDIA570.144/kernel-open/nvidia-drm/nvidia-drm-helper.h
// /*
//  * Copyright (c) 2016, NVIDIA CORPORATION. All rights reserved.
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
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
// NVIDIA570.144/kernel-open/nvidia-drm/nvidia-drm-drv.c
// /*
//  * Copyright (c) 2015-2022, NVIDIA CORPORATION. All rights reserved.
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
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
//! Native storage geometry. RM owns physical placement and page kinds; this
//! owner retains byte pitches and padded plane extents for engine consumers.
//! Memory eligibility never advertises a rendering or modesetting backend.
const std = @import("std");
const a = @import("r4os").abi;
const memory_caps = @import("gsp_memory_caps.zig");
const vaspace = @import("gsp_vaspace.zig");
pub const Error = error{ Bounds, Unsupported, Stale, Descriptor };
pub const alignment: u64 = 65536;
pub const Format = enum(u32) { xrgb8888 = 0x34325258, argb8888 = 0x34325241, r8 = 0x20203852, nv12 = 0x3231564e, p010 = 0x30313050 };
pub const Layout = enum { linear, blocklinear };
pub const Request = struct {
    width: u32,
    height: u32,
    format: Format = .xrgb8888,
    usage: u32 = 12, // Transfer source/target. No CPU mapping of native VRAM.
    layout: Layout = .linear,
    block_height: ?u8 = null, // log2(GOBs), auto-selected only for blocklinear.
};
pub const Plan = struct {
    descriptor: a.GfxBufferDescriptor,
    allocation_bytes: u64,
    request: ?Request = null,
    caps: ?memory_caps.Info = null,
    log2_gobs: u8 = 0,
    plane_bytes: [4]u64 = @splat(0),
    padded_rows: [4]u64 = @splat(0),

    pub fn blocklinear(self: Plan) bool { return self.descriptor.modifier != 0; }
    pub fn scanout(self: Plan) bool { return self.descriptor.usage & 32 != 0; }
    pub fn validate(self: Plan, adapter: u32, space: vaspace.Info) Error!void {
        const expected = if (self.request) |request| try create(adapter, space, self.caps orelse return error.Descriptor, request)
            else try raw(adapter, space, self.descriptor.byte_length);
        if (!std.meta.eql(self, expected)) return error.Descriptor;
    }
};
fn alignUp(value: u64, granule: u64) Error!u64 {
    return (std.math.add(u64, value, granule - 1) catch return error.Bounds) & ~(granule - 1);
}
pub fn raw(adapter: u32, space: vaspace.Info, bytes: u64) Error!Plan {
    if (adapter == 0 or space.epoch == 0) return error.Stale;
    if (bytes == 0) return error.Bounds;
    const rounded = try alignUp(bytes, alignment);
    if (rounded > space.bytes) return error.Bounds;
    return .{ .descriptor = .{ .byte_length = bytes, .alignment = alignment, .usage = 12,
        .location = a.gfx_buffer_location_device_local, .adapter_id = adapter, .device_generation = space.epoch }, .allocation_bytes = rounded };
}
// Pinned NVKMS headsurface policy, evaluated with checked/widened arithmetic.
pub fn automaticBlockHeight(height: u32) u8 {
    var log2: u8 = 4;
    const limit = @as(u64, height) + height / 2;
    while (log2 > 0 and (@as(u64, 8) << @intCast(log2)) > limit) log2 -= 1;
    if (log2 > 0) {
        var proposed = @as(u32, 8) << @intCast(log2 - 1);
        while (proposed >= height) {
            log2 -= 1;
            if (log2 == 0) break;
            proposed /= 2;
        }
    }
    return log2;
}
pub fn modifier(caps: memory_caps.Info, log2: u8) Error!u64 {
    if (!caps.blocklinear() or caps.gobBytes() != 512 or log2 > 5) return error.Unsupported;
    const kind: u64 = caps.genericPageKind();
    const generation: u64 = if (kind == 6) 2 else 0;
    return (@as(u64, 3) << 56) | 0x10 | log2 | (kind << 12) | (generation << 20) | (1 << 22);
}
pub fn create(adapter: u32, space: vaspace.Info, caps: memory_caps.Info, request: Request) Error!Plan {
    if (adapter == 0 or space.epoch == 0 or caps.binding.epoch != space.epoch or
        caps.binding.client != space.client or caps.binding.device != space.device) return error.Stale;
    if (request.width == 0 or request.height == 0 or request.usage == 0 or request.usage & ~@as(u32, 60) != 0) return error.Descriptor;
    const multi = request.format == .nv12 or request.format == .p010;
    // NVKMS ISO surfaces require complete chroma blocks; offscreen buffers
    // retain ceil-sized chroma planes for odd image dimensions.
    if (request.usage & 32 != 0 and ((multi and (request.width & 1 != 0 or request.height & 1 != 0)) or request.format == .r8)) return error.Unsupported;
    if (request.layout == .linear and request.block_height != null) return error.Descriptor;
    const chroma_rows = (@as(u64, request.height) + 1) / 2;
    const log2 = if (request.layout == .blocklinear) request.block_height orelse automaticBlockHeight(@intCast(if (multi) chroma_rows else request.height)) else 0;
    const mod = if (request.layout == .blocklinear) try modifier(caps, log2) else 0;
    var plan: Plan = .{ .descriptor = .{ .alignment = alignment, .modifier = mod, .width = request.width, .height = request.height,
        .format = @intFromEnum(request.format), .plane_count = if (multi) 2 else 1, .usage = request.usage,
        .location = a.gfx_buffer_location_device_local, .adapter_id = adapter, .device_generation = space.epoch },
        .allocation_bytes = 0, .request = request, .caps = caps, .log2_gobs = log2 };
    const sample_bytes: u64 = switch (request.format) { .xrgb8888, .argb8888 => 4, .p010 => 2, else => 1 };
    var end: u64 = 0;
    for (0..plan.descriptor.plane_count) |index| {
        const columns = if (multi and index == 1) ((@as(u64, request.width) + 1) / 2) * 2 else request.width;
        const rows = if (multi and index == 1) chroma_rows else request.height;
        const pitch = try alignUp(std.math.mul(u64, columns, sample_bytes) catch return error.Bounds, if (mod == 0) 256 else 64);
        const padded_rows = try alignUp(rows, if (mod == 0) 1 else @as(u64, 8) << @intCast(log2));
        // Hardware consumers encode dimensions/pitch in 32-bit fields.
        if (pitch > std.math.maxInt(u32) or padded_rows > std.math.maxInt(u32)) return error.Bounds;
        const size = std.math.mul(u64, pitch, padded_rows) catch return error.Bounds;
        const offset = try alignUp(end, alignment);
        plan.descriptor.plane_offsets[index] = offset;
        plan.descriptor.plane_pitches[index] = pitch;
        plan.plane_bytes[index] = size;
        plan.padded_rows[index] = padded_rows;
        end = std.math.add(u64, offset, size) catch return error.Bounds;
    }
    plan.allocation_bytes = try alignUp(end, alignment);
    if (plan.allocation_bytes > space.bytes) return error.Bounds;
    plan.descriptor.byte_length = plan.allocation_bytes;
    return plan;
}
