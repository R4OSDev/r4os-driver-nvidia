// Explicit host preparation step only; never part of NVIDIA.R4D.
const preparation = @import("fwsec_prepare.zig");
const std = @import("std");
const wpr = @import("gsp_wpr.zig");
const gsp_init = @import("gsp_init.zig");
const message = @import("gsp_message.zig");
extern fn r4nv_fwsec_abi_check([*]const u8, usize, c_uint, [*]const u8, usize, c_uint, [*]const u8, usize) c_int;
extern fn r4nv_gsp_init_abi_check([*]const u8, usize) c_int;
extern fn r4nv_gsp_message_abi_check([*]const u8, usize, c_uint) c_int;
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
