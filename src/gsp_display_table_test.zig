//! Existing transport-group probe: complete output from pinned original
//! Nouveau RAMHT and GV100 binder C functions, not a duplicate Zig codec.
const std = @import("std");
const t = std.testing;
const layout = @import("gsp_display_table.zig");
const fixture = @embedFile("fixtures/display-table-nouveau.bin");
pub fn check() !void {
    try t.expect(fixture.len == 12296 and word(0) == layout.capacity);
    const table = try t.allocator.create(layout.Table); defer t.allocator.destroy(table);
    table.* = .{}; try table.init(word(4), 0xc123ffff, 7);
    try t.expectError(error.Busy, table.beginUpload());
    for (0..layout.capacity) |i| {
        const at = 8 + i * 32;
        const input: layout.Descriptor = .{ .channel = word(at), .handle = word(at + 4),
            .physical = std.mem.readInt(u64, fixture[at + 8..][0..8], .little),
            .bytes = std.mem.readInt(u64, fixture[at + 16..][0..8], .little),
            .target = if (word(at + 24) == 1) .vram else .coherent_system };
        try table.add(input);
        try t.expect(table.buckets[word(at + 28)].? == i and !table.published(input.channel, input.handle));
        if (i == 0) {
            try t.expectError(error.Handle, table.add(input));
            var bad = input; bad.physical += 1; try t.expectError(error.Bounds, layout.validate(bad));
            bad = input; bad.bytes = (@as(u64, 1) << 40); try t.expectError(error.Bounds, layout.validate(bad));
            bad = input; bad.channel = 9; try t.expectError(error.Handle, layout.validate(bad));
        }
    }
    try t.expectEqualSlices(u8, fixture[8 + layout.capacity * 32..], &table.image);
    var extra = table.entries[0].?; extra.handle += 1;
    try t.expectError(error.Exhausted, table.add(extra));
    _ = try table.beginUpload();
    try t.expectError(error.Busy, table.add(extra));
    table.image[0] ^= 1;
    try t.expectError(error.Stale, table.completeUpload(table.revision));
    table.image[0] ^= 1;
    try t.expectError(error.Stale, table.completeUpload(table.revision - 1));
    try table.completeUpload(table.revision);
    for (&table.entries) |*entry| try t.expect(table.published(entry.*.?.channel, entry.*.?.handle));
    try t.expectError(error.Busy, table.beginUpload());
    var moved = table.*; try t.expect(!moved.valid());
}
fn word(at: usize) u32 { return std.mem.readInt(u32, fixture[at..][0..4], .little); }
