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
const firmware_run = @import("falcon_run.zig");
const preboot = @import("gsp_preboot.zig");
const static = @import("gsp_static.zig");
const host_page = @import("gsp_host_page.zig");
const host_vm = @import("gsp_host_vm_wire.zig");
const host_tlb = @import("gsp_host_tlb.zig");
const memory_clear = @import("gsp_memory_clear.zig");
extern fn r4nv_gsp_copy_caps_abi_check([*]const u8, usize, c_uint, c_uint, [*]u8) c_int;
extern fn r4nv_gsp_host_channel_abi_check(u32, u32, u32, u32, u32, u32) c_int;
extern fn r4nv_gsp_memory_clear_abi_check([*]const u8, usize, u64, u64) c_int;
extern fn r4nv_gsp_host_mmu_abi_check([*]const u32, usize, [*]const u8, usize, c_uint, u64) c_int;
extern fn r4nv_gsp_host_page_word(u64, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint) u64;
extern fn r4nv_gsp_host_vaspace_abi_check([*]const u8, usize) c_int;
extern fn r4nv_gsp_preboot_abi_check([*]const u32, usize, [*]const u8, usize) c_int;
extern fn r4nv_falcon_hs_abi_check([*]const u32, usize) c_int;
extern fn r4nv_gsp_core_abi_check([*]const u32, usize) c_int;
extern fn r4nv_fwsec_abi_check([*]const u8, usize, c_uint, [*]const u8, usize, c_uint, [*]const u8, usize) c_int;
extern fn r4nv_gsp_init_abi_check([*]const u8, usize) c_int;
extern fn r4nv_gsp_message_abi_check([*]const u8, usize, c_uint) c_int;
extern fn r4nv_gsp_ring_abi_check([*]const u32, usize, c_uint) c_int;
extern fn r4nv_gsp_event_abi_fixture(c_uint, [*]u8, usize) usize;
extern fn r4nv_gsp_sequence_abi_fixture([*]u8, usize) usize;
extern fn r4nv_gsp_unload_abi_check(c_uint, [*]const u8, usize, c_uint) c_int;
extern fn r4nv_gsp_memory_owner_abi_check([*]const u8, usize) c_int;
pub fn main() !void {
    try checkHostChannel();
    try checkCopyCaps();
    try checkMemoryClear();
    try checkHostMmu();
    const preboot_layout = [_]u32{ preboot.registry_header_bytes, preboot.registry_entry_bytes, 0, 4, 8, 12, static.payload_bytes, static.split_vas_offset, 1 };
    var boot_inputs: preboot.Payloads = .{};
    var boot_identity: @import("identity.zig").Snapshot = .{ .pci = .{ .vendor_id = 0x10de, .device_id = 0x2504, .class_code = 3 } };
    boot_identity.bars[0] = .{ .kind = .memory32, .base = 0xfc000000, .bytes = 0x1000000 };
    boot_identity.bars[1] = .{ .kind = .memory64, .base = 0xd0000000, .bytes = 0x10000000 };
    boot_identity.bars[2] = .{ .kind = .upper };
    boot_identity.bars[3] = .{ .kind = .memory64, .base = 0xe0000000, .bytes = 0x2000000 };
    boot_identity.bars[4] = .{ .kind = .upper };
    try preboot.encode(&boot_identity, 8192, &boot_inputs);
    if (r4nv_gsp_preboot_abi_check(&preboot_layout, preboot_layout.len, &boot_inputs.registry, boot_inputs.registry.len) != 0) return error.OriginalPrebootMismatch;
    // A syntactically valid but wrong mode must fail the independent C check.
    boot_inputs.registry[8 + 3 * 16 + 8] = 1;
    if (r4nv_gsp_preboot_abi_check(&preboot_layout, preboot_layout.len, &boot_inputs.registry, boot_inputs.registry.len) == 0) return error.OriginalPrebootNegativeMismatch;
    // Existing original-C packet fixtures must also satisfy RM's semantic
    // memory-owner contract. Layout-only fixtures previously admitted zero.
    const memory_packets = .{
        .{ @embedFile("fixtures/control-buffer-570.144.bin"), [_]usize{ 160, 320 } },
        .{ @embedFile("fixtures/buffer-part-570.144.bin"), [_]usize{ 160, 320 } },
        .{ @embedFile("fixtures/virtual-range-570.144.bin"), [_]usize{ 0, 160 } },
        .{ @embedFile("fixtures/vram-570.144.bin"), [_]usize{ 0, 160, 320, 480 } },
        .{ @embedFile("fixtures/native-storage-570.144.bin"), [_]usize{ 0, 160, 320, 480 } },
    };
    inline for (memory_packets) |fixture| for (fixture[1]) |at| try checkMemoryOwner(fixture[0][at..][0..160]);
    const images = @embedFile("fixtures/image-layout-570.144.bin");
    for (0..12) |index| for ([_]usize{ 0, 160 }) |at| try checkMemoryOwner(images[index * 432 + at ..][0..160]);
    const surfaces = @embedFile("fixtures/surface-rm-570.144.bin");
    for (0..16) |index| try checkMemoryOwner(surfaces[index * 160 ..][0..160]);
    const unload = @import("gsp_unload.zig");
    const request: unload.Owner = .{};
    if (r4nv_gsp_unload_abi_check(unload.function, &request.request, request.request.len, core.reg.mailbox0) != 0) return error.OriginalUnloadMismatch;
    const r = core.reg;
    const b = core.bits;
    const core_values = [_]u32{
        r.hwcfg2,       r.engine,               r.rm,                      r.fbif,                     r.dmactl,        r.cpuctl,     r.cpuctl_alias,
        r.bcr,          r.riscv_cpuctl,         r.mailbox0,                r.mailbox1,                 r.os,            r.sec_cpuctl, r.sec_cpuctl_alias,
        r.sec_mailbox0, r.handoff,              b.reset_ready,             b.scrubbing,                b.riscv_enabled, b.reset,      b.allow_phys,
        b.start,        b.alias,                b.halted,                  b.bcr_riscv,                b.bcr_valid,     b.bcr_boot,   b.active,
        b.handoff_done, core.propagation_reads, r.sec_hwcfg2,              r.sec_engine,               r.sec_rm,        r.sec_fbif,   r.sec_dmactl,
        r.sec_bcr,      b.reset,                firmware_run.hwcfg_offset, firmware_run.max_tcm_bytes,
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
fn checkHostChannel() !void {
    const wire = @import("gsp_fifo_wire.zig");
    const fixture = @embedFile("fixtures/fifo-570.144.bin");
    const gr = @embedFile("fixtures/gr-context-570.144.bin");
    const copy = @embedFile("fixtures/copy-570.144.bin");
    // Independent original C fields also validate the changed binary vectors.
    for (0..2) |queue| {
        const request = fixture[queue * 800..][0..400];
        const response = fixture[queue * 800 + 400..][0..400];
        if (r4nv_gsp_host_channel_abi_check(8, 0, @intCast(queue), 0, std.mem.readInt(u32, request[52..56], .little), 8) != 0 or
            r4nv_gsp_host_channel_abi_check(8, 0, @intCast(queue), 0, std.mem.readInt(u32, response[52..56], .little), 8) != 0 or
            r4nv_gsp_host_channel_abi_check(8, 0, 0, @intCast(queue), std.mem.readInt(u32, gr[2784 + queue * 4..][0..4], .little), 8) != 0) return error.OriginalHostChannelFixture;
    }
    for ([_]usize{72, 472}) |at| if (r4nv_gsp_host_channel_abi_check(8, 0, 0, 0,
        std.mem.readInt(u32, copy[at..][0..4], .little), 8) != 0) return error.OriginalHostCopyFixture;
    for (0..wire.host_channel_slots) |slot| {
        const chid = try wire.hardwareChannelForSlot(slot);
        for ([_]u32{0, 1, 127}) |runlist| {
            const token = try wire.hostWorkToken(chid, runlist);
            for (0..2) |queue| for ([_]bool{false, true}) |golden| {
                const flags = try wire.allocationFlags(chid, @intCast(queue), golden);
                if (r4nv_gsp_host_channel_abi_check(chid, runlist, @intCast(queue), @intFromBool(golden), flags, token) != 0) return error.OriginalHostChannelMismatch;
                for (0..32) |bit| {
                    const mask = @as(u32, 1) << @intCast(bit);
                    if (r4nv_gsp_host_channel_abi_check(chid, runlist, @intCast(queue), @intFromBool(golden), flags ^ mask, token) == 0 or
                        r4nv_gsp_host_channel_abi_check(chid, runlist, @intCast(queue), @intFromBool(golden), flags, token ^ mask) == 0) return error.OriginalHostChannelMutationAccepted;
                }
            };
        }
    }
}
fn checkCopyCaps() !void {
    const wire = @import("gsp_context_wire.zig");
    const binding: wire.Binding = .{ .epoch = 7, .client = 0x1234, .device = 2, .subdevice = 0x5678,
        .vaspace = 3, .group = 4, .share = 5, .internal_client = 0x2222, .internal_subdevice = 0x3333 };
    var request: [wire.length(.copy_caps)]u8 = undefined;
    var response: [wire.length(.copy_caps)]u8 = undefined;
    for (0..20) |ce| for (0..4) |flags| {
        const rm: u32 = @intCast(9 + ce);
        const encoded = try wire.encode(binding, rm, 0, .copy_caps, &request);
        if (r4nv_gsp_copy_caps_abi_check(encoded.ptr, encoded.len, @intCast(ce), @intCast(flags), &response) != 0)
            return error.OriginalCopyCapsMismatch;
        var record: message.Record = .{ .shape = .{ .message_bytes = 112, .checksum_bytes = 112, .storage_bytes = 4096, .elements = 1 },
            .queue_sequence = 0, .rpc = .{ .function = 76, .result = 0 }, .payload = &response };
        const reply = try wire.decode(binding, rm, 0, .copy_caps, encoded, record);
        const caps: wire.CopyCaps = .{ .bytes = reply.ok[4..6].* };
        if (caps.grce() != (flags & 1 != 0) or caps.sysmem() != (flags & 2 != 0) or caps.standalone() != (flags == 2))
            return error.OriginalCopyCapsFlagsMismatch;
        for (&request) |*byte| {
            byte.* ^= 1;
            if (r4nv_gsp_copy_caps_abi_check(&request, request.len, @intCast(ce), @intCast(flags), &response) == 0)
                return error.OriginalCopyCapsMutationAccepted;
            byte.* ^= 1;
        }
        response[24] ^= 1;
        if (wire.decode(binding, rm, 0, .copy_caps, encoded, record)) |_| return error.CopyCapsWrongEngineAccepted else |_| {}
        response[24] ^= 1;
        record.payload = response[0..24];
        if (wire.decode(binding, rm, 0, .copy_caps, encoded, record)) |_| return error.CopyCapsShortReplyAccepted else |_| {}
        response[12] = 0x57;
        if ((try wire.decode(binding, rm, 0, .copy_caps, encoded, record)).rejected != 0x57) return error.CopyCapsRejectionMismatch;
    };
}
fn checkMemoryClear() !void {
    const binding: memory_clear.Binding = .{ .epoch = 7, .client = 0x1234, .subdevice = 0x5678 };
    var packet: [memory_clear.bytes]u8 = undefined;
    var response: [memory_clear.bytes]u8 = undefined;
    for ([_]u64{0x80000000, 0x123400000}) |base| for ([_]u64{4096, 65536, 64 * 1024 * 1024}) |size| {
        const encoded = try memory_clear.encode(binding, base, size, &packet);
        if (r4nv_gsp_memory_clear_abi_check(encoded.ptr, encoded.len, base, size) != 0) return error.OriginalMemoryClearMismatch;
        response = packet;
        var record: message.Record = .{ .shape = .{ .message_bytes = memory_clear.bytes + 80, .checksum_bytes = memory_clear.bytes + 80, .storage_bytes = 4096, .elements = 1 },
            .queue_sequence = 0, .rpc = .{ .function = memory_clear.function, .result = 0 }, .payload = &response };
        if ((try memory_clear.decode(binding, base, size, encoded, record)) != .ok) return error.MemoryClearReplyMismatch;
        for (0..packet.len) |at| {
            packet[at] ^= 1;
            if (r4nv_gsp_memory_clear_abi_check(&packet, packet.len, base, size) == 0) return error.OriginalMemoryClearNegativeMismatch;
            packet[at] ^= 1;
        }
        response[104] ^= 1;
        if (memory_clear.decode(binding, base, size, encoded, record)) |_| return error.MemoryClearMutationAccepted else |_| {}
        response = packet; response[12] = 0x56; record.payload = response[0..24];
        if ((try memory_clear.decode(binding, base, size, encoded, record)).rejected != 0x56) return error.MemoryClearRejectionMismatch;
        response[12] = 0;
        if (memory_clear.decode(binding, base, size, encoded, record)) |_| return error.MemoryClearShortReplyAccepted else |_| {}
        record.payload = &response; record.rpc.result = message.pending;
        if (memory_clear.decode(binding, base, size, encoded, record)) |_| return error.MemoryClearOuterFailureAccepted else |_| {}
    };
}

fn checkHostMmu() !void {
    const objects = @import("gsp_objects.zig");
    var plan = try objects.Plan.init(7, .{ .client = 0xc1d00000, .device = 0x10000000, .subdevice = 0x10000001,
        .display = 0x10000002, .vaspace = 0x10000006 }, 0xffffffff, "");
    plan.external_vaspace = true;
    var request: [80]u8 = undefined;
    const allocated = try objects.encode(&plan, .{ .allocate = .vaspace }, &request);
    if (r4nv_gsp_host_vaspace_abi_check(allocated.bytes.ptr, allocated.bytes.len) != 0) return error.OriginalExternalVaspaceMismatch;
    request[36] = 0;
    if (r4nv_gsp_host_vaspace_abi_check(&request, request.len) == 0) return error.OriginalExternalVaspaceNegativeMismatch;
    for ([_]u64{ 4096, 0x12345000, 0x12345678000, host_page.system_limit - 4096 }) |physical| {
        const words = try host_tlb.words(physical);
        const values = [_]u32{ host_vm.external_vaspace_flags, host_vm.header_bytes, 32, 8,
            host_vm.command(.bind), host_vm.command(.unbind), host_page.stride(.root), host_page.stride(.dual), host_page.stride(.leaf),
            host_tlb.pf_base, host_tlb.pdb_low, host_tlb.pdb_high, host_tlb.invalidate, host_tlb.trigger, host_tlb.command, words[0], words[1] };
        var bytes: [host_vm.max_bytes]u8 = undefined;
        const binding: host_vm.Binding = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000, .vaspace = 0x10000006, .root_dma = physical };
        for ([_]host_vm.Operation{ .bind, .unbind }) |operation| {
            const encoded = try host_vm.encode(binding, operation, &bytes);
            if (r4nv_gsp_host_mmu_abi_check(&values, values.len, encoded.ptr, encoded.len, @intFromBool(operation == .bind), physical) != 0) return error.OriginalHostMmuMismatch;
            bytes[24] ^= 1; // Address/handle mutation must be independently rejected.
            if (r4nv_gsp_host_mmu_abi_check(&values, values.len, encoded.ptr, encoded.len, @intFromBool(operation == .bind), physical) == 0) return error.OriginalHostMmuNegativeMismatch;
        }
        for (1..3) |directory| if (try host_page.directory(physical) != r4nv_gsp_host_page_word(physical, @intCast(directory), 1, 0, 0, 0, 0, 0)) return error.OriginalDirectoryMismatch;
    }
    for ([_]host_page.Aperture{ .video, .system_coherent }) |aperture| {
        const limit = if (aperture == .video) host_page.video_limit else host_page.system_limit;
        for ([_]u64{ 4096, 0x12345000, limit - 4096 }) |physical| for (0..7) |kind| for (0..16) |flags| {
            const policy: host_page.Policy = .{ .aperture = aperture, .kind = @intCast(kind), .cached = flags & 1 != 0, .read_only = flags & 2 != 0, .atomic = flags & 4 != 0, .privileged = flags & 8 != 0 };
            const expected = r4nv_gsp_host_page_word(physical, 0, @intFromBool(aperture == .system_coherent), @intCast(kind), @intFromBool(policy.cached), @intFromBool(policy.read_only), @intFromBool(policy.atomic), @intFromBool(policy.privileged));
            if (try host_page.page(physical, policy) != expected) return error.OriginalPageMismatch;
        };
    }
}

fn checkMemoryOwner(bytes: *const [160]u8) !void {
    if (r4nv_gsp_memory_owner_abi_check(bytes, bytes.len) != 0) return error.OriginalMemoryOwnerMismatch;
    var invalid = bytes.*;
    for ([_]u32{ 0, 0xffffffff, 0xdeaf0000, 0xdeaf0009 }) |owner| {
        std.mem.writeInt(u32, invalid[32..36], owner, .little);
        if (r4nv_gsp_memory_owner_abi_check(&invalid, invalid.len) == 0) return error.InvalidMemoryOwnerAccepted;
    }
    invalid = bytes.*;
    invalid[41] &= ~@as(u8, 0x80); // Missing MAP_NOT_REQUIRED in the allocation flags.
    if (r4nv_gsp_memory_owner_abi_check(&invalid, invalid.len) == 0) return error.UnnormalizedMemoryFlagsAccepted;
}
