// C67D cursor control fields (MIT); R4OS image/owner policy: Apache-2.0.
// ExFiles/Reference/GFX/Nvidia/OpenKernelModules-570.144/src/common/sdk/nvidia/inc/class/clc67d.h
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
//! Packed straight-alpha ARGB cursor images and typed C67D control state.
//! Source pixels keep their original alpha; padding is transparent black.
const std = @import("std");
pub const Error = error{ Bounds, Descriptor };
pub const max_size: u16 = 256;
pub const max_bytes: u64 = @as(u64, max_size) * max_size * 4;
pub const Plan = struct {
    width: u16, height: u16, hotspot_x: u16, hotspot_y: u16,
    size: u16, pitch: u64, source_bytes: u64,
    pub fn bytes(self: Plan) u64 { return @as(u64, self.size) * self.size * 4; }
    pub fn valid(self: Plan) bool {
        const expected = make(self.width, self.height, self.hotspot_x, self.hotspot_y, self.pitch, self.source_bytes) catch return false;
        return std.meta.eql(expected, self);
    }
};
pub fn sizeCode(size: u16) Error!u32 { return switch (size) { 32 => 0, 64 => 1, 128 => 2, 256 => 3, else => error.Bounds }; }
pub fn usageCode(size: u16) Error!u32 { return if (size == 0) 0 else (try sizeCode(size)) + 1; }
pub fn make(width: u32, height: u32, hotspot_x: u32, hotspot_y: u32, pitch: u64, source_bytes: u64) Error!Plan {
    if (width == 0 or height == 0 or width > max_size or height > max_size or hotspot_x >= width or hotspot_y >= height or
        pitch & 3 != 0 or pitch < @as(u64, width) * 4 or pitch > std.math.maxInt(u64) / @as(u64, height) or pitch * height > source_bytes) return error.Bounds;
    var size: u16 = 32;
    while (size < @max(width, height)) size *= 2;
    return .{ .width = @intCast(width), .height = @intCast(height), .hotspot_x = @intCast(hotspot_x), .hotspot_y = @intCast(hotspot_y),
        .size = size, .pitch = pitch, .source_bytes = source_bytes };
}
/// A bounded sequential image part, including transparent power-of-two
/// padding. No bytes outside the caller's confirmed CPU map are read.
pub fn pack(plan: Plan, source: []const u8, offset: u64, output: []u8) Error!void {
    if (!plan.valid() or source.len != plan.source_bytes or offset & 3 != 0 or output.len == 0 or output.len & 3 != 0 or
        offset > plan.bytes() or output.len > plan.bytes() - offset) return error.Bounds;
    @memset(output, 0);
    for (0..output.len / 4) |i| {
        const pixel = offset / 4 + i;
        const x = pixel % plan.size; const y = pixel / plan.size;
        if (x >= plan.width or y >= plan.height) continue;
        const at = y * plan.pitch + x * 4;
        @memcpy(output[i * 4..][0..4], source[@intCast(at)..][0..4]);
    }
}
pub const Control = struct {
    head: u32,
    dma: u32 = 0,
    offset: u64 = 0,
    storage_bytes: u64 = 0,
    size: u16 = 0,
    hotspot_x: u16 = 0,
    hotspot_y: u16 = 0,
    visible: bool = false,
    pub fn validate(self: Control) Error!void {
        if (self.head >= 8) return error.Bounds;
        if (!self.visible) {
            if (self.dma != 0 or self.offset != 0 or self.storage_bytes != 0 or self.size != 0 or self.hotspot_x != 0 or self.hotspot_y != 0) return error.Descriptor;
            return;
        }
        _ = try sizeCode(self.size);
        if (self.dma == 0 or self.hotspot_x >= self.size or self.hotspot_y >= self.size or self.offset & 255 != 0 or
            self.offset >> 8 > std.math.maxInt(u32) or self.offset >= self.storage_bytes or
            @as(u64, self.size) * self.size * 4 > self.storage_bytes - self.offset) return error.Bounds;
    }
    pub fn word(self: Control) Error!u32 {
        try self.validate();
        if (!self.visible) return 0xcf;
        return 0x800000cf | ((try sizeCode(self.size)) << 8) | (@as(u32, self.hotspot_x) << 12) | (@as(u32, self.hotspot_y) << 20);
    }
};
