// Resident snapshot owner for the existing boot-check path. The kernel holds
// every CPU writer during capture and retains an immutable BO read lease.
// This probe never latches device effects and never claims GPU recovery.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub const Error = error{ Busy, Unsupported, Display, Buffer, Hold, Map, Stale };
pub const Report = struct { boot: a.GfxNativeBootInfo, hold_generation: u64, bytes: u64, sha256: [32]u8 };
pub const Snapshot = struct {
    memory: ?r4os.driver_memory.Context = null,
    display: ?r4os.driver_display.Context = null,
    reference: a.GfxBufferReference = .{},
    read: a.GfxBufferMap = .{},
    held_generation: u64 = 0,
    last_status: i32 = 0,

    pub fn capture(self: *Snapshot, ctx: *const r4os.r4dev.DriverContext, adapter: u32) Error!Report {
        if (self.reference.reference.id != 0 or self.held_generation != 0 or self.read.lease.id != 0) return error.Busy;
        const memory = ctx.memory() orelse return error.Unsupported;
        const display = ctx.graphicsDisplay() orelse return error.Unsupported;
        if (display.table.size < @offsetOf(a.GfxDriverDisplayApi, "boot_finish") + 8 or
            display.table.boot_hold == 0 or display.table.boot_finish == 0) return error.Unsupported;
        self.memory = memory;
        self.display = display;
        var boot: a.GfxNativeBootInfo = .{};
        self.last_status = display.bootInfo(&boot);
        if (self.last_status != a.gfx_output_ok or boot.generation == 0 or boot.physical_address == 0 or boot.state != 1 or boot.policy != 0) return error.Display;
        const bytes = @as(u64, boot.pitch) * boot.height;
        if (bytes == 0 or bytes > boot.byte_length or bytes > 256 * 1024 * 1024) return error.Display;
        self.last_status = memory.bufferCreate(&.{ .byte_length = bytes, .alignment = 4096,
            .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write }, &self.reference);
        if (self.last_status != a.gfx_buffer_result_ok) return error.Buffer;
        var state: a.GfxNativeState = .{};
        self.last_status = display.bootHold(&.{ .adapter_id = adapter, .generation = boot.generation,
            .reference = self.reference.reference, .restore_callback = @intFromPtr(&refuseRecovery) }, &state);
        // A handled capture/cleanup failure can still retain the real hold.
        if (state.retained != 0) self.held_generation = state.generation;
        if (self.last_status != a.gfx_output_ok or state.outcome != a.gfx_output_outcome_validated or state.retained != 1 or state.generation == 0) return error.Hold;
        self.last_status = memory.bufferMap(&self.reference.reference, a.gfx_buffer_map_read, 0, bytes, &self.read);
        if (self.last_status != a.gfx_buffer_result_ok or self.read.lease.id == 0 or self.read.cpu_address == 0) return error.Map;
        var current: a.GfxNativeBootInfo = .{};
        self.last_status = display.bootInfo(&current);
        if (self.last_status != a.gfx_output_ok or current.state != 2 or current.generation != boot.generation or
            current.physical_address != boot.physical_address or current.byte_length != boot.byte_length or
            current.width != boot.width or current.height != boot.height or current.pitch != boot.pitch) return error.Stale;
        var hash: [32]u8 = undefined;
        const data: [*]const u8 = @ptrFromInt(self.read.cpu_address);
        std.crypto.hash.sha2.Sha256.hash(data[0..bytes], &hash, .{});
        return .{ .boot = boot, .hold_generation = state.generation, .bytes = bytes, .sha256 = hash };
    }

    // The actual descriptor remains in this resident owner on every failed
    // cleanup. Shutdown retries this same order through the cached tables.
    pub fn close(self: *Snapshot) bool {
        const memory = self.memory orelse return self.reference.reference.id == 0 and self.held_generation == 0;
        if (self.read.lease.id != 0) {
            self.last_status = memory.bufferUnmap(&self.read.lease);
            if (self.last_status != a.gfx_buffer_result_ok) return false;
            self.read = .{};
        }
        if (self.held_generation != 0) {
            const display = self.display orelse return false;
            var state: a.GfxNativeState = .{};
            self.last_status = display.bootFinish(self.held_generation, 0, &state);
            if (self.last_status != a.gfx_output_ok or state.retained != 0 or state.outcome != a.gfx_output_outcome_old_preserved) return false;
            self.held_generation = 0;
        }
        if (self.reference.reference.id != 0) {
            self.last_status = memory.bufferRelease(&self.reference.reference);
            if (self.last_status != a.gfx_buffer_result_ok) return false;
            self.reference = .{};
        }
        self.* = .{};
        return true;
    }
};

fn refuseRecovery(_: u64, _: u64, _: *const a.GfxNativeBootInfo) callconv(.c) i32 {
    // No device effect is permitted by this diagnostic owner. An unexpected
    // recovery invocation must retain ownership, never fabricate quiescence.
    return 0;
}
