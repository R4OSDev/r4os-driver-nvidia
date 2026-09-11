//! Resident display instance and VRAM cursor/LUT payload backup; used ISO spans.
//! No native display programming. Preserve every instance byte, including
//! opaque unused objects; decoded ranges constrain GSP VRAM reservations.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const boot = @import("boot_vram.zig");
const scanout = @import("boot_scanout.zig");
const decoder = @import("display_context.zig");
const reader = @import("bar1_reader.zig");
const layout = @import("gsp_layout.zig");
const asset_decoder = @import("display_assets.zig");
const pramin = @import("pramin.zig");
pub const max_surfaces = scanout.max_windows * 6;
pub const Surface = struct { window: u8, plane: u2, eye: u1, handle: u32, context: decoder.Resolved, image: decoder.Surface };
pub const Report = struct { address: u64, bytes: u64, surfaces: usize, sha256: [32]u8, window_writes: u32,
    assets: usize, asset_bytes: usize, asset_sha256: [32]u8 };
pub const Capture = struct {
    self_address: usize = 0,
    parent: ?*boot.Capture = null,
    epoch: u64 = 0,
    memory: ?r4os.driver_memory.Context = null,
    io: reader.Reader = .{},
    reference: a.GfxBufferReference = .{},
    map: a.GfxBufferMap = .{},
    stamp: a.GfxBufferMap = .{},
    span: decoder.Span = .{ .address = 0, .bytes = 0 },
    framebuffer_bytes: u64 = 0,
    surfaces: [max_surfaces]Surface = undefined,
    surface_count: usize = 0,
    asset_catalog: asset_decoder.Catalog = .{},
    asset_reference: a.GfxBufferReference = .{},
    asset_map: a.GfxBufferMap = .{},
    asset_stamp: a.GfxBufferMap = .{},
    scratch: [4096]u8 = undefined,
    ready: bool = false,
    last_status: i32 = 0,

    pub fn capture(self: *Capture, parent: *boot.Capture) !Report {
        if (self.self_address != 0) return error.Busy;
        if (parent.context_owner != 0 or parent.borrower != 0 or parent.self_address != @intFromPtr(parent) or !parent.ready) return error.Owner;
        self.self_address = @intFromPtr(self);
        self.parent = parent;
        self.epoch = parent.boot.held_generation;
        self.memory = parent.memory;
        parent.context_owner = self.self_address;
        try self.io.open(parent);
        self.framebuffer_bytes = self.io.framebuffer_bytes;
        const raw = &parent.scanout_original.?;
        self.span = try decoder.instance(raw.instance_control, raw.instance_address, self.framebuffer_bytes);
        self.last_status = self.memory.?.bufferCreate(&.{ .byte_length = decoder.instance_bytes, .alignment = 4096, .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write }, &self.reference);
        if (self.last_status != a.gfx_buffer_result_ok) return error.Buffer;
        try self.mapBackup(a.gfx_buffer_map_write);
        for (0..decoder.instance_bytes / 4096) |page| {
            const output: [*]u8 = @ptrFromInt(self.map.cpu_address);
            try self.io.read(self.span.address + page * 4096, output[page * 4096 ..][0..4096]);
        }
        try self.comparePages();
        try self.resolveSurfaces(raw);
        try self.asset_catalog.resolve(raw, self.data(), self.framebuffer_bytes);
        // Resolve all targets before any asset payload read. GPU system
        // addresses are not CPU pointers and this reader only admits VRAM.
        for (self.asset_catalog.items[0..self.asset_catalog.count]) |*asset|
            if (asset.memory.target != .vram) return error.AssetSystemMemory;
        if (self.asset_catalog.bytes != 0) {
            self.last_status = self.memory.?.bufferCreate(&.{ .byte_length = self.asset_catalog.bytes, .alignment = 4096,
                .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write }, &self.asset_reference);
            if (self.last_status != a.gfx_buffer_result_ok) return error.Buffer;
            try self.mapAssets(a.gfx_buffer_map_write);
            try self.transferAssets(false);
            try self.transferAssets(true);
        }
        try self.comparePages(); // Bindings must remain identical across payload capture too.
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.data(), &digest, .{});
        var asset_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.assetData(), &asset_digest, .{});
        const writes = self.io.window_writes;
        if (!self.io.close()) return error.Cleanup;
        _ = try parent.reobserve();
        self.last_status = self.memory.?.bufferUnmap(&self.map.lease);
        if (self.last_status != a.gfx_buffer_result_ok) return error.Buffer;
        self.map = .{};
        self.stamp = .{};
        try self.mapBackup(a.gfx_buffer_map_read);
        if (self.asset_catalog.bytes != 0) {
            if (!self.unmapAssets()) return error.Buffer;
            try self.mapAssets(a.gfx_buffer_map_read);
        }
        self.ready = true;
        return .{ .address = self.span.address, .bytes = self.span.bytes, .surfaces = self.surface_count, .sha256 = digest, .window_writes = writes,
            .assets = self.asset_catalog.count, .asset_bytes = self.asset_catalog.bytes, .asset_sha256 = asset_digest };
    }
    pub fn assetData(self: *const Capture) []const u8 {
        if (self.asset_catalog.bytes == 0) return &.{};
        const bytes: [*]const u8 = @ptrFromInt(self.asset_map.cpu_address);
        return bytes[0..self.asset_catalog.bytes];
    }
    fn mapAssets(self: *Capture, access: u32) !void {
        self.last_status = self.memory.?.bufferMap(&self.asset_reference.reference, access, 0, self.asset_catalog.bytes, &self.asset_map);
        self.asset_stamp = self.asset_map;
        if (self.last_status != a.gfx_buffer_result_ok or self.asset_map.lease.id == 0 or self.asset_map.cpu_address == 0 or
            self.asset_map.byte_length != self.asset_catalog.bytes or self.asset_map.cpu_address > std.math.maxInt(u64) - self.asset_catalog.bytes) return error.Buffer;
    }
    fn unmapAssets(self: *Capture) bool {
        if (!std.meta.eql(self.asset_map, self.asset_stamp)) return false;
        if (self.asset_map.lease.id != 0) {
            self.last_status = self.memory.?.bufferUnmap(&self.asset_map.lease);
            if (self.last_status != a.gfx_buffer_result_ok) return false;
            self.asset_map = .{};
            self.asset_stamp = .{};
        }
        return true;
    }
    fn transferAssets(self: *Capture, compare: bool) !void {
        for (self.asset_catalog.items[0..self.asset_catalog.count]) |*asset| {
            if (asset.memory.target != .vram) return error.AssetSystemMemory;
            var offset: usize = 0;
            while (offset < asset.memory.span.bytes) {
                const address = asset.memory.span.address + offset;
                // LUTs can start only 256-byte aligned, including 256 bytes
                // before the aperture edge. Never cross that edge in one read.
                const count: usize = @intCast(@min(self.scratch.len, asset.memory.span.bytes - offset,
                    pramin.aperture_bytes - (address & (pramin.aperture_bytes - 1))));
                const start = asset.backup_offset + offset;
                try self.io.read(address, self.scratch[0..count]);
                if (compare) {
                    if (!std.mem.eql(u8, self.scratch[0..count], self.assetData()[start..][0..count])) return error.AssetChanged;
                } else {
                    const output: [*]u8 = @ptrFromInt(self.asset_map.cpu_address);
                    @memcpy(output[start..][0..count], self.scratch[0..count]);
                }
                offset += count;
            }
        }
    }
    fn data(self: *const Capture) []const u8 {
        const bytes: [*]const u8 = @ptrFromInt(self.map.cpu_address);
        return bytes[0..decoder.instance_bytes];
    }
    fn mapBackup(self: *Capture, access: u32) !void {
        self.last_status = self.memory.?.bufferMap(&self.reference.reference, access, 0, decoder.instance_bytes, &self.map);
        self.stamp = self.map;
        if (self.last_status != a.gfx_buffer_result_ok or self.map.lease.id == 0 or self.map.cpu_address == 0 or
            self.map.byte_length != decoder.instance_bytes or self.map.cpu_address > std.math.maxInt(u64) - decoder.instance_bytes) return error.Buffer;
    }
    fn comparePages(self: *Capture) !void {
        for (0..decoder.instance_bytes / 4096) |page| {
            try self.io.read(self.span.address + page * 4096, &self.scratch);
            if (!std.mem.eql(u8, &self.scratch, self.data()[page * 4096 ..][0..4096])) return error.Unstable;
        }
    }
    fn resolveSurfaces(self: *Capture, raw: *const scanout.Raw) !void {
        for (0..scanout.max_windows) |index| {
            if (raw.window_mask & (@as(u32, 1) << @intCast(index)) == 0) continue;
            const window = &raw.windows[index];
            if (try scanout.windowHead(window) == null) continue;
            if (window.client & ~@as(u32, 0x3fff) != 0) return error.Context;
            const eye_count = try decoder.eyes(window.get(.present));
            // Mono can leave arbitrary old right-eye words, sometimes handle1.
            const left = try window.binding(0, 0);
            if (left.handle == 0) {
                if (eye_count == 2 and (try window.binding(0, 1)).handle != 0) return error.Context;
                continue;
            }
            const pixel_format = try decoder.format(@truncate(window.get(.params)));
            const size = window.dimensions(.size);
            const input = window.dimensions(.input);
            if (pixel_format.count > 1 and pixel_format.planes[1].y == 2 and input.y & 1 != 0) return error.Geometry;
            for (0..eye_count) |eye| {
                const point = window.dimensions(if (eye == 0) .point_left else .point_right);
                if (input.x == 0 or input.y == 0 or @as(u32, point.x) + input.x > size.x or
                    @as(u32, point.y) + input.y > size.y) return error.Geometry;
                for (0..pixel_format.count) |plane| {
                    const bound = try window.binding(@intCast(plane), @intCast(eye));
                    const ctx = try decoder.lookup(self.data(), @intCast(window.client), bound.handle, @intCast(1 + index));
                    const image = try decoder.surface(ctx.descriptor, bound.offset_bytes, size.x, size.y, window.words[@intFromEnum(scanout.WindowField.pitch0) + plane], window.get(.storage), pixel_format, @intCast(plane), self.framebuffer_bytes);
                    self.surfaces[self.surface_count] = .{ .window = @intCast(index), .plane = @intCast(plane), .eye = @intCast(eye), .handle = bound.handle, .context = ctx, .image = image };
                    self.surface_count += 1;
                }
            }
        }
    }
    pub fn valid(self: *const Capture, parent: *const boot.Capture) bool {
        const assets_valid = if (self.asset_catalog.bytes == 0)
            self.asset_catalog.count == 0 and self.asset_reference.reference.id == 0 and self.asset_map.lease.id == 0
        else self.asset_catalog.count > 0 and self.asset_catalog.count <= asset_decoder.max_assets and
            self.asset_catalog.bytes <= asset_decoder.max_payload_bytes and self.asset_reference.reference.id != 0 and
            self.asset_map.lease.id != 0 and self.asset_map.cpu_address != 0 and self.asset_map.byte_length == self.asset_catalog.bytes;
        return self.self_address == @intFromPtr(self) and self.ready and self.parent == parent and
            parent.self_address == @intFromPtr(parent) and parent.ready and parent.context_owner == self.self_address and
            parent.boot.held_generation == self.epoch and self.epoch != 0 and self.io.self_address == 0 and
            self.reference.reference.id != 0 and self.map.lease.id != 0 and std.meta.eql(self.map, self.stamp) and
            assets_valid and std.meta.eql(self.asset_map, self.asset_stamp);
    }
    fn overlaps(span: decoder.Span, reserved: layout.Range) bool {
        return span.address < reserved.end() and reserved.offset < span.address + span.bytes;
    }
    fn reobserve(self: *Capture, parent: *boot.Capture) !void {
        try self.io.open(parent);
        try self.comparePages();
        try self.transferAssets(true);
        try self.comparePages();
        if (!self.io.close()) return error.Cleanup;
        _ = try parent.reobserve();
    }
    pub fn admit(self: *Capture, parent: *boot.Capture, plan: *const layout.Plan) !void {
        if (!self.valid(parent)) return error.ContextOwner;
        if (self.framebuffer_bytes != plan.fb_bytes) return error.PlanChanged;
        if (overlaps(self.span, plan.reserved)) return error.DisplayContextCollision;
        for (self.surfaces[0..self.surface_count]) |*surface|
            if (overlaps(surface.image.span, plan.reserved)) return error.DisplaySurfaceCollision;
        for (self.asset_catalog.items[0..self.asset_catalog.count]) |*asset| {
            if (asset.memory.target != .vram) return error.AssetSystemMemory;
            if (overlaps(asset.memory.span, plan.reserved)) return error.DisplayAssetCollision;
        }
        self.reobserve(parent) catch |err| {
            if (!self.io.close()) return error.Cleanup;
            return err;
        };
    }
    pub fn close(self: *Capture) bool {
        if (self.self_address == 0) return true;
        const parent = self.parent orelse return false;
        if (self.self_address != @intFromPtr(self) or parent.self_address != @intFromPtr(parent) or
            parent.context_owner != self.self_address or parent.borrower != 0 or parent.boot.held_generation != self.epoch) return false;
        if (!self.io.close() or !std.meta.eql(self.map, self.stamp) or !self.unmapAssets()) return false;
        if (self.asset_reference.reference.id != 0) {
            self.last_status = self.memory.?.bufferRelease(&self.asset_reference.reference);
            if (self.last_status != a.gfx_buffer_result_ok) return false;
            self.asset_reference = .{};
        }
        if (self.map.lease.id != 0) {
            self.last_status = self.memory.?.bufferUnmap(&self.map.lease);
            if (self.last_status != a.gfx_buffer_result_ok) return false;
            self.map = .{};
            self.stamp = .{};
        }
        if (self.reference.reference.id != 0) {
            self.last_status = self.memory.?.bufferRelease(&self.reference.reference);
            if (self.last_status != a.gfx_buffer_result_ok) return false;
            self.reference = .{};
        }
        parent.context_owner = 0;
        self.* = .{};
        return true;
    }
};
