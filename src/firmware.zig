//! Original package admission code, not a replacement for NVIDIA RM's loader.
//! Every returned range borrows the caller's complete, unchanged ELF buffer.
//! Hash/format admission never authorizes GPU writes or verifies GPU signatures.
const std = @import("std");

pub const Artifact = struct {
    file: []const u8,
    resource: []const u8,
    bytes: usize,
    sha256: []const u8,
};
pub const Firmware = struct {
    file: []const u8,
    resource: []const u8,
    bytes: usize,
    sha256: []const u8,
};
pub const Lock = struct {
    schema: u32,
    rm_version: []const u8,
    source_commit: []const u8,
    package_url: []const u8,
    package_sha256: []const u8,
    license: Artifact,
    firmware: [2]Firmware,
    families: [8]struct { name: []const u8, artifact: usize },
    boot: struct {
        source: Source,
        image: Artifact,
        descriptor: Artifact,
        license: Artifact,
        notices: [12]Source,
    },
};
pub const Source = struct { path: []const u8, bytes: usize, sha256: []const u8 };
pub const lock: Lock = blk: {
    @setEvalBranchQuota(500000);
    var storage: [32768]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    break :blk std.json.parseFromSliceLeaky(Lock, allocator.allocator(), @embedFile("firmware-lock.json"), .{}) catch
        @compileError("invalid NVIDIA firmware lock");
};
pub const max_bytes = 64 * 1024 * 1024;
pub const read_chunk_bytes = 64 * 1024;
pub const max_sections = 64;
pub const max_names_bytes = 4096;
pub const signature_bytes = 4096;
pub const Family = enum { tu10x, tu11x, ga100, ga10x, ad10x, gh100, gb10x, gb20x };

// This is NVIDIA's container-family mapping, not a hardware support list.
pub fn specification(family: Family) *const Firmware {
    for (lock.families) |binding| {
        if (std.mem.eql(u8, binding.name, @tagName(family))) return &lock.firmware[binding.artifact];
    }
    unreachable; // All enum values are checked against the lock at compile time.
}

comptime {
    if (lock.schema != 1 or lock.firmware.len != 2 or lock.rm_version.len == 0 or lock.rm_version.len >= 63)
        @compileError("unsupported firmware lock schema");
    for (std.meta.fields(Family)) |field| {
        var count: usize = 0;
        for (lock.firmware) |candidate| {
            if (candidate.bytes == 0 or candidate.bytes > max_bytes or candidate.sha256.len != 64)
                @compileError("invalid firmware size/hash");
        }
        for (lock.families) |binding| {
            if (binding.artifact >= lock.firmware.len) @compileError("invalid firmware artifact binding");
            if (std.mem.eql(u8, field.name, binding.name)) count += 1;
        }
        if (count != 1) @compileError("missing or ambiguous firmware family");
    }
}

pub const Error = error{
    WrongSize,
    WrongHash,
    BadHeader,
    UnsupportedElf,
    BadSectionTable,
    BadSection,
    BadNames,
    DuplicateName,
    Overlap,
    MissingImage,
    MissingVersion,
    WrongVersion,
    MissingSignature,
    BadSignature,
    BadState,
    InvalidDeadline,
    Timeout,
    ClockRegression,
    ReadFailed,
    ShortRead,
};
pub const Range = struct {
    offset: usize,
    bytes: usize,

    pub fn slice(self: Range, container: []const u8) []const u8 {
        return container[self.offset .. self.offset + self.bytes];
    }

    fn overlaps(self: Range, other: Range) bool {
        return self.bytes != 0 and other.bytes != 0 and
            self.offset < other.offset + other.bytes and other.offset < self.offset + self.bytes;
    }
};
pub const Layout = struct { image: Range, version: Range, signature: Range, sections: usize };
pub const Verified = struct {
    container: []const u8,
    family: Family,
    layout: Layout,
};

pub fn digestMatches(data: []const u8, expected_hex: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return hashMatches(digest, expected_hex);
}

fn hashMatches(digest: [32]u8, expected_hex: []const u8) bool {
    const actual = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &actual, expected_hex);
}

