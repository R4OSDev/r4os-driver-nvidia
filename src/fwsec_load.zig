// Original R4OS load-parameter validation against NVIDIA 570.144's
// kgspExecuteHsFalcon_GA102 (also selected for GA106). No MMIO or execution.
const std = @import("std");
const preparation = @import("fwsec_prepare.zig");
pub const Error = preparation.Error || error{Alignment};
pub const block_bytes = 256;
// DMATRFBASE has 32 bits, BASE1 has 9 bits, both in 256-byte units.
pub const dma_mask: u64 = (@as(u64, 1) << 49) - 1;
pub const Transfer = struct {
    base: u64,
    destination: u32,
    source_offset: u32,
    bytes: u32,
    command: u32,
};
pub const Plan = struct {
    imem: Transfer,
    dmem: Transfer,
    boot_vector: u32,
    signature_address: u32,
    engine_mask: u16,
    ucode_id: u8,
};

/// The caller supplies an actual, retained, single-segment DMA mapping.
/// This checks the encoded ranges, not current TCM capacity, engine reset,
/// authentication or recovery. Those are required before executing the plan.
pub fn plan(prepared: *const preparation.Prepared, address: u64, bytes: u32) Error!Plan {
    const entry = &prepared.selection.entry;
    if (!preparation.supported(entry)) return error.Unsupported;
    if (prepared.command != 0x19 and prepared.command != 0x15) return error.Unsupported;
    if (bytes == 0 or bytes != prepared.bytes or bytes != entry.image.bytes) return error.Bounds;
    if (address == 0 or address > dma_mask or @as(u64, bytes) - 1 > dma_mask - address) return error.Address;
    if ((address | bytes | entry.code.bytes | entry.data.bytes | entry.imem_pa | entry.imem_va | entry.dmem_pa) & 255 != 0) return error.Alignment;
    if (entry.code.bytes == 0 or entry.data.bytes == 0 or entry.code.offset != entry.image.offset or
        @as(u64, entry.code.offset) + entry.code.bytes != entry.data.offset or
        @as(u64, entry.code.bytes) + entry.data.bytes > bytes) return error.Layout;
    // DMATRFMOFFS is a 24-bit byte address. Reject an entire overflowing
    // transfer, not just its first block. DMATRFFBOFFS is 32 bits.
    if (@as(u64, entry.imem_pa) + entry.code.bytes > 0x1000000 or
        @as(u64, entry.dmem_pa) + entry.data.bytes > 0x1000000 or
        @as(u64, entry.imem_va) + entry.code.bytes > @as(u64, std.math.maxInt(u32)) + 1) return error.Bounds;
    if (entry.imem_va > address) return error.Address;
    if (entry.signature_slot.offset < entry.data.offset or entry.signature_slot.bytes != 384 or
        @as(u64, entry.signature_slot.offset) + 384 > @as(u64, entry.data.offset) + entry.data.bytes) return error.Bounds;
    return .{
        .imem = .{ .base = address - entry.imem_va, .destination = entry.imem_pa, .source_offset = entry.imem_va, .bytes = entry.code.bytes, .command = 0x614 },
        // V3 explicitly uses FLCN_DMEM_VA_INVALID: no DMTAG and memOff=0.
        .dmem = .{ .base = address + entry.code.bytes, .destination = entry.dmem_pa, .source_offset = 0, .bytes = entry.data.bytes, .command = 0x600 },
        .boot_vector = entry.imem_va,
        .signature_address = entry.signature_slot.offset - entry.data.offset,
        .engine_mask = entry.engine_mask,
        .ucode_id = entry.ucode_id,
    };
}
