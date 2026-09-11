// Explicit host preparation step only; never part of NVIDIA.R4D.
const preparation = @import("fwsec_prepare.zig");
const std = @import("std");
const wpr = @import("gsp_wpr.zig");
const gsp_init = @import("gsp_init.zig");
const message = @import("gsp_message.zig");
const ring = @import("gsp_ring.zig");
extern fn r4nv_fwsec_abi_check([*]const u8, usize, c_uint, [*]const u8, usize, c_uint, [*]const u8, usize) c_int;
extern fn r4nv_gsp_init_abi_check([*]const u8, usize) c_int;
extern fn r4nv_gsp_message_abi_check([*]const u8, usize, c_uint) c_int;
extern fn r4nv_gsp_ring_abi_check([*]const u32, usize, c_uint) c_int;
pub fn main() !void {
    // Heap backing belongs only to this host comparison, never to a target
    // driver or its bounded stack. All DMA addresses below are synthetic.
    const init_output = try std.heap.page_allocator.alloc(u8, gsp_init.output_bytes);
    defer std.heap.page_allocator.free(init_output);
    var bindings: gsp_init.Bindings = .{
        .chip_id = 0x176,
        .libos = .{ .address = 0x900000000, .bytes = 4096 },
        .rm = .{ .address = 0x900001000, .bytes = 4096 },
        .logs = undefined,
        .queues = &.{
            .{ .address = 0xa00000000, .bytes = 4096 },
            .{ .address = 0xb00000000, .bytes = 65536 },
            .{ .address = 0xc00000000, .bytes = 112 * 4096 },
        },
    };
    for (&bindings.logs, 0..) |*span, index| span.* = .{ .address = 0x910000000 + index * 0x20000, .bytes = 65536 };
    _ = try gsp_init.encode(&bindings, init_output);
    if (r4nv_gsp_init_abi_check(init_output.ptr, init_output.len) != 0) return error.OriginalInitMismatch;
    const message_output = try std.heap.page_allocator.alloc(u8, message.max_bytes);
    defer std.heap.page_allocator.free(message_output);
    const payload = try std.heap.page_allocator.alloc(u8, message.max_payload_bytes);
    defer std.heap.page_allocator.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @truncate(index * 37 + 11);
    for ([_]usize{ 0, 1, 7, 4016, 4017, message.max_payload_bytes }, 0..) |length, index| {
        const shape = try message.encode(.{ .chip_id = 0x176 }, std.math.maxInt(u32) - @as(u32, @intCast(index)), .{ .function = 0xdeadbeef, .sequence = 0x12345678 }, payload[0..length], message_output);
        if (r4nv_gsp_message_abi_check(message_output.ptr, shape.storage_bytes, @intCast(index)) != 0) return error.OriginalMessageMismatch;
    }
    for (0..8) |fixture| {
        var command: [32]u8 = undefined;
        for ([_]u32{ 0, 262144, 4096, 63, 0, @intCast(fixture & 1), 32, 4096 }, 0..) |value, index|
            std.mem.writeInt(u32, command[index * 4 ..][0..4], value, .little);
        var status = command;
        std.mem.writeInt(u32, status[20..24], @intCast((fixture >> 1) & 1), .little);
        std.mem.writeInt(u32, status[24..28], 64, .little);
        const link = try ring.inspectLink(&command, &status);
        const count: u32 = if (fixture < 4) 1 else 16;
        const tx = try ring.transmit(link.command.layout, 60, 40, count);
        const rx = try ring.receive(link.status.layout, 60, 14, count);
        var record: [48]u32 = @splat(0);
        record[0..16].* = .{
            @intFromBool(link.swapped),           @intFromEnum(link.command_read.queue), @intCast(link.command_read.offset),
            @intFromEnum(link.status_read.queue), @intCast(link.status_read.offset),     link.command.layout.rx_offset,
            link.status.layout.rx_offset,         link.command.layout.slots,             link.status.layout.slots,
            tx.available_before,                  rx.available_before,                   tx.next_cursor,
            rx.next_cursor,                       tx.next_cursor,                        rx.next_cursor,
            count,
        };
        for ([_]ring.Plan{ tx, rx }, 0..) |transfer, direction| {
            var slot: usize = 0;
            for (transfer.spans[0..transfer.span_count]) |span| {
                var offset = span.offset;
                while (offset < span.offset + span.bytes) : (offset += message.element_bytes) {
                    record[16 + direction * 16 + slot] = @intCast(offset);
                    slot += 1;
                }
            }
        }
        if (r4nv_gsp_ring_abi_check(&record, @sizeOf(@TypeOf(record)), @intCast(fixture)) != 0) return error.OriginalRingMismatch;
    }
    const sb = try preparation.commandBytes(.sb);
    const frts = try preparation.commandBytes(.{ .frts = 0x123456000 });
    // Production descriptor values and captured GA106 register values; the
    // physical addresses are deliberately synthetic host comparison inputs.
    const fields = [_]u32{ 5, 20480, 2176, 22656, 16, 0, 0, 0, 0, 2048, 2048, 4096, 6144, 10496, 1, 0, 0, 0, 0, 24576, 0 };
    var descriptor: [84]u8 = undefined;
    for (fields, 0..) |value, index| std.mem.writeInt(u32, descriptor[index * 4 ..][0..4], value, .little);
    const metadata = try wpr.encode(&.{
        .chip_id = 0x176,
        .raw = .{ .values = .{ 0x80420100, 0x47f7, 0x10, 0x80, 2, 0, 0x10, 1, 12288, 0x1ffffe00, 0, 0, 0x10e09 }, .present = 0x1fff },
        .image_bytes = wpr.image_bytes,
        .descriptor = &descriptor,
        .signature_bytes = 4096,
    }, &.{
        .gsp_segments = &.{ .{ .address = 0x200000000, .bytes = 4096 }, .{ .address = 0x100000000, .bytes = 63672320 } },
        .boot_image = .{ .address = 0x300000000, .bytes = 24576 },
        .signature = .{ .address = 0x300006000, .bytes = 4096 },
        .crash_queue = .{ .address = 0x300007000, .bytes = 16384 },
    });
    if (r4nv_fwsec_abi_check(&sb.data, sb.length, sb.id, &frts.data, frts.length, frts.id, &metadata, metadata.len) != 0) return error.OriginalAbiMismatch;
}