pub fn verify(container: []const u8, family: Family) Error!Verified {
    const spec = specification(family);
    if (container.len != spec.bytes) return error.WrongSize;
    if (!digestMatches(container, spec.sha256)) return error.WrongHash;
    return .{ .container = container, .family = family, .layout = try inspect(container, family) };
}

const Section = struct { name: []const u8, data: Range, kind: u32, flags: u64 };

/// Structural inspection only. Call verify or Load before handing bytes to RM.
/// Bounded ELF64/LE/ET_REL/EM_RISCV profile of the locked release. Firmware
/// opcodes and signature contents remain opaque and are never executed here.
pub fn inspect(container: []const u8, family: Family) Error!Layout {
    if (container.len < 64 or container.len > max_bytes) return error.BadHeader;
    if (!std.mem.eql(u8, container[0..7], "\x7fELF\x02\x01\x01")) return error.UnsupportedElf;
    if (!allZero(container[7..16]) or u16At(container, 16) != 1 or u16At(container, 18) != 243 or
        u32At(container, 20) != 1 or u64At(container, 24) != 0 or u64At(container, 32) != 0 or
        u32At(container, 48) != 0 or u16At(container, 52) != 64 or u16At(container, 54) != 0 or
        u16At(container, 56) != 0 or u16At(container, 58) != 64) return error.UnsupportedElf;
    const count: usize = u16At(container, 60);
    const names_index: usize = u16At(container, 62);
    if (count < 4 or count > max_sections or names_index == 0 or names_index >= count) return error.BadSectionTable;
    const table = try bounded(container.len, u64At(container, 40), count * 64);
    if (table.offset < 64 or table.offset & 7 != 0) return error.BadSectionTable;
    if (!allZero(container[table.offset .. table.offset + 64])) return error.BadSectionTable;
    const names_record = table.offset + names_index * 64;
    if (u32At(container, names_record + 4) != 3) return error.BadNames;
    const names_range = try bounded(container.len, u64At(container, names_record + 24), u64At(container, names_record + 32));
    if (names_range.bytes < 2 or names_range.bytes > max_names_bytes) return error.BadNames;
    const names = names_range.slice(container);
    if (names[0] != 0 or names[names.len - 1] != 0) return error.BadNames;

    var sections: [max_sections]Section = undefined;
    var image: ?Range = null;
    var version: ?Range = null;
    var signature: ?Range = null;
    var signature_name_storage: [64]u8 = undefined;
    const signature_name = std.fmt.bufPrint(&signature_name_storage, ".fwsignature_{s}", .{@tagName(family)}) catch unreachable;
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const record = table.offset + i * 64;
        const name = try sectionName(names, u32At(container, record));
        const section = Section{
            .name = name,
            .data = try bounded(container.len, u64At(container, record + 24), u64At(container, record + 32)),
            .kind = u32At(container, record + 4),
            .flags = u64At(container, record + 8),
        };
        // No SHT_NOBITS/compression/executable input in the pinned containers.
        if (section.kind != 1 and section.kind != 2 and section.kind != 3 and section.kind != 7) return error.BadSection;
        if (section.flags & ~@as(u64, 3) != 0 or u64At(container, record + 16) != 0) return error.BadSection;
        const alignment = u64At(container, record + 48);
        if (alignment != 0 and (!std.math.isPowerOfTwo(alignment) or section.data.offset % alignment != 0)) return error.BadSection;
        if (section.data.bytes == 0 or section.data.offset < 64 or section.data.overlaps(table)) return error.Overlap;
        for (sections[1..i]) |previous| {
            if (std.mem.eql(u8, previous.name, name)) return error.DuplicateName;
            if (previous.data.overlaps(section.data)) return error.Overlap;
        }
        sections[i] = section;
        if (std.mem.eql(u8, name, ".fwimage")) {
            if (section.kind != 1 or section.flags != 3) return error.BadSection;
            image = section.data;
        } else if (std.mem.eql(u8, name, ".fwversion")) {
            if (section.kind != 1 or section.flags != 0) return error.BadSection;
            const bytes = section.data.slice(container);
            if (bytes.len != lock.rm_version.len + 1 or bytes[bytes.len - 1] != 0 or
                !std.mem.eql(u8, bytes[0 .. bytes.len - 1], lock.rm_version)) return error.WrongVersion;
            version = section.data;
        } else if (std.mem.eql(u8, name, signature_name)) {
            if (section.kind != 1 or section.flags != 0 or section.data.bytes != signature_bytes) return error.BadSignature;
            signature = section.data;
        }
    }
    return .{
        .image = image orelse return error.MissingImage,
        .version = version orelse return error.MissingVersion,
        .signature = signature orelse return error.MissingSignature,
        .sections = count,
    };
}

