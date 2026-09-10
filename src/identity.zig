const std = @import("std");

pub const Pci = struct {
    bus_kind: u8 = 0,
    bus: u8 = 0,
    device: u8 = 0,
    function: u8 = 0,
    vendor_id: u16 = 0,
    device_id: u16 = 0,
    class_code: u8 = 0,
    subclass: u8 = 0,
    prog_if: u8 = 0,
};
pub const BarKind = enum { absent, io, memory32, memory64, upper, invalid };
pub const Bar = struct {
    raw: u32 = 0,
    kind: BarKind = .absent,
    base: u64 = 0,
    // Zero means unmeasured, never zero-sized or guessed from an address mask.
    bytes: u64 = 0,
    prefetchable: bool = false,
};
pub const Caps = struct {
    pm: u8 = 0,
    msi: u8 = 0,
    msix: u8 = 0,
    pcie: u8 = 0,
    power_state: ?u2 = null,
    rebar: u16 = 0,
};
pub const Snapshot = struct {
    pci: Pci,
    revision: u8 = 0,
    subsystem_vendor: u16 = 0,
    subsystem_device: u16 = 0,
    command: u16 = 0,
    interrupt_line: u8 = 0xff,
    interrupt_pin: u8 = 0,
    bars: [6]Bar = .{Bar{}} ** 6,
    rom_base: u64 = 0,
    rom_enabled: bool = false,
    caps: Caps = .{},
};
pub const Error = error{ NotNvidiaDisplay, Disappeared, Header, Capability, Resource };

pub fn isDisplay(pci: Pci) bool {
    return pci.vendor_id == 0x10de and pci.class_code == 3 and (pci.subclass == 0 or pci.subclass == 2);
}
pub fn isHdaSibling(gpu: Pci, audio: Pci) bool {
    return gpu.bus_kind == audio.bus_kind and gpu.bus == audio.bus and gpu.device == audio.device and
        gpu.function != audio.function and audio.vendor_id == 0x10de and audio.class_code == 4 and audio.subclass == 3;
}

/// The reader exposes only configuration reads. No sizing writes, PM changes,
/// MSI programming, BAR writes or second PCI enumeration belong in this layer.
pub fn capture(pci: Pci, reader: anytype) Error!Snapshot {
    if (!isDisplay(pci)) return error.NotNvidiaDisplay;
    const identity = @as(u32, pci.device_id) << 16 | pci.vendor_id;
    if (reader.read(0) != identity) return error.Disappeared;
    const header = reader.read(0x0c);
    if (header == 0xffffffff or ((header >> 16) & 0x7f) != 0) return error.Header;
    const class = reader.read(8);
    if (class >> 8 != @as(u32, pci.class_code) << 16 | @as(u32, pci.subclass) << 8 | pci.prog_if) return error.Disappeared;
    const status_command = reader.read(4);
    const subsystem = reader.read(0x2c);
    const irq = reader.read(0x3c);
    var result: Snapshot = .{
        .pci = pci,
        .revision = @truncate(class),
        .subsystem_vendor = @truncate(subsystem),
        .subsystem_device = @truncate(subsystem >> 16),
        .command = @truncate(status_command),
        .interrupt_line = @truncate(irq),
        .interrupt_pin = @truncate(irq >> 8),
    };
    var index: usize = 0;
    while (index < 6) : (index += 1) {
        const raw = reader.read(@as(u16, @intCast(0x10 + index * 4)));
        var bar = &result.bars[index];
        bar.raw = raw;
        if (raw == 0) continue;
        if (raw == 0xffffffff) return error.Resource;
        if (raw & 1 != 0) {
            bar.kind = .io;
            bar.base = raw & 0xfffffffc;
            continue;
        }
        bar.prefetchable = raw & 8 != 0;
        bar.base = raw & 0xfffffff0;
        switch ((raw >> 1) & 3) {
            0 => bar.kind = .memory32,
            2 => {
                if (index == 5) return error.Resource;
                const high = reader.read(@as(u16, @intCast(0x14 + index * 4)));
                bar.kind = .memory64;
                bar.base |= @as(u64, high) << 32;
                index += 1;
                result.bars[index] = .{ .raw = high, .kind = .upper };
            },
            else => return error.Resource,
        }
    }
    const rom = reader.read(0x30);
    if (rom != 0xffffffff) {
        result.rom_base = rom & 0xfffff800;
        result.rom_enabled = rom & 1 != 0;
    }
    if (status_command & (1 << 20) != 0) try standardCaps(&result.caps, reader);
    // bus_kind=2 denotes the canonical ECAM accessor. Legacy config reads
    // cannot address extended space and must never wrap it into 0..255.
    if (pci.bus_kind == 2 and result.caps.pcie != 0) try extendedCaps(&result, reader);
    if (reader.read(0) != identity or reader.read(4) & 0xffff != result.command) return error.Disappeared;
    return result;
}

