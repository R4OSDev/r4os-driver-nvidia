//! Admission of the production GA102 GSP-RM RISC-V boot image used by GA106.
//! Hashes identify the decoded entries of the pinned original bindata archive.
//! This does not authenticate firmware on the GPU or allocate boot resources.
const std = @import("std");
const firmware = @import("firmware.zig");

comptime {
    // These interpretations must be reviewed when the central RM pin changes.
    if (!std.mem.eql(u8, firmware.lock.source_commit, "8ec351aeb96a93a4bb69ccc12a542bf8a8df2b6f") or
        !std.mem.eql(u8, firmware.lock.rm_version, "570.144"))
        @compileError("review GSP boot/layout against the new central firmware pin");
}
pub const source_path = firmware.lock.boot.source.path;
pub const image = firmware.lock.boot.image;
pub const descriptor = firmware.lock.boot.descriptor;
comptime {
    if (image.bytes != 24576 or descriptor.bytes != 84)
        @compileError("review production boot ABI when changing the artifact profile");
}
pub const Error = error{ WrongSize, WrongHash, DescriptorVersion, UnsupportedDescriptor, Bounds, Overlap };
pub const Range = struct { offset: u32, bytes: u32 };
pub const Info = struct {
    version: u32,
    app_version: u32,
    image_bytes: u32,
    bootloader: Range,
    parameters: Range,
    manifest: Range,
    monitor_data: Range,
    monitor_code: Range,
    fb_reserved_bytes: u32,
};

fn at(bytes: []const u8, index: usize) u32 {
    return std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
}
fn range(bytes: []const u8, index: usize, capacity: u32) Error!Range {
    const result = Range{ .offset = at(bytes, index), .bytes = at(bytes, index + 1) };
    if (result.bytes == 0 or result.offset > capacity or result.bytes > capacity - result.offset) return error.Bounds;
    return result;
}

/// Structural inspection of RM_RISCV_UCODE_DESC v5, not hash admission.
/// Only the bare-metal, enabled-monitor profile of this boot image is handled.
pub fn inspect(bytes: []const u8, image_bytes: u32) Error!Info {
    if (bytes.len != descriptor.bytes or image_bytes == 0 or image_bytes > 1024 * 1024) return error.WrongSize;
    if (at(bytes, 0) != 5) return error.DescriptorVersion;
    for ([_]usize{ 5, 6, 7, 15, 16, 17, 18, 20 }) |index|
        if (at(bytes, index) != 0) return error.UnsupportedDescriptor;
    if (at(bytes, 14) != 1) return error.UnsupportedDescriptor;
    if (at(bytes, 19) != image_bytes) return error.Bounds;
    const ranges = [_]Range{
        try range(bytes, 1, image_bytes),
        try range(bytes, 3, image_bytes),
        try range(bytes, 8, image_bytes),
        try range(bytes, 10, image_bytes),
        try range(bytes, 12, image_bytes),
    };
    for (ranges, 0..) |a, index| for (ranges[index + 1 ..]) |b| {
        if (@as(u64, a.offset) < @as(u64, b.offset) + b.bytes and
            @as(u64, b.offset) < @as(u64, a.offset) + a.bytes) return error.Overlap;
    };
    return .{
        .version = 5,
        .app_version = at(bytes, 7),
        .image_bytes = image_bytes,
        .bootloader = ranges[0],
        .parameters = ranges[1],
        .manifest = ranges[2],
        .monitor_data = ranges[3],
        .monitor_code = ranges[4],
        .fb_reserved_bytes = at(bytes, 19),
    };
}

pub fn verify(image_bytes: []const u8, descriptor_bytes: []const u8) Error!Info {
    if (image_bytes.len != image.bytes or descriptor_bytes.len != descriptor.bytes) return error.WrongSize;
    if (!firmware.digestMatches(image_bytes, image.sha256) or
        !firmware.digestMatches(descriptor_bytes, descriptor.sha256)) return error.WrongHash;
    return inspect(descriptor_bytes, @intCast(image_bytes.len));
}
