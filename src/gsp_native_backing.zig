// NVIDIA570.144/src/common/sdk/nvidia/inc/nvos.h
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
// NVIDIA570.144/src/nvidia/src/kernel/mem_mgr/video_mem.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2020-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// NVIDIA570.144/src/nvidia/src/kernel/gpu/fifo/kernel_channel.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2020-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// NVIDIA570.144/src/nvidia/src/kernel/gpu/fifo/arch/volta/kernel_channel_group_gv100.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2021-2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Contiguous, initially cleared native control storage and its independent
//! common-BO use. Physical extents never come from an application address.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const caps = @import("gsp_memory_caps.zig");
const vaspace = @import("gsp_vaspace.zig");
pub const Error = error{ Stale, Bounds, Unsupported, Descriptor, Memory, Busy, Retained };
pub const Policy = struct {
    capabilities: caps.Info,
    physical_bytes: u64,
    pub fn validate(self: Policy, space: vaspace.Info, bytes: u64) Error!void {
        const binding = self.capabilities.binding;
        if (binding.epoch != space.epoch or binding.client != space.client or binding.device != space.device) return error.Stale;
        if (!self.capabilities.vidmemCleared()) return error.Unsupported;
        if (bytes == 0 or bytes > self.physical_bytes) return error.Bounds;
    }
};
pub const Physical = struct { base: u64, bytes: u64 };
pub const Source = struct {
    reference: a.GfxBufferReference,
    physical: Physical,
    address: u64,
    bytes: u64,
    epoch: u64,
    adapter: u32,
    driver_owner: u32,
};
pub const Use = struct {
    self_address: usize = 0,
    memory: ?r4os.driver_memory.Context = null,
    source: ?Source = null,
    source_stamp: ?Source = null,
    reference: a.GfxBufferReference = .{},
    reference_stamp: a.GfxBufferReference = .{},
    gpu: a.GfxDeviceLease = .{},
    gpu_stamp: a.GfxDeviceLease = .{},
    ready: bool = false,
    retained: bool = false,

    pub fn acquire(self: *Use, memory: r4os.driver_memory.Context, source: Source) Error!void {
        if (self.self_address != 0) return error.Busy;
        if (!valid(source.reference.buffer) or !valid(source.reference.reference) or source.reference.flags != 0 or
            source.bytes == 0 or source.bytes > source.physical.bytes or source.physical.base == 0 or source.address == 0 or
            source.physical.base > std.math.maxInt(u64) - source.physical.bytes or source.address > std.math.maxInt(u64) - source.bytes or
            source.epoch == 0 or source.adapter == 0 or source.driver_owner == 0) return error.Descriptor;
        self.self_address = @intFromPtr(self); self.memory = memory; self.source = source; self.source_stamp = source;
        self.acquireInner() catch |err| {
            if (err == error.Descriptor) { self.retained = true; return err; }
            if (!self.close(true)) return error.Retained;
            return err;
        };
    }
    fn acquireInner(self: *Use) Error!void {
        const source = self.source.?; const memory = self.memory.?;
        const imported = memory.bufferImport(&source.reference.reference, &self.reference);
        self.reference_stamp = self.reference;
        if (imported != a.gfx_buffer_result_ok and self.reference.reference.id == 0 and self.reference.buffer.id == 0) return error.Memory;
        const ref = self.reference;
        if (ref.version != 1 or ref.size < @sizeOf(a.GfxBufferReference) or ref.flags != 0 or ref.reserved0 != 0 or
            !valid(ref.reference) or std.meta.eql(ref.reference, source.reference.reference) or !std.meta.eql(ref.buffer, source.reference.buffer)) return error.Descriptor;
        if (imported != a.gfx_buffer_result_ok) return error.Memory;
        // Access1 is real device use and covers the logical byte extent.
        // Access3 would only retain page-aligned mapping residency, which
        // the native backing already owns independently of this consumer.
        const acquired = memory.deviceAcquire(&ref.reference, &.{ .byte_length = source.bytes, .gpu_virtual_address = source.address,
            .adapter_id = source.adapter, .device_generation = source.epoch, .access = 1, .address_space = 1 }, &self.gpu);
        self.gpu_stamp = self.gpu;
        if (acquired != a.gfx_buffer_result_ok and self.gpu.lease.id == 0) return error.Memory;
        const gpu = self.gpu;
        if (gpu.version != 1 or gpu.size < @sizeOf(a.GfxDeviceLease) or !valid(gpu.lease) or gpu.byte_offset != 0 or
            gpu.byte_length != source.bytes or gpu.gpu_virtual_address != source.address or gpu.device_generation != source.epoch or
            gpu.adapter_id != source.adapter or gpu.driver_owner != source.driver_owner or gpu.access != 1 or gpu.address_space != 1 or
            gpu.dma_mask != std.math.maxInt(u64)) return error.Descriptor;
        if (acquired != a.gfx_buffer_result_ok) return error.Memory;
        self.ready = true;
    }
    fn stable(self: *const Use) bool {
        return self.self_address == @intFromPtr(self) and self.memory != null and self.source != null and
            std.meta.eql(self.source, self.source_stamp) and std.meta.eql(self.reference, self.reference_stamp) and std.meta.eql(self.gpu, self.gpu_stamp);
    }
    pub fn info(self: *const Use) ?Source {
        if (!self.stable() or !self.ready or self.retained) return null;
        var result = self.source.?;
        result.reference = self.reference; // The producer reference may already be closed.
        return result;
    }
    // The concrete RM consumer, including a group-owned methods descriptor,
    // must be gone before quiesced=true. Dropping the producer is insufficient.
    pub fn close(self: *Use, quiesced: bool) bool {
        if (self.self_address == 0) return true;
        if (!self.stable() or self.retained or !quiesced) return false;
        self.ready = false;
        if (self.gpu.lease.id != 0) {
            if (self.memory.?.deviceRelease(&self.gpu, 1) != a.gfx_buffer_result_ok) return false;
            self.gpu = .{}; self.gpu_stamp = .{};
        }
        if (self.reference.reference.id != 0) {
            if (self.memory.?.bufferRelease(&self.reference.reference) != a.gfx_buffer_result_ok) return false;
            self.reference = .{}; self.reference_stamp = .{};
        }
        self.* = .{}; return true;
    }
};
fn valid(value: a.GfxBufferHandle) bool { return value.id != 0 and value.generation != 0 and value.reserved0 == 0; }
