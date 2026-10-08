//! Cursor protocol cases share the existing original-header transport group.
const std = @import("std");
const t = std.testing;
const pio = @import("gsp_cursor_pio.zig");
const head = @import("gsp_head_events.zig");
pub fn check(commands: []const u8) !void {
    const point: pio.Point = .{ .x = -17, .y = 29 };
    for (pio.methods, 0..) |method, i| {
        try t.expectEqual(std.mem.readInt(u32, commands[i * 8..][0..4], .little), method);
        try t.expectEqual(std.mem.readInt(u32, commands[i * 8 + 4..][0..4], .little), pio.value(point, i));
    }
    var owner: pio.Owner = .{};
    const idle: pio.Sample = .{ .free = 1, .control = 1, .state = 0x40000 };
    const event: head.Sample = .{ .sequence = 1, .observed_ns = 11 };
    try t.expectError(error.Bounds, owner.begin(32768, 0, 10, 100));
    try t.expectError(error.Bounds, owner.begin(0, -32769, 10, 100));
    try t.expectEqual(@as(u64, 1), try owner.begin(-17, 29, 10, 100));
    try t.expectError(error.Busy, owner.begin(1, 1, 10, 100));
    owner.pending.?.point.x += 1;
    try t.expectError(error.Stale, owner.prepare(12, event));
    owner.pending.?.point.x -= 1;
    try owner.prepare(12, event);
    try t.expectEqual(@as(usize,0),try owner.issueMethod(100));
    // A newer electrical IRQ and drained first method cannot complete a
    // position whose UPDATE has not been issued.
    try t.expect(!try owner.observe(idle,.{.sequence=2,.observed_ns=13},14));
    try owner.prepareUpdate(14,.{.sequence=2,.observed_ns=13});
    try t.expectEqual(@as(usize,1),try owner.issueMethod(100));
    try t.expectError(error.State,owner.issueMethod(100));
    try t.expect(!try owner.observe(idle,.{.sequence=2,.observed_ns=13},15));
    var later = event; later.sequence = 3; later.observed_ns = 15;
    // The IRQ can arrive between the worker clock and the snapshot. It
    // keeps the already written UPDATE owned until that clock catches up.
    try t.expect(!try owner.observe(idle, later, 14));
    try t.expect(owner.pending != null and owner.completed == null);
    try t.expect(owner.pending.?.next_method == pio.methods.len and owner.pending.?.update_submitted_ns == 14);
    var busy = idle; busy.state = 0x50000;
    try t.expect(try pio.writable(busy));
    try t.expect(!try owner.observe(busy, later, 16));
    busy = idle; busy.free = 0;
    try t.expect(!try owner.observe(busy, later, 16));
    try t.expect(try owner.observe(idle, later, 16));
    try t.expectEqualDeep(point, owner.completed.?.point);
    try t.expect(owner.completed.?.sequence == 1 and owner.completed.?.submitted_ns == 12 and owner.completed.?.drained_ns == 16);
    _ = try owner.begin(-32768, 32767, 17, 25);
    try owner.prepare(18, later);_ = try owner.issueMethod(25);try owner.prepareUpdate(19,later);_ = try owner.issueMethod(25);
    try t.expectError(error.Timeout, owner.observe(idle, later, 25));
    try t.expect(owner.pending != null and owner.pending.?.published);
    owner = .{ .issued = std.math.maxInt(u64) };
    try t.expectError(error.Exhausted, owner.begin(0, 0, 1, 2));
    try t.expectError(error.Completion, pio.idle(.{ .free = 0xffffffff, .control = 1, .state = 0x40000 }));
}
