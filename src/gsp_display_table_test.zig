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
    const first = table.entries[0].?;
    const other = table.entries[1].?;
    const previous_revision = table.uploaded_revision;
    try table.remove(first.channel, first.handle);
    try t.expect(!table.published(first.channel, first.handle) and table.published(other.channel, other.handle));
    try t.expectError(error.Stale, table.finishRemove());
    _ = try table.beginUpload();
    try t.expect((try table.uploadRange(0)).bytes == 8 and table.uploadParts() == 1);
    try t.expectError(error.Busy, table.remove(other.channel, other.handle));
    try table.completeUpload(table.revision);
    try t.expect(try table.finishRemove() == 0);
    try t.expect(table.count == layout.capacity - 1 and table.freeIndex().? == 0 and table.uploaded_revision > previous_revision);
    var replacement = first; replacement.handle = 0x71234567; replacement.physical += 0x100000;
    try table.add(replacement);
    try t.expect(table.indexOf(replacement.channel, replacement.handle).? == 0 and table.uploadParts() == 2);
    try t.expect(table.published(other.channel, other.handle) and !table.published(replacement.channel, replacement.handle));
    try t.expectError(error.Busy, table.add(first));
    _ = try table.beginUpload();
    try t.expectEqual(layout.Range{ .offset = layout.ramht_bytes, .bytes = layout.descriptor_bytes }, try table.uploadRange(0));
    try t.expect((try table.uploadRange(1)).bytes == 8);
    try t.expectError(error.Bounds, table.uploadRange(2));
    // A retry retains the candidate; it never erases another collision-chain
    // entry or republishes a stale handle at the recycled descriptor slot.
    try table.cancelUpload(table.revision);
    _ = try table.beginUpload();
    try table.completeUpload(table.revision);
    try t.expect(!table.published(first.channel, first.handle) and table.published(replacement.channel, replacement.handle) and
        table.published(other.channel, other.handle) and table.change == null);
    var moved = table.*; try t.expect(!moved.valid());
}
fn word(at: usize) u32 { return std.mem.readInt(u32, fixture[at..][0..4], .little); }
