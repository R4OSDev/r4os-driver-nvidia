//! Select the physical boot owner before any firmware/display mutation.
const identity = @import("identity.zig");
const a = @import("r4os").abi;
pub const Error = error{ BootUnavailable, NoBootAdapter, AmbiguousBootAdapter, UnsupportedBootAdapter };

pub fn id(pci: identity.Pci) u32 {
    return 0x01000000 | (@as(u32, pci.bus) << 8) | (@as(u32, pci.device) << 3) | pci.function;
}

/// BAR1 extents must have been measured without sizing writes. A matching
/// base alone is not an ownership proof. Unknown or conflicting assignments
/// preserve bootfb; PCI identity alone never starts a native port.
pub fn selectBoot(devices: []const identity.Snapshot, boot: a.GfxNativeBootInfo) Error!usize {
    if (boot.version != 1 or boot.size < @sizeOf(a.GfxNativeBootInfo) or boot.generation == 0 or
        boot.state != a.display_state_bootfb or boot.policy != 0 or boot.physical_address == 0 or
        boot.width == 0 or boot.height == 0 or boot.pitch == 0 or boot.byte_length == 0 or
        @as(u64, boot.pitch) * boot.height > boot.byte_length or boot.physical_address > ~@as(u64, 0) - boot.byte_length)
        return error.BootUnavailable;
    var found: ?usize = null;
    for (devices, 0..) |*device, index| {
        const bar = device.bars[1];
        if ((bar.kind != .memory32 and bar.kind != .memory64) or bar.base == 0 or bar.bytes == 0 or
            bar.base > ~@as(u64, 0) - bar.bytes or boot.physical_address < bar.base or
            boot.physical_address - bar.base >= bar.bytes or boot.byte_length > bar.bytes - (boot.physical_address - bar.base)) continue;
        if (found != null) return error.AmbiguousBootAdapter;
        found = index;
    }
    const index = found orelse return error.NoBootAdapter;
    if (identity.decision(&devices[index]) != .identity_words_only) return error.UnsupportedBootAdapter;
    return index;
}
