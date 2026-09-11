// Explicit host preparation step only; never part of NVIDIA.R4D.
const preparation = @import("fwsec_prepare.zig");
const std = @import("std");
const wpr = @import("gsp_wpr.zig");
const gsp_init = @import("gsp_init.zig");
const message = @import("gsp_message.zig");
const ring = @import("gsp_ring.zig");
const boot_events = @import("gsp_boot_events.zig");
const sequencer = @import("gsp_sequencer.zig");
const core = @import("gsp_core.zig");
const hs = @import("falcon_hs.zig");
extern fn r4nv_falcon_hs_abi_check([*]const u32, usize) c_int;
extern fn r4nv_gsp_core_abi_check([*]const u32, usize) c_int;
extern fn r4nv_fwsec_abi_check([*]const u8, usize, c_uint, [*]const u8, usize, c_uint, [*]const u8, usize) c_int;
extern fn r4nv_gsp_init_abi_check([*]const u8, usize) c_int;
extern fn r4nv_gsp_message_abi_check([*]const u8, usize, c_uint) c_int;
extern fn r4nv_gsp_ring_abi_check([*]const u32, usize, c_uint) c_int;
extern fn r4nv_gsp_event_abi_fixture(c_uint, [*]u8, usize) usize;
extern fn r4nv_gsp_sequence_abi_fixture([*]u8, usize) usize;
pub fn main() !void {
    const r = core.reg;
    const b = core.bits;
    const core_values = [_]u32{
        r.hwcfg2,       r.engine,               r.rm,          r.fbif,      r.dmactl,        r.cpuctl,     r.cpuctl_alias,
        r.bcr,          r.riscv_cpuctl,         r.mailbox0,    r.mailbox1,  r.os,            r.sec_cpuctl, r.sec_cpuctl_alias,
        r.sec_mailbox0, r.handoff,              b.reset_ready, b.scrubbing, b.riscv_enabled, b.reset,      b.allow_phys,
        b.start,        b.alias,                b.halted,      b.bcr_riscv, b.bcr_valid,     b.bcr_boot,   b.active,
        b.handoff_done, core.propagation_reads,
    };
    if (r4nv_gsp_core_abi_check(&core_values, core_values.len) != 0) return error.OriginalCoreMismatch;
    const hr = hs.reg;
    const hb = hs.bits;
    const hs_values = [_]u32{
        hr.gsp,               hr.sec2,              hr.fbif_offset, hr.fbif_offset, hr.second_offset, hr.second_offset,
        hr.fbif_control,      hr.transcfg,          hr.dma_control, hr.dma_base,    hr.dma_base_high, hr.dma_destination,
        hr.dma_source_offset, hr.dma_command,       hr.signature,   hr.engine_mask, hr.ucode,         hr.algorithm,
        hr.boot_vector,       hr.cpu_control,       hr.cpu_alias,   hr.mailbox0,    hr.mailbox1,      hb.physical_no_context,
        hb.transcfg_mask,     hb.coherent_physical, hb.full,        hb.idle,        hb.imem_command,  hb.dmem_command,
        hb.rsa3k,             hb.cpu_alias,         hb.cpu_start,   hb.cpu_halted,
    };
    if (r4nv_falcon_hs_abi_check(&hs_values, hs_values.len) != 0) return error.OriginalHsMismatch;
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
    // Decode real original-C event layouts through the production codec. C
    // creates the bytes with its own generated types and original checksum.
    for (0..6) |fixture| {
        const length = r4nv_gsp_event_abi_fixture(@intCast(fixture), message_output.ptr, message_output.len);
        if (length != 4096) return error.OriginalEventMismatch;
        const record = try message.decode(.{ .chip_id = 0x176 }, message_output[0..length], @intCast(10 + fixture));
        if (record.rpc.result_private != 0x76543210 or record.rpc.sequence != 0x700 + fixture) return error.OriginalEventMismatch;
        const event = try boot_events.decode(record);
        const same = switch (fixture) {
            0 => event == .init_done,
            1 => check: {
                if (event != .cpu_sequencer) break :check false;
                const seq = event.cpu_sequencer;
                for (seq.saved, 0..) |value, index| if (value != 0x100 + index) break :check false;
                break :check seq.capacity_words == 8 and std.mem.eql(u8, seq.commands, &.{ 0x44, 0x33, 0x22, 0x11, 0x88, 0x77, 0x66, 0x55, 0xcc, 0xbb, 0xaa, 0x99 });
            },
            2 => event == .os_error and event.os_error.xid == 119 and event.os_error.runlist == 4 and
                event.os_error.channel == 0xffffffff and event.os_error.previous_xid == 13 and
                event.os_error.text.len == 256 and std.mem.allEqual(u8, event.os_error.text, 'X'),
            3 => event == .libos_print and event.libos_print.engine == 0x1234 and std.mem.eql(u8, event.libos_print.bytes, &.{ 0, '%', 0xff, 0x1b, 'Z' }),
            4 => event == .lockdown and event.lockdown,
            else => check: {
                if (event != .nocat) break :check false;
                const n = event.nocat;
                break :check n.flags == 3 and n.timestamp == 0x123456789abcdef0 and n.record_type == 7 and n.bugcheck == 0x79 and
                    std.mem.eql(u8, n.source, "rm") and n.subsystem == 8 and n.error_code == 0xfedcba9876543210 and
                    std.mem.eql(u8, n.engine, "gsp") and n.tdr_reason == 12 and std.mem.eql(u8, n.diagnostic, &.{ 0xde, 0xad, 0xbe, 0xef, 0x79 });
            },
        };
        if (!same) return error.OriginalEventMismatch;
    }
    const sequence_bytes = r4nv_gsp_sequence_abi_fixture(message_output.ptr, message_output.len);
    if (sequence_bytes != 88) return error.OriginalSequencerMismatch;
    const expected_commands = [_]sequencer.Command{
        .{ .write = .{ .address = 0x1234, .value = 0x5678 } },
        .{ .modify = .{ .address = 0x5678, .mask = 0xff00, .value = 0xf00f } },
        .{ .poll = .{ .address = 0x9010, .mask = 0xfff, .value = 0x321, .timeout_us = 7, .error_code = 99 } },
        .{ .delay_us = 13 },
        .{ .store = .{ .address = 0x1100, .index = 7 } },
        .core_reset,
        .core_start,
        .core_halt,
        .core_resume,
    };
    var position: usize = 0;
    for (expected_commands) |expected| {
        const instruction = try sequencer.decode(message_output[0..sequence_bytes], position);
        if (!std.meta.eql(instruction.command, expected)) return error.OriginalSequencerMismatch;
        position = instruction.next;
    }
    if (position != sequence_bytes) return error.OriginalSequencerMismatch;
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
