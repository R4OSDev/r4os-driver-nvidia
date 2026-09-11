//! CPU preparation of the pinned GA106 first-boot Libos/RM/log/message areas.
//! The caller retains every supplied DMA span and synchronizes the resulting
//! image before use. This encoder neither owns DMA nor submits or links queues.
//! Status-queue metadata remains zero: only GSP may initialize its producer.
// Layout and initial field assignments from NVIDIA 570.144 libos_init_args.h,
// gsp_init_args.h, kernel_gsp.c, message_queue_cpu.c and msgq.c/msgq_priv.h.
// Original R4OS admission and interfaces: Apache-2.0. NVIDIA portions: MIT.
// Copyright (c) 2018-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2020-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2019-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2019-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2018-2019 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
const radix = @import("gsp_radix.zig");
pub const Span = radix.Segment;
pub const page_bytes = 4096;
pub const log_bytes = 65536;
pub const log_count = 5;
pub const log_names = [_][]const u8{ "LOGINIT", "LOGINTR", "LOGRM", "LOGMNOC", "LOGKRNL" };
pub const queue_bytes = 262144;
pub const queue_pages = 129; // Includes the page table's own first page.
pub const queue_allocation_bytes = queue_pages * page_bytes;
pub const command_offset = page_bytes;
pub const status_offset = command_offset + queue_bytes;
pub const ring_slots = (queue_bytes - page_bytes) / page_bytes;
pub const ring_capacity = ring_slots - 1;
pub const libos_entry_bytes = 32;
pub const rm_argument_bytes = 72;
pub const libos_offset = 0;
pub const rm_offset = page_bytes;
pub const logs_offset = rm_offset + page_bytes;
pub const queues_offset = logs_offset + log_count * log_bytes;
pub const output_bytes = queues_offset + queue_allocation_bytes;
pub const max_excluded = 258; // GSP's 256 spans, boot pack and FWSEC image.
pub const Error = error{ Profile, Size, Address, Alignment, Overlap, Segments };

comptime {
    if (!std.mem.eql(u8, firmware.lock.rm_version, "570.144") or
        !std.mem.eql(u8, firmware.lock.source_commit, "8ec351aeb96a93a4bb69ccc12a542bf8a8df2b6f"))
        @compileError("GSP initialization structures require a new original-source ABI comparison");
}

pub const Bindings = struct {
    chip_id: u16,
    // A complete page for each argument block and contiguous release-sized logs.
    libos: Span,
    rm: Span,
    logs: [log_count]Span,
    // Logical order, complete shared queue backing, possibly discontiguous.
    queues: []const Span,
    // Other retained boot allocations. No address from an earlier closed probe.
    excluded: []const Span = &.{},
};
pub const Report = struct {
    libos_address: u64,
    rm_address: u64,
    queues_address: u64,
    queue_page_count: usize = queue_pages,
    log_regions: usize = log_count,
};
const Prepared = struct {
    report: Report,
    pages: [queue_pages]u64,
    log_addresses: [log_count]u64,
};

pub fn id8(name: []const u8) u64 {
    std.debug.assert(name.len <= 8);
    var result: u64 = 0;
    for (name) |c| result = (result << 8) | c;
    return result;
}
fn valid(span: Span) Error!void {
    if (span.address == 0 or span.bytes == 0 or span.address > radix.dma_mask or
        span.bytes - 1 > radix.dma_mask - span.address) return error.Address;
    if ((span.address | span.bytes) & (page_bytes - 1) != 0) return error.Alignment;
}
fn overlap(a: Span, b: Span) bool {
    return a.address < b.address + b.bytes and b.address < a.address + a.bytes;
}
fn prepare(input: *const Bindings) Error!Prepared {
    if (input.chip_id != 0x176) return error.Profile;
    if (input.queues.len == 0 or input.queues.len > queue_pages or input.excluded.len > max_excluded) return error.Segments;
    const fixed = [_]Span{ input.libos, input.rm } ++ input.logs;
    for (fixed, 0..) |span, index| {
        const expected_bytes: u64 = if (index < 2) page_bytes else log_bytes;
        if (span.bytes != expected_bytes) return error.Size;
        try valid(span);
        for (fixed[0..index]) |previous| if (overlap(previous, span)) return error.Overlap;
    }
    for (input.excluded) |span| try valid(span);
    for (fixed) |span| for (input.excluded) |excluded| {
        if (overlap(span, excluded)) return error.Overlap;
    };
    var prepared: Prepared = .{
        .report = .{ .libos_address = input.libos.address, .rm_address = input.rm.address, .queues_address = input.queues[0].address },
        .pages = undefined,
        .log_addresses = undefined,
    };
    var used: usize = 0;
    for (input.queues, 0..) |span, index| {
        try valid(span);
        if (span.bytes / page_bytes > queue_pages - used) return error.Size;
        for (fixed) |other| if (overlap(span, other)) return error.Overlap;
        for (input.excluded) |other| if (overlap(span, other)) return error.Overlap;
        for (input.queues[0..index]) |other| if (overlap(span, other)) return error.Overlap;
        for (0..span.bytes / page_bytes) |page| {
            prepared.pages[used] = span.address + page * page_bytes;
            used += 1;
        }
    }
    if (used != queue_pages) return error.Size;
    for (input.logs, 0..) |span, index| prepared.log_addresses[index] = span.address;
    return prepared;
}
fn put64(output: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, output[offset..][0..8], value, .little);
}
fn put32(output: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, output[offset..][0..4], value, .little);
}
fn region(output: []u8, index: usize, name: []const u8, address: u64, bytes: u64) void {
    const offset = libos_offset + index * libos_entry_bytes;
    put64(output, offset, id8(name));
    put64(output, offset + 8, address);
    put64(output, offset + 16, bytes);
    output[offset + 24] = 1; // CONTIGUOUS
    output[offset + 25] = 1; // SYSMEM
}

/// Validate every input before the first output write. All values needed during
/// encoding are copied into the small local plan, so caller metadata may reside
/// within output without becoming a read-after-zero source. No allocation/I/O.
pub fn encode(input: *const Bindings, output: []u8) Error!Report {
    if (output.len != output_bytes) return error.Size;
    const prepared = try prepare(input);
    @memset(output, 0);
    for (prepared.log_addresses, 0..) |address, index| {
        region(output, index, log_names[index], address, log_bytes);
        // Put pointer remains zero. The 16 physical page addresses follow it.
        for (0..log_bytes / page_bytes) |page| put64(output, logs_offset + index * log_bytes + 8 + page * 8, address + page * page_bytes);
    }
    region(output, log_count, "RMARGS", prepared.report.rm_address, page_bytes);
    put64(output, rm_offset, prepared.report.queues_address);
    put32(output, rm_offset + 8, queue_pages);
    put64(output, rm_offset + 16, command_offset);
    put64(output, rm_offset + 24, status_offset);
    // Normal first boot: no PM transition, gpuInstance 0, no profiler. Original
    // production default uses DMEM for the stack; this is not a clock override.
    output[rm_offset + 48] = 1;
    for (prepared.pages, 0..) |address, index| put64(output, queues_offset + index * 8, address);
    const header = queues_offset + command_offset;
    put32(output, header + 4, queue_bytes);
    put32(output, header + 8, page_bytes);
    put32(output, header + 12, ring_slots);
    put32(output, header + 20, 1); // MSGQ_FLAGS_SWAP_RX requested, not negotiated.
    put32(output, header + 24, 32);
    put32(output, header + 28, page_bytes);
    return prepared.report;
}
