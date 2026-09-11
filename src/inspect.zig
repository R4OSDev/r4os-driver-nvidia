const std = @import("std");
const vbios = @import("vbios.zig");
const fwsec = @import("fwsec.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 4 or std.mem.eql(u8, args[1], args[2])) {
        std.debug.print("Usage: nvbios-inspect INPUT.rom OUTPUT.json [PCI-device-hex]\n", .{});
        return error.Arguments;
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(vbios.max_rom_bytes));
    defer init.gpa.free(rom);
    const expected: ?u16 = if (args.len == 4) try std.fmt.parseInt(u16, args[3], 16) else null;
    const start = try vbios.promStart(rom);
    const result = vbios.parse(rom[start.offset..], expected) catch |err| {
        std.debug.print("NVIDIA VBIOS rejected: {s}; no report published.\n", .{@errorName(err)});
        return err;
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rom, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const chain = rom[start.offset..][0..result.rom_bytes];
    const chain_hex = try fwsec.sha256(chain, .{ .offset = 0, .bytes = result.rom_bytes });
    var fwsec_error: ?[]const u8 = null;
    const catalog: ?fwsec.Catalog = fwsec.parse(chain, &result) catch |err| blk: {
        fwsec_error = @errorName(err);
        break :blk null;
    };
    const EntryReport = struct { entry: fwsec.Entry, descriptor_sha256: []const u8, image_sha256: []const u8, signatures_sha256: ?[]const u8 };
    var entries: [fwsec.max_entries]EntryReport = undefined;
    var hashes: [fwsec.max_entries][3][64]u8 = undefined;
    if (catalog) |*value| {
        for (value.entries[0..value.count], 0..) |*entry, index| {
            hashes[index][0] = try fwsec.sha256(chain, entry.descriptor);
            hashes[index][1] = try fwsec.sha256(chain, entry.image);
            if (entry.signatures.bytes != 0) hashes[index][2] = try fwsec.sha256(chain, entry.signatures);
            entries[index] = .{ .entry = entry.*, .descriptor_sha256 = &hashes[index][0], .image_sha256 = &hashes[index][1], .signatures_sha256 = if (entry.signatures.bytes == 0) null else &hashes[index][2] };
        }
    }
    var gpio_entries: [vbios.gpio.max_entries]vbios.gpio.Entry = undefined;
    if (result.gpio_table) |*gpio| for (0..gpio.count) |i| {
        gpio_entries[i] = try gpio.entry(i);
    };
    const report = .{
        .schema = 4,
        .source = "supplied-file",
        .sha256 = digest_hex[0..],
        .hardware_verified = false,
        .native_initialization_authorized = false,
        .prom_offset = start.offset,
        .ifr_version = start.ifr_version,
        .rom_bytes = result.rom_bytes,
        .pci_chain_sha256 = chain_hex[0..],
        .first_extension_offset = result.first_extension_offset,
        .expansion_rom_offset = result.expansion_rom_offset,
        .image_count = result.image_count,
        .image_offset = result.image_offset,
        .image_bytes = result.image_bytes,
        .checksum_bytes = result.checksum_bytes,
        .checksum_scope = "x86-initialization-only",
        .pci_device = result.pci_device,
        .vbios_version = result.vbios_version,
        .version_present = result.version_present,
        .bit_offset = result.bit_offset,
        .bit_entries = result.bit_entries,
        .dcb_offset = result.dcb_offset,
        .dcb_version = result.dcb_version,
        .ccb_version = result.ccb_version,
        .communications = result.communications[0..result.communication_count],
        .connector_version = result.connector_version,
        .connectors = result.connectors[0..result.connector_count],
        .gpio = if (result.gpio_table) |*gpio| .{
            .offset = gpio.offset, .version = gpio.version, .header_bytes = gpio.header_bytes,
            .entry_bytes = gpio.entry_bytes, .byte_length = gpio.byte_length,
            .external_table_offset = gpio.external_table_offset,
            .external_table_resolved = false,
            .entries = gpio_entries[0..gpio.count], .hpd = &gpio.hpd,
        } else null,
        .topology_state = "VBIOS-wiring-only; live HPD, active routing and receiver data unknown",
        .ports = result.ports[0..result.port_count],
        .fwsec = .{
            .catalog_parsed = catalog != null,
            .rejection = fwsec_error,
            .firmware_ready = false,
            .signature_cryptographically_verified = false,
            .variant_selected = false,
            .fuse_version_measured = false,
            .entries = entries[0..if (catalog) |value| value.count else 0],
        },
    };
    const json = try std.json.Stringify.valueAlloc(init.gpa, report, .{ .whitespace = .indent_2 });
    defer init.gpa.free(json);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = json });
    std.debug.print("NVIDIA VBIOS: parsed images={d} ports={d}; supplied file, hardware unverified.\n", .{ result.image_count, result.port_count });
}
