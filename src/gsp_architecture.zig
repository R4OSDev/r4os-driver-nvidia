// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Build copied hardware facts only from this driver's captured and
//! acknowledged records. Architecture classes do not authorize GPU execution.
const std = @import("std");
const r4os = @import("r4os");
const nv = @import("r4nv_binding");
const identity = @import("identity.zig");
const generation = @import("generation.zig");
const postinit = @import("gsp_postinit.zig");
const static = @import("gsp_static.zig");
const space = @import("gsp_vaspace.zig");

pub fn describe(pci: *const identity.Snapshot, chip: u16, topology: *const postinit.Data,
    memory: *const static.Info, va: space.Info, epoch: u64, copy_class: u32) !r4os.abi.GfxBackendProperties
{
    const profile = generation.get(chip) orelse return error.Unsupported;
    if (!generation.ga102Hal(chip) or profile.status != .implementation_ready) return error.Unsupported;
    if ((pci.pci.bus_kind != 1 and pci.pci.bus_kind != 2) or pci.pci.vendor_id != 0x10de or pci.pci.device_id == 0 or pci.pci.device_id == 0xffff or
        pci.pci.class_code != 3 or pci.pci.device > 31 or pci.pci.function > 7 or
        (copy_class != profile.copy[0] and copy_class != profile.copy[1]) or copy_class == 0) return error.Binding;
    if (epoch == 0 or va.epoch != epoch or va.base == 0 or va.bytes == 0 or va.base >= (@as(u64, 1) << 49) or
        va.bytes > (@as(u64, 1) << 49) - va.base or va.big_page_bytes != 65536 or
        va.base % va.big_page_bytes != 0 or va.bytes % va.big_page_bytes != 0 or memory.fb_bytes == 0) return error.Binding;
    const gpc = @popCount(topology.gpc_mask);
    if (gpc == 0) return error.Geometry;
    var tpc: u32 = 0;
    for (topology.tpc_masks, 0..) |mask, index| {
        const present = topology.gpc_mask & (@as(u32, 1) << @as(u5, @intCast(index))) != 0;
        if (present != (mask != 0)) return error.Geometry;
        tpc += @popCount(mask);
    }
    if (tpc == 0 or tpc != topology.tpc_count) return error.Geometry;
    // SM86/89 constants are architectural, not estimates of fused units.
    // Mesa 26.2.2 nouveau_device.c uses two MPs/TPC and 48 warps/MP here.
    if (profile.sm != 86 and profile.sm != 89) return error.Unsupported;
    const value: nv.R4NvArchitecture = .{
        .version = nv.architecture_version, .size = @sizeOf(nv.R4NvArchitecture), .vendor_id = pci.pci.vendor_id,
        .device_id = pci.pci.device_id, .chipset = chip, .pci_revision = pci.revision, .pci_domain = 0,
        .pci_bus = pci.pci.bus, .pci_device = pci.pci.device, .pci_function = pci.pci.function,
        .gpc_count = gpc, .tpc_count = tpc, .shader_model = profile.sm, .mp_per_tpc = 2, .max_warps_per_mp = 48,
        .rm_release = nv.rm_release, .vram_bytes = memory.fb_bytes, .va_start = va.base, .va_end = va.base + va.bytes,
        .memory_generation = epoch, .bind_alignment = va.big_page_bytes,
        .flags = nv.architecture_image_layouts |
            @as(u32, if (@import("gsp_buffer_wire.zig").hostCoherentPolicy()) nv.architecture_host_coherent else 0),
        .graphics_class = profile.render, .compute_class = profile.computeClass(),
        .copy_class = copy_class, .gpfifo_class = 0xc56f,
    };
    var result: r4os.abi.GfxBackendProperties = .{ .interface_id_lo = nv.backend_v1_header.interface_id_lo,
        .interface_id_hi = nv.backend_v1_header.interface_id_hi, .revision = nv.architecture_version, .data_bytes = @sizeOf(nv.R4NvArchitecture) };
    @memcpy(result.data[0..@sizeOf(nv.R4NvArchitecture)], std.mem.asBytes(&value));
    return result;
}
