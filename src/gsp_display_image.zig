// Derived display protocol portions: MIT, original sources/notices below.
//
// Original/Nvidia570144/src/common/sdk/nvidia/inc/class/clc67e.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2020 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! A retained physical display context plus its actual native surface plan.
//! The descriptor base supplies the allocation origin; methods use offsets
//! relative to that context, never a caller-provided GPU/physical address.
const std = @import("std");
const a = @import("r4os").abi;
const surface = @import("gsp_surface_layout.zig");
pub const Error = error{Bounds, Unsupported, Descriptor};
pub const Image = struct {
    dma: u32,
    channel: u32,
    width: u32,
    height: u32,
    pitch: u32,
    format: u32,
    bytes: u64,
    offset: u64,
};
pub fn create(plan: surface.Plan, dma: u32, channel: u32) Error!Image {
    const d = plan.descriptor;
    if (plan.request == null or !plan.scanout() or plan.blocklinear() or d.location != a.gfx_buffer_location_device_local or
        d.plane_count != 1 or d.plane_pitches[0] > std.math.maxInt(u32)) return error.Unsupported;
    const result: Image = .{ .dma = dma, .channel = channel, .width = d.width, .height = d.height,
        .pitch = @intCast(d.plane_pitches[0]), .format = d.format, .bytes = d.byte_length, .offset = d.plane_offsets[0] };
    try validate(result); return result;
}
pub fn validate(value: Image) Error!void {
    if (value.dma == 0 or value.channel < 1 or value.channel > 8) return error.Descriptor;
    if (value.format != a.gfx_buffer_format_xrgb8888 and value.format != a.gfx_buffer_format_argb8888) return error.Unsupported;
    if (value.width == 0 or value.height == 0 or value.width > 0x7fff or value.height > 0xffff or
        value.pitch & 63 != 0 or value.pitch / 64 > 0x1fff or value.pitch < @as(u64, value.width) * 4 or
        value.offset & 255 != 0 or value.offset >> 8 > std.math.maxInt(u32) or value.offset >= value.bytes or
        @as(u64, value.pitch) * value.height > value.bytes - value.offset) return error.Bounds;
}