fn standardCaps(caps: *Caps, reader: anytype) Error!void {
    var pointer: u16 = @intCast(reader.read(0x34) & 0xff);
    var seen: u64 = 0;
    while (pointer != 0) {
        if (pointer < 0x40 or pointer > 0xfc or pointer & 3 != 0) return error.Capability;
        const mask = @as(u64, 1) << @as(u6, @intCast(pointer / 4));
        if (seen & mask != 0) return error.Capability;
        seen |= mask;
        const header = reader.read(pointer);
        if (header == 0xffffffff) return error.Capability;
        const id: u8 = @truncate(header);
        const slot: ?*u8 = switch (id) {
            1 => &caps.pm,
            5 => &caps.msi,
            0x10 => &caps.pcie,
            0x11 => &caps.msix,
            else => null,
        };
        if (slot) |value| {
            if (value.* != 0) return error.Capability;
            value.* = @intCast(pointer);
            const msi64 = header & (1 << 23) != 0;
            const masked = header & (1 << 24) != 0;
            const length: u16 = switch (id) {
                1 => 8,
                5 => if (masked) (if (msi64) 24 else 20) else (if (msi64) 14 else 10),
                0x10 => 0x14,
                0x11 => 12,
                else => unreachable,
            };
            if (pointer + length > 0x100) return error.Capability;
            if (id == 1) caps.power_state = @truncate(reader.read(pointer + 4));
        }
        pointer = @intCast((header >> 8) & 0xff);
    }
}

fn extendedCaps(result: *Snapshot, reader: anytype) Error!void {
    var pointer: u16 = 0x100;
    var seen: [16]u64 = .{0} ** 16;
    var visits: usize = 0;
    while (pointer != 0) : (visits += 1) {
        if (visits >= 256 or pointer < 0x100 or pointer > 0xffc or pointer & 3 != 0) return error.Capability;
        const mask = @as(u64, 1) << @as(u6, @intCast(pointer / 4 % 64));
        if (seen[pointer / 256] & mask != 0) return error.Capability;
        seen[pointer / 256] |= mask;
        const header = reader.read(pointer);
        if (header == 0 or header == 0xffffffff) {
            if (pointer == 0x100) return;
            return error.Capability;
        }
        if (header & 0xffff == 0x15) {
            if (result.caps.rebar != 0 or (header >> 16) & 0xf != 1 or pointer > 0xff4) return error.Capability;
            result.caps.rebar = pointer;
            const control = reader.read(pointer + 8);
            const count = (control >> 5) & 7;
            if (count == 0 or count > 6 or pointer + 4 + count * 8 > 0x1000) return error.Capability;
            var bars_seen: u8 = 0;
            for (0..count) |index| {
                const offset: u16 = pointer + 4 + @as(u16, @intCast(index * 8));
                const supported = reader.read(offset) >> 4;
                const selected = reader.read(offset + 4);
                const bar_index = selected & 7;
                const size = (selected >> 8) & 0x3f;
                if (bar_index >= 6 or size >= 28 or supported & (@as(u32, 1) << @as(u5, @intCast(size))) == 0) return error.Resource;
                const bit = @as(u8, 1) << @as(u3, @intCast(bar_index));
                if (bars_seen & bit != 0) return error.Resource;
                bars_seen |= bit;
                const bar = &result.bars[bar_index];
                if (bar.kind != .memory32 and bar.kind != .memory64) return error.Resource;
                const bytes = @as(u64, 1024 * 1024) << @as(u6, @intCast(size));
                if (bar.base == 0 or bar.base % bytes != 0 or bar.base > std.math.maxInt(u64) - bytes or
                    (bar.kind == .memory32 and bar.base + bytes > @as(u64, 1) << 32)) return error.Resource;
                bar.bytes = bytes;
            }
        }
        pointer = @intCast(header >> 20);
    }
}

pub const ProbeDecision = enum { identity_words_only, unknown_pci_id, decode_disabled, power_unavailable, invalid_bar };
pub fn decision(snapshot: *const Snapshot) ProbeDecision {
    if (!isDisplay(snapshot.pci) or snapshot.pci.device_id != 0x2504) return .unknown_pci_id;
    if (snapshot.command & 2 == 0) return .decode_disabled;
    if (snapshot.caps.power_state) |power| {
        if (power != 0) return .power_unavailable;
    }
    const bar = snapshot.bars[0];
    if ((bar.kind != .memory32 and bar.kind != .memory64) or bar.prefetchable or bar.base == 0 or bar.base & 0xfff != 0) return .invalid_bar;
    return .identity_words_only;
}

pub const Chip = struct { id: u16, revision: u8, name: []const u8, profile: []const u8 };
pub fn chip(boot0: u32, boot1: u32) ?Chip {
    if (boot0 == 0 or boot0 == 0xffffffff or boot1 == 0xffffffff or boot1 & 0x30100 != 0) return null;
    const id: u16 = @intCast(((boot0 >> 20) & 0x1ff) | ((boot0 & 0x100) << 1));
    // Only the measured GA106 identity matches the sole bootstrap PCI entry.
    // This profile admits identification reads; it grants no engine writes.
    if (id != 0x176) return null;
    return .{ .id = id, .revision = @truncate(boot0), .name = "GA106", .profile = "ga106-identity-only" };
}
