//! Dynamic common-BO fixture for the actual Device external-PDB case.
//! Bus addresses and PF completion are a host model, never GPU evidence.
const std = @import("std");
const a = @import("r4os").abi;
const t = std.testing;
pub const Model = struct {
    const Node = struct {
        next: ?*Node = null,
        serial: u64,
        descriptor: a.GfxBufferDescriptor,
        data: [4096]u8 align(4096) = @splat(0xa5),
        cpu: bool = false,
        reference: bool = true,
        dma: ?a.GfxDeviceLease = null,
        fn handle(self: *const Node, kind: u64) a.GfxBufferHandle { return .{ .id = @intCast(0x58000000 + self.serial * 8 + kind), .generation = 1 }; }
        fn physical(self: *const Node) u64 { return 0x580000000 + self.serial * 8192; }
    };
    pub var enabled = false;
    pub var count: usize = 0;
    pub var allocated: usize = 0;
    pub var released: usize = 0;
    pub var defer_collection = false;
    pub var deferred_collects: usize = 0;
    var first: ?*Node = null;
    var serial: u64 = 0;
    pub fn reset(active: bool) void {
        // Host fixture disposal is not a production reset or a release proof.
        while (first) |node| { first = node.next; t.allocator.destroy(node); }
        enabled = active; count = 0; allocated = 0; released = 0; serial = 0;
        defer_collection = false; deferred_collects = 0;
    }
    fn find(handle: a.GfxBufferHandle, kind: u64) ?*Node {
        var node = first;
        while (node) |entry| : (node = entry.next) if (std.meta.eql(entry.handle(kind), handle)) return entry;
        return null;
    }
    pub fn owns(handle: a.GfxBufferHandle) bool { return handle.id >= 0x58000000 and handle.id < 0x59000000; }
    pub fn create(input: *const a.GfxBufferDescriptor, output: *a.GfxBufferReference) i32 {
        std.debug.assert(enabled and input.byte_length == 4096 and input.alignment == 4096);
        const node = t.allocator.create(Node) catch return a.gfx_buffer_error_oom;
        serial += 1;
        node.* = .{ .serial = serial, .descriptor = input.*, .next = first };
        first = node; count += 1; allocated += 1;
        output.* = .{ .buffer = node.handle(0), .reference = node.handle(1) };
        return a.gfx_buffer_result_ok;
    }
    pub fn describe(input: *const a.GfxBufferHandle, output: *a.GfxBufferDescriptor) i32 {
        const node = find(input.*, 1) orelse return a.gfx_buffer_error_stale;
        output.* = node.descriptor; return a.gfx_buffer_result_ok;
    }
    pub fn mapCpu(input: *const a.GfxBufferHandle, access: u32, offset: u64, bytes: u64, output: *a.GfxBufferMap) i32 {
        const node = find(input.*, 1) orelse return a.gfx_buffer_error_stale;
        std.debug.assert(!node.cpu and access == a.gfx_buffer_map_write and offset == 0 and bytes == 4096);
        node.cpu = true;
        output.* = .{ .lease = node.handle(2), .cpu_address = @intFromPtr(&node.data), .byte_length = 4096, .cache_policy = a.gfx_buffer_cache_write_back };
        return a.gfx_buffer_result_ok;
    }
    pub fn unmapCpu(input: *const a.GfxBufferHandle) i32 {
        const node = find(input.*, 2) orelse return a.gfx_buffer_error_stale;
        std.debug.assert(node.cpu); node.cpu = false; return a.gfx_buffer_result_ok;
    }
    pub fn acquire(input: *const a.GfxBufferHandle, request: *const a.GfxDeviceRequest, output: *a.GfxDeviceLease) i32 {
        const node = find(input.*, 1) orelse return a.gfx_buffer_error_stale;
        std.debug.assert(!node.cpu and node.dma == null and std.mem.allEqual(u8, &node.data, 0) and request.access == 4 and
            request.byte_offset == 0 and request.byte_length == 4096 and request.gpu_virtual_address == 0 and request.address_space == 0);
        output.* = .{ .lease = node.handle(3), .byte_length = 4096, .adapter_id = request.adapter_id, .driver_owner = 7,
            .device_generation = request.device_generation, .access = 4, .dma_mask = request.dma_mask };
        node.dma = output.*; return a.gfx_buffer_result_ok;
    }
    pub fn segment(input: *const a.GfxDeviceLease, offset: u64, output: *a.GfxDmaSegment) i32 {
        const node = find(input.lease, 3) orelse return a.gfx_buffer_error_stale;
        std.debug.assert(node.dma != null and std.meta.eql(input.*, node.dma.?) and offset == 0);
        output.* = .{ .dma_address = node.physical(), .byte_length = 4096, .next_offset = 4096 }; return a.gfx_buffer_result_ok;
    }
    pub fn releaseDevice(input: *const a.GfxDeviceLease, quiet: u32) i32 {
        const node = find(input.lease, 3) orelse return a.gfx_buffer_error_stale;
        std.debug.assert(!node.cpu and node.dma != null and std.meta.eql(input.*, node.dma.?) and quiet == 1);
        node.dma = null; return a.gfx_buffer_result_ok;
    }
    pub fn release(input: *const a.GfxBufferHandle) i32 {
        const node = find(input.*, 1) orelse return a.gfx_buffer_error_stale;
        std.debug.assert(node.reference and !node.cpu and node.dma == null);
        node.reference = false;
        if (!defer_collection) _ = collect(false);
        return a.gfx_buffer_result_ok;
    }
    pub fn collect(other_backing_pending: bool) i32 {
        if (defer_collection and other_backing_pending) {
            deferred_collects += 1;
            return a.gfx_buffer_error_busy;
        }
        var link = &first;
        while (link.*) |node| {
            if (node.reference) { link = &node.next; continue; }
            std.debug.assert(!node.cpu and node.dma == null);
            link.* = node.next;
            t.allocator.destroy(node); count -= 1; released += 1;
        }
        return a.gfx_buffer_result_ok;
    }
    fn physical(dma: u64) !*const [4096]u8 {
        var node = first;
        while (node) |entry| : (node = entry.next) if (entry.physical() == dma and entry.dma != null) return &entry.data;
        return error.MissingPage;
    }
    pub fn walk(root: u64, address: u64) !u64 {
        var data = try physical(root);
        const indices = [_]usize{ @intCast((address >> 47) & 3), @intCast((address >> 38) & 511),
            @intCast((address >> 29) & 511), @intCast(((address >> 21) & 255) * 2 + 1) };
        for (indices, 0..) |at, level| {
            const word = std.mem.readInt(u64, data[at * 8 ..][0..8], .little);
            if (word == 0) return 0;
            try t.expect(word & 255 == 12);
            if (level == 3) try t.expect(std.mem.readInt(u64, data[(at - 1) * 8 ..][0..8], .little) == 0);
            data = try physical((word & 0x003fffffffffff00) << 4);
        }
        const at: usize = @intCast((address >> 12) & 511);
        return std.mem.readInt(u64, data[at * 8 ..][0..8], .little);
    }
};
