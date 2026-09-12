// Host-only common-BO responses for the existing real Device transport test.
// Kernel owner and ABI paths have separate, actual-owner coverage.
const std = @import("std");
const a = @import("r4os").abi;
const heap_model = @import("gsp_buffer_test_model.zig").Model;
pub const Model = struct {
    const Slot = struct { reservation: a.GfxOwnedBufferReservation = .{}, live: bool = false, published: bool = false, reference: bool = false, imported: bool = false, claimed: bool = false };
    pub var slots: [2]Slot = @splat(.{});
    pub var charged: u64 = 0;
    pub var released: u32 = 0;
    pub var aborted: u32 = 0;
    var query: *const fn (*a.GfxDriverMemoryApi) callconv(.c) i32 = undefined;
    var fallback_release: u64 = 0;
    pub fn install(table: *a.DriverApi, scenario: []const u8) void {
        heap_model.install(table, scenario); query = table.gfx_memory_query.?;
        table.gfx_memory_query = memory; slots = @splat(.{}); charged = 0; released = 0; aborted = 0;
    }
    pub fn dispose(table: *a.DriverApi) void { heap_model.dispose(table); }
    pub fn is(name: []const u8) bool { return heap_model.is(name); }
    pub fn address(index: usize) u64 { return 0x10000000 + index * 0x10000000; }
    fn memory(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        if (query(out) != a.gfx_buffer_result_ok) return -1;
        fallback_release = out.buffer_release;
        out.size = @sizeOf(a.GfxDriverMemoryApi);
        out.buffer_reserve = @intFromPtr(&reserve); out.buffer_commit = @intFromPtr(&commit); out.buffer_abort = @intFromPtr(&abort);
        out.buffer_take_release = @intFromPtr(&take); out.buffer_finish_release = @intFromPtr(&finish); out.buffer_release = @intFromPtr(&drop);
        return a.gfx_buffer_result_ok;
    }
    fn reserve(d: *const a.GfxBufferDescriptor, cookie: u64, out: *a.GfxOwnedBufferReservation) callconv(.c) i32 {
        std.debug.assert(d.location == 1 and d.adapter_id == 0x01000000 and d.device_generation != 0 and d.driver_owner == 0 and d.usage == 12 and d.alignment == 65536);
        if (is("vram_budget")) return a.gfx_buffer_error_budget;
        for (&slots, 0..) |*slot, i| if (!slot.live) {
            const bytes = (d.byte_length + 65535) & ~@as(u64, 65535);
            out.* = .{ .buffer = .{ .id = @intCast(801+i), .generation = 601 }, .reference = .{ .id = @intCast(811+i), .generation = 701 },
                .allocation_bytes = bytes, .cookie = cookie, .device_generation = d.device_generation, .driver_generation = 0x200000003,
                .adapter_id = d.adapter_id, .driver_owner = 7 };
            slot.* = .{ .reservation = out.*, .live = true }; charged += bytes;
            return a.gfx_buffer_result_ok;
        };
        return a.gfx_buffer_error_capacity;
    }
    fn selected(r: a.GfxOwnedBufferReservation) *Slot {
        for (&slots) |*slot| if (slot.live and std.meta.eql(slot.reservation, r)) return slot;
        unreachable;
    }
    fn commit(r: *const a.GfxOwnedBufferReservation, out: *a.GfxBufferReference) callconv(.c) i32 {
        const slot = selected(r.*);
        std.debug.assert(!slot.published);
        if (is("vram_commit")) return a.gfx_buffer_error_closed;
        slot.published = true; slot.reference = true;
        out.* = .{ .buffer = r.buffer, .reference = r.reference };
        return a.gfx_buffer_result_ok;
    }
    fn abort(r: *const a.GfxOwnedBufferReservation, quiesced: u32) callconv(.c) i32 {
        const slot = selected(r.*);
        std.debug.assert(!slot.published and quiesced == 1);
        charged -= r.allocation_bytes; slot.live = false; aborted += 1;
        return a.gfx_buffer_result_ok;
    }
    fn drop(reference: *const a.GfxBufferHandle) callconv(.c) i32 {
        for (&slots) |*slot| if (slot.live and std.meta.eql(slot.reservation.reference, reference.*)) {
            std.debug.assert(slot.reference and slot.published); slot.reference = false; return a.gfx_buffer_result_ok;
        };
        const call: *const fn (*const a.GfxBufferHandle) callconv(.c) i32 = @ptrFromInt(fallback_release); return call(reference);
    }
    fn ticket(slot: Slot) a.GfxOwnedBufferRelease {
        const r = slot.reservation;
        return .{ .buffer = r.buffer, .cookie = r.cookie, .byte_length = r.allocation_bytes, .attempt = 0x100000001,
            .device_generation = r.device_generation, .driver_generation = r.driver_generation, .adapter_id = r.adapter_id, .driver_owner = r.driver_owner };
    }
    fn take(adapter: u32, epoch: u64, out: *a.GfxOwnedBufferRelease) callconv(.c) i32 {
        for (&slots) |*slot| if (slot.live and slot.published and !slot.reference and !slot.imported and !slot.claimed) {
            std.debug.assert(slot.reservation.adapter_id == adapter and slot.reservation.device_generation == epoch);
            slot.claimed = true; out.* = ticket(slot.*); return a.gfx_buffer_result_ok;
        };
        return a.gfx_buffer_error_busy;
    }
    fn finish(r: *const a.GfxOwnedBufferRelease, quiesced: u32) callconv(.c) i32 {
        for (&slots) |*slot| if (slot.live and std.meta.eql(ticket(slot.*), r.*)) {
            std.debug.assert(slot.claimed and !slot.reference and !slot.imported and quiesced == 1);
            if (is("vram_finish")) return a.gfx_buffer_error_busy;
            slot.live = false; charged -= r.byte_length; released += 1; return a.gfx_buffer_result_ok;
        };
        unreachable;
    }
};
