const std = @import("std");
const fw = @import("firmware.zig");

const Reader = struct {
    file: std.Io.File,
    io: std.Io,
    resource: []const u8,
    reads: usize = 0,
    largest_read: usize = 0,

    pub fn nowNs(self: *@This()) u64 {
        return @intCast(std.Io.Clock.awake.now(self.io).toNanoseconds());
    }

    pub fn readAt(self: *@This(), resource: []const u8, offset: usize, out: []u8, deadline_ns: u64) !usize {
        if (!std.mem.eql(u8, resource, self.resource)) return error.WrongResource;
        if (self.nowNs() >= deadline_ns) return error.Timeout;
        self.reads += 1;
        self.largest_read = @max(self.largest_read, out.len);
        // Host regular-file reads: deadline checked on both sides by Load;
        // this is not an assertion of OS-level cancellation during a read.
        return self.file.readPositionalAll(self.io, out, offset);
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4 or std.mem.eql(u8, args[1], args[3])) {
        std.debug.print("Usage: nvfirmware-inspect INPUT.bin FAMILY OUTPUT.json\n", .{});
        return error.Arguments;
    }
    const family = std.meta.stringToEnum(fw.Family, args[2]) orelse return error.UnknownFamily;
    const spec = fw.specification(family);
    const file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    const stat = try file.stat(init.io);
    if (stat.kind != .file or stat.size != spec.bytes) return error.WrongSize;
    const storage = try init.gpa.alloc(u8, spec.bytes);
    defer init.gpa.free(storage);
    var reader = Reader{ .file = file, .io = init.io, .resource = spec.resource };
    var load = try fw.Load.begin(family, storage, reader.nowNs(), 30 * std.time.ns_per_s);
    defer load.close();
    while (load.state == .reading) {
        _ = load.step(&reader) catch |err| {
            std.debug.print("NVIDIA firmware rejected: {s}; no report published.\n", .{@errorName(err)});
            return err;
        };
    }
    const verified = load.ready() orelse return error.NotReady;
    var signatures: [8]struct { family: []const u8, offset: usize, bytes: usize } = undefined;
    var signature_count: usize = 0;
    for (fw.lock.families) |binding| {
        if (!std.mem.eql(u8, fw.lock.firmware[binding.artifact].file, spec.file)) continue;
        const layout = try fw.inspect(verified.container, std.meta.stringToEnum(fw.Family, binding.name).?);
        signatures[signature_count] = .{ .family = binding.name, .offset = layout.signature.offset, .bytes = layout.signature.bytes };
        signature_count += 1;
    }
    const report = .{
        .schema = 1,
        .source = "supplied-file",
        .rm_version = fw.lock.rm_version,
        .source_commit = fw.lock.source_commit,
        .resource = spec.resource,
        .bytes = storage.len,
        .sha256 = spec.sha256,
        .hash_verified = true,
        .container = "ELF64/LE/ET_REL/EM_RISCV",
        .family = @tagName(family),
        .layout = verified.layout,
        .family_signatures = signatures[0..signature_count],
        .signature_cryptographically_verified = false,
        .hardware_verified = false,
        .native_initialization_authorized = false,
        .reads = reader.reads,
        .max_read_bytes = reader.largest_read,
        .deadline_scope = "before-and-after-host-file-reads",
    };
    const json = try std.json.Stringify.valueAlloc(init.gpa, report, .{ .whitespace = .indent_2 });
    defer init.gpa.free(json);
    // Exclusive creation avoids replacing a source file through a path alias,
    // overwriting a previous success report or leaving an old report ambiguous.
    const out = try std.Io.Dir.cwd().createFile(init.io, args[3], .{ .exclusive = true });
    errdefer std.Io.Dir.cwd().deleteFile(init.io, args[3]) catch {};
    defer out.close(init.io);
    var out_buffer: [4096]u8 = undefined;
    var writer = out.writer(init.io, &out_buffer);
    try writer.interface.writeAll(json);
    try writer.interface.flush();
    std.debug.print("NVIDIA firmware: verified package={s} family={s} bytes={d} reads={d}; GPU untested.\n", .{ fw.lock.rm_version, @tagName(family), storage.len, reader.reads });
}
