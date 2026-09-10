//! Bounded CPU encoder of NVIDIA's three-level, 4-KB Libos radix format.
//! The caller owns a retained DMA mapping of the COMPLETE output allocation.
//! Segment addresses are device addresses, never CPU pointers. Encoding neither
//! maps memory nor synchronizes/submits it; the owner must do that afterwards.
//! Format: pinned libos_init_args.h and kgspCreateRadix3_IMPL, RM 570.144.
const std = @import("std");
const firmware = @import("firmware.zig");
const boot = @import("gsp_boot.zig");
pub const page_bytes: usize = 4096;
pub const entries_per_page: usize = page_bytes / 8;
pub const max_segments: usize = 256;
// Conservative Falcon DMA limit also used by the FWSEC load planner.
pub const dma_mask = @import("fwsec_load.zig").dma_mask;
pub const Error = error{ ImageSize, Capacity, Segments, Address, Alignment, Overlap };
pub const Segment = struct { address: u64, bytes: u64 };
pub const Level = struct { pages: usize, offset: usize };
pub const Requirements = struct {
    image_bytes: usize,
    levels: [4]Level,
    table_bytes: usize,
    allocation_bytes: usize,
};

pub fn requirements(image_bytes: usize) Error!Requirements {
    _ = boot.source_path; // The format belongs to the central firmware pin.
    if (image_bytes == 0 or image_bytes > firmware.max_bytes) return error.ImageSize;
    var levels: [4]Level = @splat(.{ .pages = 0, .offset = 0 });
    levels[3].pages = (image_bytes + page_bytes - 1) / page_bytes;
    var index: usize = 3;
    while (index > 0) : (index -= 1) levels[index - 1].pages = (levels[index].pages + entries_per_page - 1) / entries_per_page;
    // The image-size limit above makes every product/sum bounded, including
    // on a 32-bit host; there is always exactly one root page.
    for (1..levels.len) |i| levels[i].offset = levels[i - 1].offset + levels[i - 1].pages * page_bytes;
    return .{
        .image_bytes = image_bytes,
        .levels = levels,
        .table_bytes = levels[3].offset,
        .allocation_bytes = levels[3].offset + levels[3].pages * page_bytes,
    };
}

fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const aa = @intFromPtr(a.ptr);
    const bb = @intFromPtr(b.ptr);
    return if (aa <= bb) bb - aa < a.len else aa - bb < b.len;
}

const Cursor = struct {
    segments: []const Segment,
    index: usize = 0,
    offset: u64 = 0,
    // Calls advance through validated logical allocation offsets. Segment
    // addresses themselves may be unordered and physically discontinuous.
    fn address(self: *@This(), logical: usize) u64 {
        while (logical - self.offset >= self.segments[self.index].bytes) {
            self.offset += self.segments[self.index].bytes;
            self.index += 1;
        }
        return self.segments[self.index].address + logical - self.offset;
    }
};

/// The caller supplies admitted immutable .fwimage bytes, separate writable
/// backing and the actual mapping's logical-order segments (including tables).
/// Every failure leaves output unchanged. Zero padding covers all unused PTEs
/// and the final data page. Returns the actual root DMA address, not a grant
/// to execute or release any mapping while firmware might still access it.
pub fn encode(image: []const u8, segments: []const Segment, output: []u8) Error!u64 {
    const need = try requirements(image.len);
    if (output.len != need.allocation_bytes) return error.Capacity;
    if (segments.len == 0 or segments.len > max_segments) return error.Segments;
    if (overlaps(image, output) or overlaps(std.mem.sliceAsBytes(segments), output)) return error.Overlap;
    var covered: u64 = 0;
    for (segments, 0..) |segment, index| {
        if (segment.address == 0 or segment.address > dma_mask or segment.bytes == 0 or
            segment.bytes - 1 > dma_mask - segment.address) return error.Address;
        if ((segment.address | segment.bytes) & (page_bytes - 1) != 0) return error.Alignment;
        if (segment.bytes > need.allocation_bytes - covered) return error.Capacity;
        covered += segment.bytes;
        for (segments[0..index]) |previous| {
            if (segment.address < previous.address + previous.bytes and previous.address < segment.address + segment.bytes)
                return error.Overlap;
        }
    }
    if (covered != need.allocation_bytes) return error.Capacity;
    // From here all counts, ranges, aliasing and device addresses are valid.
    @memset(output[0..need.table_bytes], 0);
    @memset(output[need.table_bytes + image.len ..], 0);
    var cursor = Cursor{ .segments = segments };
    for (0..3) |level| {
        const next = need.levels[level + 1];
        for (0..next.pages) |page| {
            const offset = need.levels[level].offset + page * 8;
            std.mem.writeInt(u64, output[offset..][0..8], cursor.address(next.offset + page * page_bytes), .little);
        }
    }
    @memcpy(output[need.table_bytes..][0..image.len], image);
    return segments[0].address;
}
