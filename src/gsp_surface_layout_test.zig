// Extends the existing RM transport group; no extra test gate.
const std = @import("std");
const t = std.testing;
const surface = @import("gsp_surface_layout.zig");
const wire = @import("gsp_vram_wire.zig");
const message = @import("gsp_message.zig");
fn long(data: []const u8, at: usize) u64 { return std.mem.readInt(u64, data[at..][0..8], .little); }
pub fn check() !void {
    var space: @import("gsp_vaspace.zig").Info = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000,
        .handle = 0x10000006, .base = 0x200000, .bytes = @as(u64, 1) << 48, .big_page_bytes = 65536 };
    var caps: @import("gsp_memory_caps.zig").Info = .{ .binding = .{ .epoch = space.epoch, .client = space.client, .device = space.device }, .raw = .{15,129,18} };
    const golden = @embedFile("fixtures/surface-layout-570.144.bin");
    for (0..16) |index| {
        const vector = golden[index * 64..][0..64];
        caps.raw[1] = if (index % 2 == 0) 129 else 1;
        const cpp = long(vector, 16);
        const request: surface.Request = .{ .width = @intCast(long(vector, 0)), .height = @intCast(long(vector, 8)),
            .format = if (cpp == 1) .r8 else if (cpp == 2) .p010 else .xrgb8888, .layout = .blocklinear,
            .block_height = if (cpp == 2) @intCast(long(vector, 24)) else null };
        const plan = try surface.create(1, space, caps, request);
        try t.expectEqual(long(vector, 24), surface.automaticBlockHeight(request.height));
        try t.expectEqual(long(vector, 24), plan.log2_gobs);
        try t.expectEqual(long(vector, 32), plan.descriptor.plane_pitches[0]);
        try t.expectEqual(long(vector, 40), plan.padded_rows[0]);
        try t.expectEqual(long(vector, 48), plan.plane_bytes[0]);
        try t.expectEqual(long(vector, 56), plan.descriptor.modifier);
        try plan.validate(1, space);
        var changed = plan; changed.descriptor.plane_pitches[0] += 64;
        try t.expectError(error.Descriptor, changed.validate(1, space));
    }
    caps.raw = .{15,129,18};
    const linear = try surface.create(1, space, caps, .{ .width = 1919, .height = 1079 });
    try t.expect(linear.descriptor.modifier == 0 and linear.descriptor.plane_pitches[0] == 7680 and linear.padded_rows[0] == 1079);
    const yuv = try surface.create(1, space, caps, .{ .width = 1919, .height = 1079, .format = .nv12, .layout = .blocklinear });
    try t.expect(yuv.log2_gobs == 4 and yuv.descriptor.plane_count == 2 and yuv.descriptor.plane_pitches[1] == 1920);
    try t.expect(yuv.padded_rows[0] == 1152 and yuv.padded_rows[1] == 640 and yuv.plane_bytes[1] == 1228800);
    try t.expect(yuv.descriptor.plane_offsets[1] == 2228224 and yuv.allocation_bytes == 3473408);
    const p010 = try surface.create(1, space, caps, .{ .width = 5, .height = 3, .format = .p010, .layout = .blocklinear });
    try t.expect(p010.log2_gobs == 0 and p010.descriptor.plane_pitches[1] == 64 and p010.padded_rows[1] == 8 and p010.allocation_bytes == 131072);
    for ([_]u8{0,1,2,3,4,5}) |h| {
        const plan = try surface.create(1, space, caps, .{ .width = 64, .height = 9, .layout = .blocklinear, .block_height = h });
        try t.expect(plan.log2_gobs == h and plan.padded_rows[0] % (@as(u64, 8) << @intCast(h)) == 0);
    }
    try t.expectError(error.Unsupported, surface.create(1, space, caps, .{ .width = 1, .height = 1, .layout = .blocklinear, .block_height = 6 }));
    try t.expectError(error.Descriptor, surface.create(1, space, caps, .{ .width = 1, .height = 1, .block_height = 0 }));
    try t.expectError(error.Descriptor, surface.create(1, space, caps, .{ .width = 0, .height = 1 }));
    try t.expectError(error.Descriptor, surface.create(1, space, caps, .{ .width = 1, .height = 1, .usage = 15 }));
    try t.expectError(error.Bounds, surface.create(1, space, caps, .{ .width = 0xffffffff, .height = 1 }));
    try t.expectError(error.Bounds, surface.create(1, space, caps, .{ .width = 1, .height = 0xffffffff, .layout = .blocklinear }));
    try t.expectError(error.Unsupported, surface.create(1, space, caps, .{ .width = 5, .height = 3, .format = .nv12, .usage = 32 }));
    try t.expectError(error.Unsupported, surface.create(1, space, caps, .{ .width = 6, .height = 4, .format = .r8, .usage = 32 }));
    caps.binding.epoch += 1;
    try t.expectError(error.Stale, surface.create(1, space, caps, .{ .width = 1, .height = 1 }));
    caps.binding.epoch -= 1;
    for ([_][3]u8{.{0,0,0}, .{2,0,0}}) |bits| {
        caps.raw = bits;
        _ = try surface.create(1, space, caps, .{ .width = 1, .height = 1 });
        try t.expectError(error.Unsupported, surface.create(1, space, caps, .{ .width = 1, .height = 1, .layout = .blocklinear }));
    }
    space.bytes = 65535;
    try t.expectError(error.Bounds, surface.create(1, space, caps, .{ .width = 1, .height = 1 }));

    const binding: wire.Binding = .{ .space = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000, .handle = 0x10000006,
        .base = 0x200000, .bytes = 0x100000000, .big_page_bytes = 65536 }, .memory = 0x10000007, .virtual = 0x10000008 };
    const rm = @embedFile("fixtures/surface-rm-570.144.bin");
    var request: [160]u8 = undefined;
    var offset: usize = 0;
    for ([_]bool{false,true}) |tiled| for ([_]bool{false,true}) |scanout| {
        for ([_]wire.Operation{.allocate_memory,.allocate_virtual}) |op| {
            const encoded = try wire.encodeLayout(binding, 64 * 1024 * 1024, .{ .blocklinear = tiled, .scanout = scanout }, op, 0, &request);
            try t.expectEqualSlices(u8, rm[offset..][0..160], encoded.bytes);
            var response: [160]u8 = rm[offset + 160..][0..160].*;
            const record: message.Record = .{ .shape = .{ .message_bytes = 240, .checksum_bytes = 240, .storage_bytes = 4096, .elements = 1 },
                .queue_sequence = 0, .rpc = .{ .function = 103, .result = 0 }, .payload = &response };
            try t.expect((try wire.decode(binding, 64 * 1024 * 1024, op, encoded.bytes, record, 0)) == .ok);
            response[58] ^= 2; // A successful reply changing PITCH/BLOCK_LINEAR is uncertain.
            try t.expectError(error.Payload, wire.decode(binding, 64 * 1024 * 1024, op, encoded.bytes, record, 0));
            if (scanout and op == .allocate_memory) {
                response = rm[offset + 160..][0..160].*;
                response[59] ^= 0x18; // Contiguous scanout must not become noncontiguous.
                try t.expectError(error.Payload, wire.decode(binding, 64 * 1024 * 1024, op, encoded.bytes, record, 0));
            }
            offset += 320;
        }
    };
    try t.expect(offset == rm.len);
}
