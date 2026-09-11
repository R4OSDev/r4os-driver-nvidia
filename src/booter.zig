// GA106 production Booter preparation. Header/signature semantics adapt
// kernel_gsp_booter.c (RM570.144); ownership and bounded admission are R4OS.
// Original R4OS interfaces/admission are Apache-2.0. Adapted portions:
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
const std = @import("std");
const firmware = @import("firmware.zig");
const fuse = @import("fwsec_prepare.zig");
const transfer = @import("fwsec_load.zig");
pub const Operation = enum { load, unload };
pub const Fuses = fuse.Fuses;
pub const signature_bytes = 384;
pub const metadata_bytes = 36 + 768 + 4 + 4 + 12 + 4;
pub const Error = error{ Size, Layout, Profile, Fuse, Signature, Hash, Capacity, Overlap, Address, Alignment };
pub const Parts = struct {
    image: []const u8,
    header: []const u8,
    signatures: []const u8,
    patch_location: []const u8,
    patch_signature: []const u8,
    patch_metadata: []const u8,
    signature_count: []const u8,
};
pub const Info = struct { image_bytes: u32, code_offset: u32, code_bytes: u32, data_offset: u32, data_bytes: u32, signature_offset: u32 };
pub const Prepared = struct { operation: Operation, info: Info, fuse_version: u32, signature_index: u8 };

pub fn specification(operation: Operation) *const firmware.Booter {
    return &firmware.lock.booters[@intFromEnum(operation)];
}
comptime {
    if (!std.mem.eql(u8, firmware.lock.booters[0].operation, "load") or
        !std.mem.eql(u8, firmware.lock.booters[1].operation, "unload")) @compileError("Booter operation order differs from pin");
}

/// Structural GA102 HS profile only. Caller bytes are not authenticated here.
pub fn inspect(parts: Parts) Error!Info {
    if (parts.header.len != 36 or parts.signatures.len != 768 or parts.patch_location.len != 4 or
        parts.patch_signature.len != 4 or parts.patch_metadata.len != 12 or parts.signature_count.len != 4 or
        parts.image.len == 0 or parts.image.len > 65536 or parts.image.len & 255 != 0) return error.Size;
    if (word(parts.header, 0) != 0 or word(parts.header, 1) != 256 or word(parts.header, 4) != 1 or
        word(parts.header, 5) != 256 or word(parts.header, 7) != 256 or word(parts.header, 8) != 0) return error.Layout;
    const code = word(parts.header, 6);
    const data_offset = word(parts.header, 2);
    const data_bytes = word(parts.header, 3);
    if (code == 0 or data_bytes == 0 or (code | data_offset | data_bytes) & 255 != 0 or
        @as(u64, 256) + code != data_offset or @as(u64, data_offset) + data_bytes != parts.image.len) return error.Layout;
    if (word(parts.patch_signature, 0) != 0 or word(parts.signature_count, 0) != 2 or
        word(parts.patch_metadata, 0) != 1 or word(parts.patch_metadata, 1) != 1 or word(parts.patch_metadata, 2) != 3) return error.Profile;
    const offset = word(parts.patch_location, 0);
    if (@as(u64, data_offset) + 16 != offset or @as(u64, offset) + signature_bytes >= parts.image.len) return error.Signature;
    return .{ .image_bytes = @intCast(parts.image.len), .code_offset = 256, .code_bytes = code, .data_offset = data_offset, .data_bytes = data_bytes, .signature_offset = offset };
}
fn signatureIndex(fuses: Fuses) Error!struct { version: u32, index: u8 } {
    if (fuses.ucode_id != 3) return error.Fuse;
    const debug = fuse.debugEnabled(fuses.debug_disable_raw) catch return error.Fuse;
    // This package deliberately contains production binaries only; debug
    // silicon cannot silently receive a production or another-generation file.
    if (debug) return error.Profile;
    const version = fuse.fuseVersion(fuses.ucode_version_raw) catch return error.Fuse;
    if (version > 1) return error.Fuse;
    return .{ .version = version, .index = @intCast(1 - version) };
}
pub fn verify(operation: Operation, chip_id: u16, fuses: Fuses, parts: Parts) Error!Info {
    if (chip_id != 0x176) return error.Profile;
    _ = try signatureIndex(fuses);
    const spec = specification(operation);
    inline for (std.meta.fields(Parts)) |field| {
        const bytes = @field(parts, field.name);
        const expected = @field(spec.*, field.name);
        if (bytes.len != expected.bytes) return error.Size;
        if (!firmware.digestMatches(bytes, expected.sha256)) return error.Hash;
    }
    return inspect(parts);
}

