//! CPU-only GA106 first-boot layout, following the centrally pinned RM 570.144.
//! No VRAM ownership, allocation, DMA address or permission to execute follows
//! from a plan. Runtime use also requires a fresh observation and display recovery.
// Layout/heap calculations adapted from kernel_gsp_tu102.c, kernel_gsp.c and
// gsp_fw_heap.h. Original R4OS admission checks and interfaces: Apache-2.0.
// The NVIDIA portions retain their original MIT terms:
// Copyright (c) 2017-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2019-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2022-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
const preflight = @import("fwsec_state.zig");
pub const Error = preflight.Error || error{ UnsupportedChip, WprActive, EngineState, ImageSize, Bounds, PrescrubbedCapacity };
pub const mb: u64 = 1024 * 1024;
pub const metadata_bytes: u64 = 256;
pub const prescrubbed_bytes: u64 = 256 * mb;
pub const min_heap_bytes: u64 = 88 * mb;
pub const Range = struct {
    offset: u64,
    bytes: u64,
    pub fn end(self: Range) u64 {
        return self.offset + self.bytes;
    }
};
pub const Plan = struct {
    fb_bytes: u64,
    current_vga_base: ?u64,
    vga_relocation_required: bool,
    vga: Range,
    prescrubbed: Range,
    reserved: Range,
    wpr: Range,
    non_wpr_heap: Range,
    metadata_reservation: Range,
    heap: Range,
    heap_limit_bytes: u64,
    firmware: Range,
    boot: Range,
    frts: Range,
};

fn subtract(a: u64, b: u64) Error!u64 {
    return std.math.sub(u64, a, b) catch error.Bounds;
}
fn up(value: u64, alignment: u64) Error!u64 {
    return (std.math.add(u64, value, alignment - 1) catch return error.Bounds) & ~(alignment - 1);
}
fn down(value: u64, alignment: u64) u64 {
    return value & ~(alignment - 1);
}

/// Default bare-metal first boot: no heap override, recovery margin, boost
/// clocks, vGPU or GA100 MMU-lock region. Sizes refer to admitted .fwimage and
/// decoded GSP boot bytes, not to the GSP container or compressed bindata.
/// WPR from an earlier boot must not be reused through this entry point.
pub fn firstBoot(chip_id: u16, raw: *const preflight.Raw, image_bytes: u64, boot_bytes: u64) Error!Plan {
    _ = boot.source_path; // Enforce the common pin's ABI review at compile time.
    if (chip_id != 0x176) return error.UnsupportedChip;
    if (raw.present & ~@as(u16, (1 << preflight.addresses.len) - 1) != 0) return error.MissingRegister;
    const state = try preflight.decode(raw);
    if (state.wpr_up) return error.WprActive;
    if (state.reset_asserted or state.scrubbing or !state.falcon_halted or !state.dma_idle or state.dma_full or
        !state.riscv_enabled or state.riscv_selected or state.riscv_active or !state.riscv_halted or !state.bcr_valid)
        return error.EngineState;
    if (image_bytes == 0 or image_bytes > firmware.max_bytes or boot_bytes == 0 or boot_bytes > mb) return error.ImageSize;
    const fb = state.fb_bytes;
    if (fb < prescrubbed_bytes) return error.PrescrubbedCapacity;
    const vga_base = if (!state.vga_valid) fb - mb else if (state.vga_relocation_needed) fb - 0x20000 else state.vga_base;
    // kgspGetWprEndMargin: zero only for the normal first boot with no override.
    const wpr_end = down(vga_base, 0x20000);
    const frts_start = try subtract(wpr_end, mb);
    const boot_start = down(try subtract(frts_start, boot_bytes), 0x1000);
    const image_start = down(try subtract(boot_start, image_bytes), 0x10000);
    const metadata_reservation = try up(metadata_bytes, mb);
    const anterior = metadata_reservation + mb; // Plus the non-WPR heap.
    const posterior = try up(fb - image_start, mb);
    // GA106 has no separate scrubber ucode; everything needed for boot must
    // fit in the top 256 MB. Reject underflow or less than the minimum heap.
    if (anterior + posterior > prescrubbed_bytes) return error.PrescrubbedCapacity;
    const heap_limit = down(prescrubbed_bytes - anterior - posterior, mb);
    if (heap_limit < min_heap_bytes) return error.PrescrubbedCapacity;
    const fb_gb = (try up(fb, 1 << 30)) >> 30;
    const calculated_heap = 22 * mb + 8 * mb + (try up(96 * 1024 * fb_gb, mb)) + 96 * mb;
    const requested_heap = @min(@max(calculated_heap, min_heap_bytes), heap_limit);
    const heap_start = down(try subtract(image_start, requested_heap), mb);
    const wpr_start = try subtract(heap_start, metadata_reservation);
    const non_wpr_start = try subtract(wpr_start, mb);
    if (non_wpr_start < fb - prescrubbed_bytes) return error.PrescrubbedCapacity;
    return .{
        .fb_bytes = fb,
        .current_vga_base = if (state.vga_valid) state.vga_base else null,
        .vga_relocation_required = state.vga_relocation_needed,
        .vga = .{ .offset = vga_base, .bytes = fb - vga_base },
        .prescrubbed = .{ .offset = fb - prescrubbed_bytes, .bytes = prescrubbed_bytes },
        .reserved = .{ .offset = non_wpr_start, .bytes = fb - non_wpr_start },
        .wpr = .{ .offset = wpr_start, .bytes = wpr_end - wpr_start },
        .non_wpr_heap = .{ .offset = non_wpr_start, .bytes = mb },
        .metadata_reservation = .{ .offset = wpr_start, .bytes = metadata_reservation },
        .heap = .{ .offset = heap_start, .bytes = down(image_start - heap_start, mb) },
        .heap_limit_bytes = heap_limit,
        .firmware = .{ .offset = image_start, .bytes = image_bytes },
        .boot = .{ .offset = boot_start, .bytes = boot_bytes },
        .frts = .{ .offset = frts_start, .bytes = mb },
    };
}
