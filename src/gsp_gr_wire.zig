// ExFiles/Reference/GFX/Nvidia/OpenKernelModules-570.144/src/common/sdk/nvidia/inc/class/clc797.h
// /*******************************************************************************
//     Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.
// 
//     Permission is hereby granted, free of charge, to any person obtaining a
//     copy of this software and associated documentation files (the "Software"),
//     to deal in the Software without restriction, including without limitation
//     the rights to use, copy, modify, merge, publish, distribute, sublicense,
//     and/or sell copies of the Software, and to permit persons to whom the
//     Software is furnished to do so, subject to the following conditions:
// 
//     The above copyright notice and this permission notice shall be included in
//     all copies or substantial portions of the Software.
// 
//     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//     IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//     FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//     THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//     LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//     FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//     DEALINGS IN THE SOFTWARE.
// 
// *******************************************************************************/
// NVIDIA 570.144 class/clc797.h
// /*******************************************************************************
//     Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.
// 
//     Permission is hereby granted, free of charge, to any person obtaining a
//     copy of this software and associated documentation files (the "Software"),
//     to deal in the Software without restriction, including without limitation
//     the rights to use, copy, modify, merge, publish, distribute, sublicense,
//     and/or sell copies of the Software, and to permit persons to whom the
//     Software is furnished to do so, subject to the following conditions:
// 
//     The above copyright notice and this permission notice shall be included in
//     all copies or substantial portions of the Software.
// 
//     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//     IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//     FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//     THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//     LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//     FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//     DEALINGS IN THE SOFTWARE.
// 
// *******************************************************************************/
//! C797 graphics commands owned by the driver, never raw application words.
//! Header constants: pinned NVIDIA 570.144 clc797.h and clc56f.h.
pub const class: u32 = 0xc797;
pub const render = @import("r4nv_render");
pub const Error = render.Error || error{Busy};
pub const Command = union(enum) { barrier, draw: render.Binding };
pub const Program = struct {
    data: [render.max_words + 11]u32 = undefined,
    count: usize = 0,
    pub fn slice(self: *const Program) []const u32 { return self.data[0..self.count]; }
};
fn inc(method: u32, count: u32) u32 { return 0x20000000 | (count << 16) | (method >> 2); }
pub fn encode(object_class: u32, command: Command, completion: u64, point: u32) Error!Program {
    if (object_class != class) return error.Unsupported;
    if (completion == 0 or completion & 3 != 0 or completion > (@as(u64, 1) << 40) - 4 or point == 0) return error.Bounds;
    var out: Program = .{};
    switch (command) {
        .barrier => {},
        .draw => |binding| {
            var body: render.Program = .{};
            try render.encode(binding,&body);
            @memcpy(out.data[0..body.count],body.slice());
            out.count = body.count;
        },
    }
    // Wait includes preceding reads; the flushed, one-word release at ALL
    // includes writes. No render completion is inferred from USERD/GP_GET.
    const release = [_]u32{
        inc(0x0000, 1), class,
        inc(0x0110, 1), 0,
        inc(0x1144, 1), 0,
        inc(0x1b00, 4), @intCast(completion >> 32), @truncate(completion), point, 0x1000f010,
    };
    @memcpy(out.data[out.count..][0..release.len], &release);
    out.count += release.len;
    return out;
}