/// Verify all original parts before touching output, then install the one
/// signature selected by SEC2 ucode3's fuse version. This does not prove GPU
/// authentication. Exact in-place preparation of a writable image is allowed;
/// all partial image aliases and all metadata/signature aliases are rejected.
pub fn prepare(operation: Operation, chip_id: u16, fuses: Fuses, parts: Parts, output: []u8) Error!Prepared {
    const info = try verify(operation, chip_id, fuses, parts);
    return prepareChecked(operation, fuses, parts, info, output);
}
fn prepareChecked(operation: Operation, fuses: Fuses, parts: Parts, info: Info, output: []u8) Error!Prepared {
    const selection = try signatureIndex(fuses);
    if (output.len < info.image_bytes) return error.Capacity;
    const destination = output[0..info.image_bytes];
    inline for (std.meta.fields(Parts)) |field| {
        const bytes = @field(parts, field.name);
        const identical_image = comptime std.mem.eql(u8, field.name, "image");
        if (!(identical_image and @intFromPtr(bytes.ptr) == @intFromPtr(destination.ptr) and bytes.len == destination.len)) {
            if (overlap(bytes, destination)) return error.Overlap;
        }
    }
    if (@intFromPtr(parts.image.ptr) != @intFromPtr(destination.ptr)) @memcpy(destination, parts.image);
    const start = @as(usize, selection.index) * signature_bytes;
    @memcpy(destination[info.signature_offset..][0..signature_bytes], parts.signatures[start..][0..signature_bytes]);
    return .{ .operation = operation, .info = info, .fuse_version = selection.version, .signature_index = selection.index };
}

/// Actual retained single-segment DMA address; not a CPU pointer or VRAM
/// offset. SEC2 TCM capacity/reset, authentication and quiescence are separate
/// native-owner obligations before any register or transfer is executed.
pub fn loadPlan(prepared: Prepared, address: u64, bytes: u32) Error!transfer.Plan {
    const info = prepared.info;
    if (bytes == 0 or bytes != info.image_bytes or @as(u64, info.code_offset) + info.code_bytes != info.data_offset or
        @as(u64, info.data_offset) + info.data_bytes != bytes or info.code_offset != 256 or info.code_bytes == 0 or info.data_bytes == 0 or
        @as(u64, info.data_offset) + 16 != info.signature_offset or @as(u64, info.signature_offset) + signature_bytes >= bytes) return error.Layout;
    if (address == 0 or address > transfer.dma_mask or @as(u64, bytes) - 1 > transfer.dma_mask - address) return error.Address;
    if ((address | bytes | info.code_bytes | info.data_bytes | info.data_offset) & 255 != 0) return error.Alignment;
    if (info.code_bytes > 0x1000000 or info.data_bytes > 0x1000000 or prepared.fuse_version > 1 or
        prepared.signature_index != 1 - prepared.fuse_version) return error.Profile;
    return .{
        // NVIDIA: image DMA + codeOffset - imemVa; both offsets are256.
        .imem = .{ .base = address, .destination = 0, .source_offset = 256, .bytes = info.code_bytes, .command = 0x614 },
        .dmem = .{ .base = address + info.data_offset, .destination = 0, .source_offset = 0, .bytes = info.data_bytes, .command = 0x600 },
        .boot_vector = 256,
        .signature_address = 16,
        .engine_mask = 1,
        .ucode_id = 3,
    };
}
fn word(bytes: []const u8, index: usize) u32 {
    return std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
}
fn overlap(left: []const u8, right: []const u8) bool {
    const a = @intFromPtr(left.ptr);
    const b = @intFromPtr(right.ptr);
    return if (a >= b) a - b < right.len else b - a < left.len;
}

