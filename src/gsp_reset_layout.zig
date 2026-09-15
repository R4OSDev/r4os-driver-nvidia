//! GA106 XVE configuration map, NVIDIA570.144 GA102 HAL, unchanged bits.
//! Original: published/ampere/ga102/dev_nv_pcfg_xve_regmap.h.
//! Pin:8ec351aeb96a93a4bb69ccc12a542bf8a8df2b6f.
// 
// SPDX-FileCopyrightText: Copyright (c) 2003-2023 NVIDIA CORPORATION & AFFILIATES
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
// 
pub const valid = [_]u32{
    0xfff1ffff, 0x101fff9f, 0x3ffa3c7f, 0x00000000,
    0x03f00000, 0x00000000, 0x00000000, 0x00000000,
    0x8007ffc0, 0x3f3f5807, 0x000000bf, 0x00000000,
    0x0140aa1f, 0x00000000, 0x00013fff, 0x00000000,
    0xffefdfd7, 0x1edaffff, 0xffffffff, 0x002fffff,
    0xff7fffff, 0x0007ffff, 0x00000000, 0xfffff000,
    0x0007bfe7, 0xffc003fc, 0xffffffff, 0x7c1f3fff,
    0xffffffff, 0x00ffffff, 0x00000000, 0xfe000000,
};
pub const writable = [_]u32{
    0x3ef193fa, 0x1007c505, 0x3ffa0828, 0x00000000,
    0x03200000, 0x00000000, 0x00000000, 0x00000000,
    0x80007ec0, 0x3f075007, 0x000000bf, 0x00000000,
    0x0140aa10, 0x00000000, 0x00013fff, 0x00000000,
    0x004c5fc3, 0x1c5affc0, 0xfffc7804, 0x002fffff,
    0xff7ffdfd, 0x00007fff, 0x00000000, 0xf8a54000,
    0x00003c01, 0x3fc003fc, 0xfffffffc, 0x701b2c3f,
    0xfffffff8, 0x00ffbfff, 0x00000000, 0xfe000000,
};
pub fn contains(map: *const [32]u32, offset: u16) bool {
    if (offset >= 4096 or offset & 3 != 0) return false;
    return map[offset / 128] & (@as(u32, 1) << @as(u5, @intCast((offset / 4) % 32))) != 0;
}
