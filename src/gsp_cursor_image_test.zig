//! Existing transport group: independently compiled C packets plus pixel
//! padding/chunk boundaries. No GPU execution or physical visibility claim.
const std = @import("std");
const t = std.testing;
const cursor = @import("gsp_cursor_image.zig");
const commands = @import("gsp_display_commands.zig");
pub fn check() !void {
    const fixture = @embedFile("fixtures/display-cursor-image.bin");
    try t.expectEqual(@as(u32, 5), std.mem.readInt(u32, fixture[0..4], .little));
    var at: usize = 4;
    for (0..5) |_| {
        var fields: [8]u32 = undefined;
        for (&fields) |*value| { value.* = std.mem.readInt(u32, fixture[at..][0..4], .little); at += 4; }
        const value: cursor.Control = .{ .head = fields[0], .visible = fields[1] != 0, .size = @intCast(fields[2]),
            .hotspot_x = @intCast(fields[3]), .hotspot_y = @intCast(fields[4]), .offset = fields[5],
            .dma = if (fields[1] != 0) 0x1234 else 0, .storage_bytes = if (fields[1] != 0) 2 * cursor.max_bytes else 0 };
        try t.expectEqual(fields[6], try cursor.usageCode(value.size));
        const program = try commands.core(.{ .notifier = 0x4321, .windows = 8, .initialize = false, .cursor_image = value });
        try t.expectEqual(fields[7], program.count);
        for (program.words[0..program.count]) |word| {
            try t.expectEqual(std.mem.readInt(u32, fixture[at..][0..4], .little), word); at += 4;
        }
    }
    try t.expectEqual(fixture.len, at);
    var input: [3 * 16]u8 = @splat(0xee);
    for (0..3) |y| for (0..3) |x| std.mem.writeInt(u32, input[y * 16 + x * 4..][0..4], @as(u32, @intCast(x + y * 3)) << 24 | 0x010203, .little);
    const plan = try cursor.make(3, 3, 2, 1, 16, input.len);
    try t.expect(plan.size == 32 and plan.bytes() == 4096);
    var output: [4096]u8 = undefined;
    try cursor.pack(plan, &input, 0, output[0..132]);
    try cursor.pack(plan, &input, 132, output[132..]);
    for (0..32) |y| for (0..32) |x| {
        const word = std.mem.readInt(u32, output[(y * 32 + x) * 4..][0..4], .little);
        try t.expectEqual(if (x < 3 and y < 3) std.mem.readInt(u32, input[y * 16 + x * 4..][0..4], .little) else @as(u32, 0), word);
    };
    try t.expectError(error.Bounds, cursor.make(257, 1, 0, 0, 1028, 1028));
    try t.expectError(error.Bounds, cursor.make(32, 32, 32, 0, 128, 4096));
    try t.expectError(error.Bounds, cursor.make(32, 32, 0, 0, 124, 4096));
    try t.expectError(error.Bounds, cursor.pack(plan, &input, 1, &output));
    var invalid: cursor.Control = .{ .head = 1, .visible = true, .dma = 1, .size = 32, .storage_bytes = 4096 };
    invalid.offset = 1; try t.expectError(error.Bounds, invalid.validate());
    invalid.offset = 256; try t.expectError(error.Bounds, invalid.validate());
    invalid.offset = 0; invalid.hotspot_x = 32; try t.expectError(error.Bounds, invalid.validate());
    invalid.visible = false; try t.expectError(error.Descriptor, invalid.validate());
}
