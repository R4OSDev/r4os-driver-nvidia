// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2010-2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Private C5 identity conversion, not a programmable public colour LUT.
//! Complete padded bytes are checked against original NVIDIA570.144 C and
//! SoftFloat; the device worker publishes them only after CE readback.
const std = @import("std");
pub const bytes: usize = 0x4200;
pub const allocation_bytes: u64 = 65536;
pub const output_offset: u32 = 0x2100;
pub const entries: u32 = 1029;
pub const ilut_control: u32 = (entries << 8) | 8;
pub const olut_control: u32 = ilut_control | 1;
pub const Controls = struct {
    head: u32, window: u32, input: u32, output: u32,
    pub fn validate(self: Controls) error{Descriptor}!void {
        if (self.head >= 8 or self.window >= 8 or self.input == 0 or
            self.output == 0 or self.input == self.output) return error.Descriptor;
    }
};
fn half(index: u16) u16 {
    if (index == 0) return 0;
    // i/1024 is exactly representable: no host FPU or rounded float UVs.
    const exponent: u16 = 15 - @clz(index);
    const leading = @as(u16, 1) << @as(u4, @intCast(exponent));
    return ((exponent + 5) << 10) |
        ((index - leading) << @as(u4, @intCast(10 - exponent)));
}
pub fn byteAt(index: usize) u8 {
    if (index >= bytes) return 0;
    const output = index >= output_offset;
    const local = if (output) index - output_offset else index;
    const slot = local / 8;
    const lane = local % 8;
    if (slot < 4 or slot >= entries or lane >= 6) return 0;
    const sample: u16 = @intCast(@min(slot - 4, @as(usize, 1023)));
    const value: u16 = if (output) sample << 6 else half(sample);
    return @truncate(value >> @as(u4, @intCast((lane & 1) * 8)));
}
pub fn fill(out: []u8) error{Bounds}!void {
    if (out.len < bytes) return error.Bounds;
    @memset(out, 0);
    for (out[0..bytes], 0..) |*value, i| value.* = byteAt(i);
}
pub fn firstDifference(actual: []const u8) error{Bounds}!?u32 {
    if (actual.len != bytes) return error.Bounds;
    for (actual, 0..) |value, i| if (value != byteAt(i)) return @intCast(i);
    return null;
}
