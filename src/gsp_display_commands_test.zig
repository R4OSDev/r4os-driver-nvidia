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
}