fn bounded(total: usize, raw_offset: u64, raw_size: u64) Error!Range {
    if (raw_offset > total or raw_size > total - raw_offset) return error.BadSection;
    return .{ .offset = @intCast(raw_offset), .bytes = @intCast(raw_size) };
}

fn sectionName(names: []const u8, start: usize) Error![]const u8 {
    if (start == 0 or start >= names.len) return error.BadNames;
    const end = std.mem.indexOfScalar(u8, names[start..], 0) orelse return error.BadNames;
    if (end == 0 or end >= 64) return error.BadNames;
    const name = names[start .. start + end];
    for (name) |c| if (c < 0x21 or c > 0x7e) return error.BadNames;
    return name;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
fn u16At(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}
fn u32At(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}
fn u64At(bytes: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, bytes[off..][0..8], .little);
}

/// Caller owns storage, cancellation and file/driver lifetime. One step reads
/// at most 64 KB directly into its final buffer; only ready() exposes a verified
/// view. Reader.readAt(resource, offset, output, absolute_deadline_ns) must
/// honor that deadline in its I/O owner. Boundary checks cannot interrupt an
/// arbitrary blocking implementation. No DMA ownership exists at this stage.
pub const Load = struct {
    pub const State = enum { reading, ready, failed, closed };
    family: Family,
    storage: []u8,
    deadline_ns: u64,
    last_now: u64,
    filled: usize = 0,
    state: State = .reading,
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    layout: ?Layout = null,

    pub fn begin(family: Family, storage: []u8, now_ns: u64, timeout_ns: u64) Error!Load {
        if (storage.len != specification(family).bytes) return error.WrongSize;
        if (timeout_ns == 0) return error.InvalidDeadline;
        return .{
            .family = family,
            .storage = storage,
            .last_now = now_ns,
            .deadline_ns = std.math.add(u64, now_ns, timeout_ns) catch return error.InvalidDeadline,
        };
    }

    pub fn step(self: *Load, reader: anytype) Error!State {
        if (self.state != .reading) return error.BadState;
        errdefer {
            self.state = .failed;
            self.layout = null;
        }
        try self.checkClock(reader.nowNs());
        const end = self.filled + @min(read_chunk_bytes, self.storage.len - self.filled);
        const out = self.storage[self.filled..end];
        const spec = specification(self.family);
        const read = reader.readAt(spec.resource, self.filled, out, self.deadline_ns) catch return error.ReadFailed;
        try self.checkClock(reader.nowNs());
        if (read != out.len) return error.ShortRead;
        self.hash.update(out);
        self.filled = end;
        if (self.filled == self.storage.len) {
            var digest: [32]u8 = undefined;
            self.hash.final(&digest);
            if (!hashMatches(digest, spec.sha256)) return error.WrongHash;
            self.layout = try inspect(self.storage, self.family);
            try self.checkClock(reader.nowNs());
            self.state = .ready;
        }
        return self.state;
    }

    pub fn ready(self: *const Load) ?Verified {
        if (self.state != .ready) return null;
        return .{ .container = self.storage, .family = self.family, .layout = self.layout.? };
    }

    pub fn close(self: *Load) void {
        self.state = .closed;
        self.layout = null;
        self.storage = &.{};
    }

    fn checkClock(self: *Load, now: u64) Error!void {
        if (now < self.last_now) return error.ClockRegression;
        if (now >= self.deadline_ns) return error.Timeout;
        self.last_now = now;
    }
};
