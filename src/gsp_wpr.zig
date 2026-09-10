//! CPU-only first-boot WPR metadata, pinned to RM 570.144. The unbound template
//! is NOT a bootable descriptor. Encoding actual addresses neither grants VRAM
//! ownership nor proves DMA lifetime, synchronization or GPU authentication.
//! Callers must retain every mapping, reserve VRAM, establish VGA recovery and
//! synchronize the completed metadata before any eventual GPU submission.
// Format/field assignment from gsp_fw_wpr_meta.h and kernel_gsp_tu102.c.
// Original R4OS validation and interfaces: Apache-2.0. NVIDIA portions: MIT.
// Copyright (c) 2021-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2017-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
const std = @import("std");
const firmware = @import("firmware.zig");
const boot = @import("gsp_boot.zig");
const layout = @import("gsp_layout.zig");
const radix = @import("gsp_radix.zig");
const preflight = @import("fwsec_state.zig");
pub const bytes = 256;
pub const magic: u64 = 0xdc3aae21371a60b3;
pub const revision: u64 = 1;
pub const image_bytes = 63541248;
pub const signature_bytes = 4096;
pub const Error = boot.Error || layout.Error || radix.Error || error{ SignatureSize, CrashQueueSize };
pub const Input = struct {
    chip_id: u16,
    raw: preflight.Raw,
    image_bytes: usize,
    descriptor: []const u8,
    signature_bytes: usize,
};
pub const Prepared = struct {
    plan: layout.Plan,
    boot_info: boot.Info,
    unbound_template: [bytes]u8,
};
pub const Bindings = struct {
    // Complete retained GSP backing, including all three radix levels.
    // The first logical page supplies the root; physical order may differ.
    gsp_segments: []const radix.Segment,
    // Boot image and signature must each be one contiguous device span.
    boot_image: radix.Segment,
    signature: radix.Segment,
    // Optional contiguous queue. This encoder does not initialize its ABI.
    crash_queue: ?radix.Segment = null,
};

fn put(output: *[bytes]u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, output[offset..][0..8], value, .little);
}

/// Caller has already admitted the immutable GA10X firmware and boot image.
/// The small descriptor is re-admitted here; arbitrary Info or Plan structs
/// cannot smuggle unvalidated offsets into the metadata. This is the exact
/// bare-metal GA106 first-boot profile, without recovery, vGPU or clock boost.
pub fn prepare(input: *const Input) Error!Prepared {
    if (input.image_bytes != image_bytes) return error.ImageSize;
    if (input.signature_bytes != signature_bytes) return error.SignatureSize;
    if (input.descriptor.len != boot.descriptor.bytes) return error.WrongSize;
    if (!firmware.digestMatches(input.descriptor, boot.descriptor.sha256)) return error.WrongHash;
    const info = try boot.inspect(input.descriptor, boot.image.bytes);
    const plan = try layout.firstBoot(input.chip_id, &input.raw, input.image_bytes, info.image_bytes);
    var output: [bytes]u8 = @splat(0);
    const fields = [_]u64{
        magic,                    revision,                 0,                    input.image_bytes, 0,                     info.image_bytes,
        info.monitor_code.offset, info.monitor_data.offset, info.manifest.offset, 0,                 input.signature_bytes, plan.reserved.offset,
        plan.non_wpr_heap.offset, plan.non_wpr_heap.bytes,  plan.wpr.offset,      plan.heap.offset,  plan.heap.bytes,       plan.firmware.offset,
        plan.boot.offset,         plan.frts.offset,         plan.frts.bytes,      plan.wpr.end(),    plan.fb_bytes,         plan.vga.offset,
        plan.vga.bytes,
    };
    for (fields, 0..) |value, index| put(&output, index * 8, value);
    // bootCount, the partition/crash union, VF count, flags, PMU reservation and
    // verified remain zero. Only the Booter may write the verified marker.
    return .{ .plan = plan, .boot_info = info, .unbound_template = output };
}

fn span(segment: radix.Segment) Error!void {
    if (segment.address == 0 or segment.address > radix.dma_mask or segment.bytes == 0 or
        segment.bytes - 1 > radix.dma_mask - segment.address) return error.Address;
    if ((segment.address | segment.bytes) & (radix.page_bytes - 1) != 0) return error.Alignment;
}
fn overlaps(a: radix.Segment, b: radix.Segment) bool {
    // Both complete spans have passed the 49-bit check above.
    return a.address < b.address + b.bytes and b.address < a.address + a.bytes;
}

/// Returns one complete little-endian descriptor by value. On failure there
/// is no partial caller output. All claimed device spans must be disjoint,
/// including the firmware's scattered data pages, not merely the root page.
pub fn encode(input: *const Input, bindings: *const Bindings) Error![bytes]u8 {
    const prepared = try prepare(input);
    const need = try radix.requirements(input.image_bytes);
    const segments = bindings.gsp_segments;
    if (segments.len == 0 or segments.len > radix.max_segments) return error.Segments;
    var covered: u64 = 0;
    for (segments, 0..) |segment, index| {
        try span(segment);
        if (segment.bytes > need.allocation_bytes - covered) return error.Capacity;
        covered += segment.bytes;
        for (segments[0..index]) |previous| if (overlaps(segment, previous)) return error.Overlap;
    }
    if (covered != need.allocation_bytes) return error.Capacity;
    try span(bindings.boot_image);
    try span(bindings.signature);
    if (bindings.boot_image.bytes != prepared.boot_info.image_bytes) return error.WrongSize;
    if (bindings.signature.bytes != signature_bytes) return error.SignatureSize;
    var extra: [3]radix.Segment = undefined;
    extra[0] = bindings.boot_image;
    extra[1] = bindings.signature;
    var count: usize = 2;
    if (bindings.crash_queue) |queue| {
        try span(queue);
        if (queue.bytes > std.math.maxInt(u32)) return error.CrashQueueSize;
        extra[2] = queue;
        count = 3;
    }
    for (extra[0..count], 0..) |segment, index| {
        for (extra[0..index]) |previous| if (overlaps(segment, previous)) return error.Overlap;
        for (segments) |previous| if (overlaps(segment, previous)) return error.Overlap;
    }
    var output = prepared.unbound_template;
    put(&output, 16, segments[0].address);
    put(&output, 32, bindings.boot_image.address);
    put(&output, 72, bindings.signature.address);
    if (bindings.crash_queue) |queue| {
        put(&output, 224, queue.address);
        std.mem.writeInt(u32, output[232..236], @intCast(queue.bytes), .little);
    }
    return output;
}
