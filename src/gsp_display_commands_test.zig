//! Original NVIDIA class definitions and Nouveau C DRF macros provide the
//! complete reference packets. Part of the existing transport test group.
const std = @import("std");
const t = std.testing;
const commands = @import("gsp_display_commands.zig");
const push = @import("gsp_display_push.zig");
const fixture = @embedFile("fixtures/display-commands.bin");
fn word(at: usize) u32 { return std.mem.readInt(u32, fixture[at..][0..4], .little); }
pub fn check() !void {
    try t.expect(fixture.len == 484 and word(0) == 4);
    var at: usize = 4;
    for (0..word(0)) |_| {
        const result = try commands.core(.{ .windows = word(at), .notifier = word(at + 4), .initialize = word(at + 8) == 1 });
        const count = word(at + 12); at += 16;
        try t.expectEqual(count, result.count);
        for (result.words[0..result.count]) |value| { try t.expectEqual(word(at), value); at += 4; }
    }
    try t.expectEqual(word(at), push.jump_zero);
    try t.expectEqual(@as(u16, 1022), try push.cursor(word(at + 4)));
    try t.expectEqual(@as(u16, 1023), try push.cursor(word(at + 8)));
    try t.expect(word(at + 12) == 16 and word(at + 16) == 0 and word(at + 20) == 1 << 30 and word(at + 24) == 2 << 30);
    try t.expect(at + 28 == fixture.len);
    try t.expectError(error.Bounds, commands.core(.{ .notifier = 1, .windows = 256, .initialize = true }));
    try t.expectError(error.Handle, commands.core(.{ .notifier = 0, .windows = 1, .initialize = true }));
    try t.expectError(error.Completion, push.cursor(0xffffffff));
    try checkImages();
}
fn checkImages() !void {
    const vectors = @embedFile("fixtures/display-image.bin");
    try t.expect(vectors.len == 984 and std.mem.readInt(u32, vectors[0..4], .little) == 4);
    var at: usize = 4;
    for (0..4) |_| {
        var fields: [15]u32 = undefined;
        for (&fields) |*field| { field.* = std.mem.readInt(u32, vectors[at..][0..4], .little); at += 4; }
        const image: commands.image.Image = .{ .dma = fields[7], .channel = 1 + fields[3], .width = fields[8], .height = fields[9],
            .pitch = fields[10], .format = fields[11], .offset = fields[12], .bytes = fields[13] };
        const config: commands.Config = .{ .kind = if (fields[0] == 0) .core else .window, .initialize = fields[1] == 1,
            .windows = fields[2], .route = .{ .window = fields[3], .head = fields[4] }, .notifier = fields[5],
            .notifier_offset = if (fields[0] == 0) 0 else @intCast(fields[6]), .scanout = if (fields[0] == 0) null else image };
        const result = try commands.encode(config);
        try t.expectEqual(fields[14], result.count);
        for (result.words[0..result.count]) |value| { try t.expectEqual(std.mem.readInt(u32, vectors[at..][0..4], .little), value); at += 4; }
        if (config.kind == .window) {
            var invalid = config;
            invalid.notifier_offset = 8; try t.expectError(error.Descriptor, commands.encode(invalid));
            invalid = config; invalid.scanout.?.bytes -= 1; try t.expectError(error.Bounds, commands.encode(invalid));
            invalid = config; invalid.scanout.?.pitch += 1; try t.expectError(error.Bounds, commands.encode(invalid));
            invalid = config; invalid.scanout.?.format = 0; try t.expectError(error.Unsupported, commands.encode(invalid));
            invalid = config; invalid.route.?.window = 8; try t.expectError(error.Bounds, commands.encode(invalid));
        }
    }
    try t.expect(at == vectors.len);
}
