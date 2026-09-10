const std = @import("std");
const vbios = @import("vbios.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 4 or std.mem.eql(u8, args[1], args[2])) {
        std.debug.print("Usage: nvbios-inspect INPUT.rom OUTPUT.json [PCI-device-hex]\n", .{});
        return error.Arguments;
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(vbios.max_rom_bytes));
    defer init.gpa.free(rom);
    const expected: ?u16 = if (args.len == 4) try std.fmt.parseInt(u16, args[3], 16) else null;
    const result = vbios.parse(rom, expected) catch |err| {
        std.debug.print("NVIDIA VBIOS rejected: {s}; no report published.\n", .{@errorName(err)});
        return err;
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rom, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const report = .{
        .schema = 1,
        .source = "supplied-file",
        .sha256 = digest_hex[0..],
        .hardware_verified = false,
        .native_initialization_authorized = false,
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
        .ports = result.ports[0..result.port_count],
    };
    const json = try std.json.Stringify.valueAlloc(init.gpa, report, .{ .whitespace = .indent_2 });
    defer init.gpa.free(json);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = json });
    std.debug.print("NVIDIA VBIOS: parsed images={d} ports={d}; supplied file, hardware unverified.\n", .{ result.image_count, result.port_count });
}