test "GA102 Booter preparation selects its own fuse signature before any mutation" {
    const t = std.testing;
    const image = try t.allocator.alloc(u8, 65536 + 256);
    defer t.allocator.free(image);
    const output = try t.allocator.alloc(u8, 65536);
    defer t.allocator.free(output);
    var header: [36]u8 = undefined;
    var signatures: [768]u8 = undefined;
    @memset(signatures[0..384], 0x71);
    @memset(signatures[384..], 0x82);
    var location: [4]u8 = undefined;
    const index: [4]u8 = @splat(0);
    var metadata: [12]u8 = undefined;
    const count = [_]u8{ 2, 0, 0, 0 };
    for ([_]u32{ 1, 1, 3 }, 0..) |value, n| std.mem.writeInt(u32, metadata[n * 4 ..][0..4], value, .little);
    for ([_]Operation{ .load, .unload }) |operation| {
        // Actual original header extents; the body and signatures are clearly
        // synthetic fixtures. Real parts must still pass verify's pinned hash.
        const bytes: usize = if (operation == .load) 60416 else 40192;
        const code: u32 = if (operation == .load) 35072 else 20224;
        const data_offset = code + 256;
        for ([_]u32{ 0, 256, data_offset, @as(u32, @intCast(bytes)) - data_offset, 1, 256, code, 256, 0 }, 0..) |value, n|
            std.mem.writeInt(u32, header[n * 4 ..][0..4], value, .little);
        std.mem.writeInt(u32, &location, data_offset + 16, .little);
        @memset(image, 0x39);
        const parts = Parts{ .image = image[0..bytes], .header = &header, .signatures = &signatures, .patch_location = &location, .patch_signature = &index, .patch_metadata = &metadata, .signature_count = &count };
        const info = try inspect(parts);
        const fuses = Fuses{ .debug_disable_raw = 1, .ucode_version_raw = 1, .ucode_id = 3 };
        @memset(output, 0xa5);
        try t.expectError(error.Hash, prepare(operation, 0x176, fuses, parts, output));
        try t.expect(std.mem.allEqual(u8, output, 0xa5));
        for ([_]u32{ 0, 1 }) |version| {
            var observed = fuses;
            observed.ucode_version_raw = version;
            const prepared = try prepareChecked(operation, observed, parts, info, output);
            try t.expectEqual(@as(u8, @intCast(1 - version)), prepared.signature_index);
            const slot: usize = info.signature_offset;
            try t.expect(std.mem.allEqual(u8, output[0..slot], 0x39));
            try t.expectEqualSlices(u8, signatures[@as(usize, prepared.signature_index) * 384 ..][0..384], output[slot..][0..384]);
            try t.expect(std.mem.allEqual(u8, output[slot + 384 .. bytes], 0x39));
            try t.expect(std.mem.allEqual(u8, output[bytes..], 0xa5));
            const plan = try loadPlan(prepared, 0x123456000, @intCast(bytes));
            try t.expectEqual(@as(u64, 0x123456000), plan.imem.base);
            try t.expectEqual(@as(u32, 256), plan.imem.source_offset);
            try t.expectEqual(code, plan.imem.bytes);
            try t.expectEqual(@as(u64, 0x123456000) + data_offset, plan.dmem.base);
            try t.expectEqual(@as(u32, 16), plan.signature_address);
            try t.expectEqual(@as(u8, 3), plan.ucode_id);
            try t.expectEqual(@as(u16, 1), plan.engine_mask);
            try t.expectError(error.Address, loadPlan(prepared, 0, @intCast(bytes)));
            try t.expectError(error.Alignment, loadPlan(prepared, 0x123456001, @intCast(bytes)));
            try t.expectError(error.Address, loadPlan(prepared, transfer.dma_mask - 255, @intCast(bytes)));
            var stale = prepared;
            stale.info.data_offset += 256;
            try t.expectError(error.Layout, loadPlan(stale, 0x123456000, @intCast(bytes)));
        }
        @memset(output, 0xa5);
        try t.expectError(error.Capacity, prepareChecked(operation, fuses, parts, info, output[0 .. bytes - 1]));
        for ([_]Fuses{
            .{ .debug_disable_raw = 1, .ucode_version_raw = 1, .ucode_id = 9 },
            .{ .debug_disable_raw = 1, .ucode_version_raw = 3, .ucode_id = 3 },
            .{ .debug_disable_raw = 0xffffffff, .ucode_version_raw = 1, .ucode_id = 3 },
            .{ .debug_disable_raw = 1, .ucode_version_raw = 0xffffffff, .ucode_id = 3 },
        }) |bad| try t.expectError(error.Fuse, prepareChecked(operation, bad, parts, info, output));
        try t.expectError(error.Profile, prepareChecked(operation, .{ .debug_disable_raw = 0, .ucode_version_raw = 1, .ucode_id = 3 }, parts, info, output));
        try t.expect(std.mem.allEqual(u8, output, 0xa5));
        try t.expectError(error.Overlap, prepareChecked(operation, fuses, parts, info, image[128..][0..bytes]));
        try t.expect(std.mem.allEqual(u8, image, 0x39));
        var alias = parts;
        alias.signatures = image[0..768];
        try t.expectError(error.Overlap, prepareChecked(operation, fuses, alias, info, image));
        try t.expect(std.mem.allEqual(u8, image, 0x39));
        _ = try prepareChecked(operation, fuses, parts, info, image);
        try t.expect(std.mem.allEqual(u8, image[0..info.signature_offset], 0x39));
        try t.expectEqualSlices(u8, signatures[0..384], image[info.signature_offset..][0..384]);
        try t.expect(std.mem.allEqual(u8, image[info.signature_offset + 384 ..], 0x39));
        // Reject truncated and malformed independent metadata before copying.
        var bad = parts;
        bad.header = header[0..35];
        try t.expectError(error.Size, inspect(bad));
        header[16] = 2;
        try t.expectError(error.Layout, inspect(parts));
        header[16] = 1;
        metadata[8] = 9;
        try t.expectError(error.Profile, inspect(parts));
        metadata[8] = 3;
        std.mem.writeInt(u32, &location, @intCast(bytes - 128), .little);
        try t.expectError(error.Signature, inspect(parts));
        try t.expectError(error.Profile, verify(operation, 0x177, fuses, parts));
    }
}
