//! Turn an authenticated surface plan into Copy Engine operands. Opaque
//! modifiers are interpreted only here, never as CPU-addressable pixels.
const std = @import("std");
const wire = @import("gsp_copy_wire.zig");
const surface = @import("gsp_surface_layout.zig");
const a = @import("r4os").abi;
pub const Operand = struct { address: u64, block: ?wire.Block = null };
pub fn operand(address: u64, logical_bytes: u64, offset: u64, bytes: u64, rows: ?wire.Rows, target: bool, plan: ?surface.Plan) !Operand {
    const transfer: wire.Transfer = .{ .source = address, .target = address, .bytes = bytes, .rows = rows };
    const linear_span = try transfer.span(target);
    if (offset > logical_bytes or linear_span > logical_bytes - offset) return error.Bounds;
    if (plan) |value| if (value.blocklinear()) {
        const geometry = rows orelse return error.Unsupported;
        const desc = value.descriptor;
        const pitch = if (target) geometry.target_pitch else geometry.source_pitch;
        if (desc.byte_length != logical_bytes or desc.location != a.gfx_buffer_location_device_local or
            desc.modifier != try surface.modifier(value.caps orelse return error.Unsupported, value.log2_gobs)) return error.Descriptor;
        const multi = desc.format == a.gfx_buffer_format_nv12 or desc.format == a.gfx_buffer_format_p010;
        for (0..desc.plane_count) |index| {
            if (offset < desc.plane_offsets[index] or pitch != desc.plane_pitches[index]) continue;
            const relative = offset - desc.plane_offsets[index];
            const x = relative % pitch;
            const y = relative / pitch;
            const height: u64 = if (multi and index == 1) (@as(u64, desc.height) + 1) / 2 else desc.height;
            if (y >= height or x + bytes > pitch or geometry.count > height - y) continue;
            const block: wire.Block = .{ .width = pitch, .height = @intCast(height), .x = @intCast(x), .y = @intCast(y), .log2_gobs = value.log2_gobs };
            const span = try block.span(bytes, geometry, target);
            if (span > value.plane_bytes[index] or desc.plane_offsets[index] > logical_bytes or span > logical_bytes - desc.plane_offsets[index]) return error.Bounds;
            const base = try std.math.add(u64, address, desc.plane_offsets[index]);
            try wire.extent(base, span, 49);
            return .{ .address = base, .block = block };
        }
        return error.Bounds;
    };
    const base = try std.math.add(u64, address, offset);
    try wire.extent(base, linear_span, 49);
    return .{ .address = base };
}
