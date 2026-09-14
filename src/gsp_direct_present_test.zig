//! Extends the existing native-product Device scenario. The actual runtime,
//! DMA table encoder and Window path consume independent modeled receipts.
const std = @import("std");
const t = std.testing;
const a = @import("r4os").abi;
const runtime = @import("gsp_runtime.zig");
const Device = @import("gsp_device.zig").Device;
const copy = @import("gsp_copy_test_model.zig").Model;
const native = @import("gsp_vram_test_model.zig").Model;
const display = @import("gsp_display_test_model.zig").Model;
const push = @import("gsp_display_push.zig");

pub fn check(target: *Device, clock: *u64, reply: anytype, head: anytype, table: anytype) !void {
    const run = &target.running; const product = &target.native_output;
    const resources = run.display_resources_slot.owner.?;
    var gpu_table = resources.table.image;
    const image = run.presentation.?.surface.scanout.?;
    const before_cpu = copy.host;
    const before_references = copy.heldReferences();
    const before_completed = copy.completed;
    const before_released = native.released;
    const before_bytes = run.copy_bytes;
    var previous_index: ?usize = null;
    var last_fence: a.GfxFence = .{};
    var checkpoint: []const u8 = "allocation";
    errdefer |err| std.debug.print("direct image: {s} at={s} device={s} failure={?} phase={?} flip={} held={d}\n",
        .{ @errorName(err), checkpoint, @tagName(target.phase), target.failure,
            if (run.direct_work) |value| value.phase else null, run.primaryFlip() != null, copy.heldScanouts() });
    try t.expect(run.direct_enabled and copy.heldScanouts() == 0);
    for (0..2) |pass| {
        checkpoint = "allocation";
        const deadline = clock.* + 5 * std.time.ns_per_s;
        const buffer = try run.allocateDisplaySurface(.{ .width = image.width, .height = image.height, .usage = 60 }, deadline);
        for (0..100) |_| {
            try tick(target, clock, reply, table, &gpu_table);
            if ((try run.nativeBufferStatus(buffer)).state == .handed_off) break;
        }
        const source = (try run.nativeBufferStatus(buffer)).info orelse return error.Allocation;
        const index = source.reference.buffer.id - 801;
        try t.expect(source.surface.descriptor.usage & a.gfx_buffer_usage_scanout != 0);
        for (0..image.height) |y| for (0..image.width) |x| copy.imagePixel(index, @intCast(x), @intCast(y), 0,
            0xff000000 | @as(u32, @intCast((pass + 1) * 0x10000 + y * 0x100 + x)));
        const notes = resources.publishedNotifier(product.window.?.slot).?;
        const words: [*]u32 = @ptrFromInt(notes.cpu.cpu_address);
        const previous = notes.offset;
        words[(previous ^ 16) / 4] = 2 << 30;
        const visible = run.flip_visible;
        const current = run.presentation.?;
        checkpoint = "direct submit";
        try copy.enqueueDirect(index, deadline); last_fence = copy.job.fence;
        for (0..160) |_| {
            try tick(target, clock, reply, table, &gpu_table);
            if (run.primaryFlip() != null and run.primaryFlip().?.window.phase == .submitted) break;
        }
        try t.expect(run.primaryFlip() != null and run.primaryFlip().?.window.phase == .submitted and copy.active and
            run.presentation == current and run.flip_visible == visible and run.copy_bytes == before_bytes);
        try t.expect(native.slots[index].gpu.lease.id != 0 and native.slots[index].gpu.access == 0);
        checkpoint = "producer close before BEGUN";
        try run.releaseNativeBuffer(buffer);
        try tick(target, clock, reply, table, &gpu_table);
        try t.expect(native.slots[index].live and !native.slots[index].reference and copy.active);
        checkpoint = "BEGUN and head IRQ";
        try activate(target, clock, head);
        for (0..20) |_| {
            try tick(target, clock, reply, table, &gpu_table);
            if (run.direct_work == null and run.flip_visible == visible + 1) break;
        }
        try t.expect(run.presentation.?.direct.?.handed_off and run.presentation.?.initial_point == 0 and
            run.presentation.?.surface.target.?.info().?.reference.buffer.id == source.reference.buffer.id and
            !copy.active and copy.heldScanouts() == pass + 1 and copy.completed == before_completed);
        const receipt = run.flip_receipts[product.mode.?.head].?;
        try t.expect(receipt.direct and receipt.render_point == 0 and receipt.begun_observed_ns != 0 and
            receipt.source_timeline == last_fence.timeline and receipt.source_point == last_fence.point);
        // BEGUN releases neither the former direct source nor the new one.
        if (previous_index) |old| try t.expect(native.slots[old].live and native.slots[old].gpu.lease.id != 0);
        checkpoint = "previous FINISHED";
        words[previous / 4] = 2 << 30;
        for (0..160) |_| {
            try tick(target, clock, reply, table, &gpu_table);
            if (run.primaryFlip() == null and run.direct_work == null and run.native_active == null and
                (if (previous_index) |old| !native.slots[old].live else true)) break;
        }
        try t.expect(run.primaryFlip() == null and run.direct_work == null and copy.heldScanouts() == 1 and
            copy.completed == before_completed + pass and native.slots[index].live and native.slots[index].gpu.access == 0);
        previous_index = index;
    }
    checkpoint = "close restores private image";
    copy.requestRetire(last_fence);
    for (0..40) |_| {
        try tick(target, clock, reply, table, &gpu_table);
        if (run.direct_work != null and run.direct_work.?.phase == .restore and run.direct_work.?.submitted) break;
    }
    try t.expect(run.direct_work != null and run.direct_work.?.phase == .restore and run.direct_work.?.submitted);
    const candidate = run.direct_work.?.target.?;
    const fifo = run.fifos[product.copy.?.slot].owner.?;
    const raw: [*]const u8 = @ptrFromInt(target.port.window.cpu_address);
    copy.beginRestore();
    try copy.fetch(fifo, raw[0..@intCast(target.port.window.byte_length)]);
    try copy.execute();
    try tick(target, clock, reply, table, &gpu_table);
    try t.expect(run.direct_work != null and run.frame_ready == null and copy.heldScanouts() == 1);
    const pixels = copy.imageBytes(candidate.surface.target.?.info().?.reference.buffer.id - 801);
    for (0..image.height) |y| for (0..image.width) |x| {
        const expected = 0xff000000 | @as(u32, @intCast(2 * 0x10000 + y * 0x100 + x));
        try t.expectEqual(expected, std.mem.readInt(u32, pixels[y * candidate.surface.scanout.?.pitch + x * 4..][0..4], .little));
    };
    const notes = resources.publishedNotifier(product.window.?.slot).?;
    const words: [*]u32 = @ptrFromInt(notes.cpu.cpu_address);
    const previous = notes.offset; words[(previous ^ 16) / 4] = 2 << 30;
    try copy.signal();
    for (0..40) |_| {
        try tick(target, clock, reply, table, &gpu_table);
        if (run.primaryFlip() != null and run.primaryFlip().?.window.phase == .submitted) break;
    }
    try t.expect(run.primaryFlip() != null and run.primaryFlip().?.window.phase == .submitted and copy.heldScanouts() == 1);
    checkpoint = "restore BEGUN";
    try activate(target, clock, head);
    for (0..20) |_| { try tick(target, clock, reply, table, &gpu_table); if (run.presentation == candidate) break; }
    try t.expect(run.presentation == candidate and candidate.direct == null and native.slots[previous_index.?].live and copy.heldScanouts() == 1);
    checkpoint = "last FINISHED and DMA table withdrawal";
    words[previous / 4] = 2 << 30;
    for (0..160) |_| {
        try tick(target, clock, reply, table, &gpu_table);
        if (run.primaryFlip() == null and run.direct_work == null and run.native_active == null and !native.slots[previous_index.?].live) break;
    }
    try t.expect(run.primaryFlip() == null and run.direct_work == null and run.native_active == null and copy.heldScanouts() == 0 and
        copy.completed == before_completed + 2 and native.released == before_released + 2 and
        copy.heldReferences() == before_references and run.copy_bytes == before_bytes + @as(u64, image.width) * image.height * 4);
    try t.expectEqualDeep(before_cpu, copy.host);
    std.debug.print("[nvidia-direct] two whole scanout images; BEGUN holds sources; FINISHED/table ACK retires; close restores via CE; CPU shadow unchanged\n", .{});
}
fn tick(target: *Device, clock: *u64, reply: anytype, table: anytype, gpu_table: anytype) !void {
    clock.* += 1000; _ = target.step(); try t.expect(target.phase == .ready);
    if (target.running.activeChannel().?.phase == .waiting) try reply(target);
    if (target.running.display_upload_job) |work| if (work.operation.phase == .prepared and work.operation.part == 0)
        try table(target, gpu_table, if (target.running.display_resources_slot.owner.?.table.change.?.remove) 1 else 2);
}
fn activate(target: *Device, clock: *u64, head: anytype) !void {
    _ = clock;
    const run = &target.running; const product = &target.native_output;
    const notes = run.display_resources_slot.owner.?.publishedNotifier(product.window.?.slot).?;
    const words: [*]u32 = @ptrFromInt(notes.cpu.cpu_address);
    const user = try push.userBase(.window, product.mode.?.window);
    display.words[(user + 4) / 4] = display.words[user / 4];
    words[notes.offset / 4 + 2] = @intCast(300 + run.flip_issued); words[notes.offset / 4 + 3] = 9;
    words[notes.offset / 4] = 1 << 30;
    try head(target, true);
}
