const std = @import("std");
const t = std.testing;
const architecture = @import("gsp_architecture.zig");
const nv = @import("r4nv_binding");
pub fn check() !void {
    var pci: @import("identity.zig").Snapshot = .{ .pci = .{ .bus_kind = 2, .vendor_id = 0x10de, .device_id = 0x2503,
        .class_code = 3, .bus = 0x31, .device = 7, .function = 1 }, .revision = 0xa1 };
    var topology: @import("gsp_postinit.zig").Data = .{ .gpc_mask = 5, .tpc_count = 7 };
    topology.tpc_masks[0] = 7; topology.tpc_masks[2] = 15;
    var memory: @import("gsp_static.zig").Info = .{ .client = 1, .device = 2, .subdevice = 3, .fb_bytes = 12 << 30,
        .bar1_pdb = 0, .bar2_pdb = 0, .engine_caps = @splat(0), .region_count = 0, .non_wpr_heap = 0, .frts = 0 };
    var va: @import("gsp_vaspace.zig").Info = .{ .epoch = 0x100000035, .client = 1, .device = 2, .handle = 4,
        .base = 0x100000000, .bytes = 0x800000000, .big_page_bytes = 65536 };
    for ([_]u16{0x172,0x173,0x174,0x176,0x177,0x192,0x193,0x194,0x196,0x197}) |chip| {
        const result = try architecture.describe(&pci, chip, &topology, &memory, va, 0x100000035, 0xc7b5);
        var info: nv.R4NvArchitecture = undefined;
        @memcpy(std.mem.asBytes(&info), result.data[0..@sizeOf(nv.R4NvArchitecture)]);
        try t.expect(result.data_bytes == 120 and result.revision == nv.architecture_version and info.version == result.revision and std.mem.allEqual(u8, result.data[120..], 0));
        try t.expect(info.memory_generation == va.epoch and info.va_start == va.base and info.va_end == va.base + va.bytes);
        try t.expect(info.gpc_count == 2 and info.tpc_count == 7 and info.vram_bytes == 12 << 30 and
            info.flags == nv.architecture_host_coherent | nv.architecture_image_layouts);
        try t.expect(info.chipset == chip and info.pci_bus == 0x31 and info.pci_device == 7 and info.pci_function == 1 and info.pci_revision == 0xa1);
        try t.expect(info.shader_model == (if (chip < 0x190) @as(u32,86) else 89));
    }
    try t.expectError(error.Unsupported, architecture.describe(&pci, 0x175, &topology, &memory, va, va.epoch, 0xc7b5));
    try t.expectError(error.Unsupported, architecture.describe(&pci, 0x1b2, &topology, &memory, va, va.epoch, 0xc7b5));
    try t.expectError(error.Binding, architecture.describe(&pci, 0x176, &topology, &memory, va, va.epoch+1, 0xc7b5));
    topology.tpc_count += 1;
    try t.expectError(error.Geometry, architecture.describe(&pci, 0x176, &topology, &memory, va, va.epoch, 0xc7b5));
    topology.tpc_count -= 1; topology.tpc_masks[1] = 1;
    try t.expectError(error.Geometry, architecture.describe(&pci, 0x176, &topology, &memory, va, va.epoch, 0xc7b5));
    topology.tpc_masks[1] = 0; pci.pci.device = 32;
    try t.expectError(error.Binding, architecture.describe(&pci, 0x176, &topology, &memory, va, va.epoch, 0xc7b5));
    pci.pci.device = 7; va.bytes = std.math.maxInt(u64);
    try t.expectError(error.Binding, architecture.describe(&pci, 0x176, &topology, &memory, va, va.epoch, 0xc7b5));
    va.bytes = 0x800000000; memory.fb_bytes = 0;
    try t.expectError(error.Binding, architecture.describe(&pci, 0x176, &topology, &memory, va, va.epoch, 0xc7b5));
}
