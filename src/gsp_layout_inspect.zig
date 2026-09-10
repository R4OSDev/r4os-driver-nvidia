const std = @import("std");
const firmware = @import("firmware.zig");
const boot = @import("gsp_boot.zig");
const layout = @import("gsp_layout.zig");
const radix = @import("gsp_radix.zig");
const preflight = @import("fwsec_state.zig");
const identity = @import("identity.zig");

const Snapshot = struct {
    schema: u32,
    recorded_utc: []const u8,
    pci_vendor: u16,
    pci_device: u16,
    pmc_boot0: u32,
    pmc_boot1: u32,
    raw: preflight.Raw,
};

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

fn read(init: std.process.Init, path: []const u8, maximum: usize, exact: ?usize) ![]u8 {
    const start = now(init.io);
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    const stat = try file.stat(init.io);
    if (stat.kind != .file or stat.size == 0 or stat.size > maximum) return error.WrongSize;
    if (exact) |bytes| if (stat.size != bytes) return error.WrongSize;
    const storage = try init.gpa.alloc(u8, @intCast(stat.size));
    errdefer init.gpa.free(storage);
    var position: usize = 0;
    while (position < storage.len) {
        // Regular host files: elapsed time checked around each read, without
        // claiming cancellation of a blocked host I/O operation.
        const before = now(init.io);
        if (before < start) return error.ClockRegression;
        if (before - start >= 30 * std.time.ns_per_s) return error.Timeout;
        const chunk = storage[position..@min(storage.len, position + firmware.read_chunk_bytes)];
        if (try file.readPositionalAll(init.io, chunk, position) != chunk.len) return error.ShortRead;
        const after = now(init.io);
        if (after < before) return error.ClockRegression;
        if (after - start >= 30 * std.time.ns_per_s) return error.Timeout;
        position += chunk.len;
    }
    if ((try file.stat(init.io)).size != stat.size) return error.WrongSize;
    return storage;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 6) {
        std.debug.print("Usage: nvgsp-layout PREFLIGHT.json GSP.bin BOOT.bin DESC.bin OUTPUT.json\n", .{});
        return error.Arguments;
    }
    const snapshot_bytes = try read(init, args[1], 16384, null);
    defer init.gpa.free(snapshot_bytes);
    const parsed = try std.json.parseFromSlice(Snapshot, init.gpa, snapshot_bytes, .{});
    defer parsed.deinit();
    const snapshot = parsed.value;
    if (snapshot.schema != 1 or snapshot.recorded_utc.len == 0 or snapshot.recorded_utc.len > 64 or
        snapshot.pci_vendor != 0x10de or snapshot.pci_device != 0x2504) return error.Snapshot;
    const chip = identity.chip(snapshot.pmc_boot0, snapshot.pmc_boot1) orelse return error.UnsupportedChip;
    const boot_bytes = try read(init, args[3], boot.image.bytes, boot.image.bytes);
    defer init.gpa.free(boot_bytes);
    const desc_bytes = try read(init, args[4], boot.descriptor.bytes, boot.descriptor.bytes);
    defer init.gpa.free(desc_bytes);
    const boot_info = try boot.verify(boot_bytes, desc_bytes);
    const spec = firmware.specification(.ga10x);
    const firmware_bytes = try read(init, args[2], spec.bytes, spec.bytes);
    defer init.gpa.free(firmware_bytes);
    const verified = try firmware.verify(firmware_bytes, .ga10x);
    const plan = try layout.firstBoot(chip.id, &snapshot.raw, verified.layout.image.bytes, boot_info.image_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(snapshot_bytes, &digest, .{});
    const snapshot_hash = std.fmt.bytesToHex(digest, .lower);
    const report = .{
        .schema = 1,
        .source = "supplied-files-and-recorded-observation",
        .rm_version = firmware.lock.rm_version,
        .source_commit = firmware.lock.source_commit,
        .snapshot_sha256 = snapshot_hash[0..],
        .snapshot = snapshot,
        .profile = "ga106-bare-metal-first-boot-no-overrides",
        .container_sha256 = spec.sha256,
        .firmware_section = verified.layout.image,
        .signature_section = verified.layout.signature,
        .boot_image_sha256 = boot.image.sha256,
        .boot_descriptor_sha256 = boot.descriptor.sha256,
        .hashes_verified = true,
        .boot_descriptor = boot_info,
        .plan = plan,
        .radix3 = try radix.requirements(verified.layout.image.bytes),
        .metadata_bytes = layout.metadata_bytes,
        .wpr_end_margin = 0,
        .boost_clocks = false,
        .live_hardware_read = false,
        .vram_reserved = false,
        .vga_relocated = false,
        .dma_addresses_assigned = false,
        .signature_cryptographically_verified = false,
        .native_initialization_authorized = false,
    };
    const json = try std.json.Stringify.valueAlloc(init.gpa, report, .{ .whitespace = .indent_2 });
    defer init.gpa.free(json);
    const output = try std.Io.Dir.cwd().createFile(init.io, args[5], .{ .exclusive = true });
    errdefer std.Io.Dir.cwd().deleteFile(init.io, args[5]) catch {};
    defer output.close(init.io);
    var buffer: [4096]u8 = undefined;
    var writer = output.writer(init.io, &buffer);
    try writer.interface.writeAll(json);
    try writer.interface.flush();
    std.debug.print("GSP layout: FB={d} MB heap={d} MB reserved={d} MB VGA-relocation={}; CPU plan only.\n", .{
        plan.fb_bytes / layout.mb, plan.heap.bytes / layout.mb, plan.reserved.bytes / layout.mb, plan.vga_relocation_required,
    });
}
