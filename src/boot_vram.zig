//! Resident GA106 boot/VGA snapshot owner for the existing boot-check.
//! Actual SDK BO/MMIO leases and the common boot-display hold remain retained
//! through failure. The only permitted device write is BAR0_WINDOW; this
//! recovery callback must never be reused after firmware/DMA/scanout effects.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const identity = @import("identity.zig");
const display = @import("boot_display.zig");
const probe = @import("fwsec_state_probe.zig");
const state = @import("fwsec_state.zig");
const pramin = @import("pramin.zig");
const bar0 = @import("bar0.zig");
const scanout = @import("boot_scanout.zig");
pub const Report = struct { boot: display.Report, range: pramin.Range, sha256: [32]u8, window_original: u32, window_restored: bool, window_writes: u32 };
pub const Capture = struct {
    context: ?r4os.r4dev.DriverContext = null,
    snapshot: ?identity.Snapshot = null,
    chip: ?identity.Chip = null,
    observation: ?state.Raw = null,
    borrower: usize = 0,
    mapping_owner: usize = 0,
    context_owner: usize = 0,
    ready: bool = false,
    boot: display.Snapshot = .{},
    preflight: probe.Capture = .{},
    scanout_probe: scanout.Capture = .{},
    scanout_original: ?scanout.Raw = null,
    memory: ?r4os.driver_memory.Context = null,
    clock: ?r4os.r4dev.DriverResourceContext = null,
    registers: bar0.Owner = .{},
    register_access: bar0.Lease = .{},
    reference: a.GfxBufferReference = .{},
    map: a.GfxBufferMap = .{},
    operation: ?pramin.Capture = null,
    original_boot: ?a.GfxNativeBootInfo = null,
    self_address: usize = 0,
    effects_latched: bool = false,
    window_writes: u32 = 0,
    last_status: i32 = 0,
    last_error: ?anyerror = null,

    /// Driver init/work owner, stable resident address; no IRQ or parallel
    /// native port may use this GPU while the common display hold is pending.
    pub fn capture(self: *Capture, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip) !Report {
        if (self.self_address != 0) return error.Busy;
        const bar = snapshot.bars[0];
        if (identity.decision(snapshot) != .identity_words_only or chip.id != 0x176 or
            bar.bytes < 0x821000 or bar.base > std.math.maxInt(u64) - bar.bytes) return error.Profile;
        self.self_address = @intFromPtr(self);
        errdefer |err| self.last_error = err;
        self.context = ctx.*;
        self.snapshot = snapshot.*;
        self.chip = chip;
        self.clock = ctx.resources() orelse return error.Api;
        self.memory = ctx.memory() orelse return error.Api;
        const adapter = 0x01000000 | (@as(u32, snapshot.pci.bus) << 8) | (@as(u32, snapshot.pci.device) << 3) | snapshot.pci.function;
        const boot = try self.boot.captureGuarded(ctx, adapter, .{ .context = @intFromPtr(self), .callback = recoverWindow });
        self.original_boot = boot.boot;
        const mapped = self.registers.open(ctx, snapshot, chip);
        self.last_status = self.registers.last_status;
        try mapped;
        try self.register_access.acquire(&self.registers, ctx, snapshot, chip);
        // Reobserve the complete supported preflight under the held display.
        const raw = try self.preflight.readShared(ctx, snapshot, chip, &self.registers);
        if (!self.preflight.close()) return error.Cleanup;
        const range = try pramin.workspace(chip.id, &raw);
        self.observation = raw;
        self.scanout_original = try self.readScanout();
        const boot0 = try read32(self, 0);
        const boot1 = try read32(self, 4);
        const observed = identity.chip(boot0, boot1) orelse return error.Profile;
        if (observed.id != chip.id or observed.revision != chip.revision) return error.Unstable;
        self.last_status = self.memory.?.bufferCreate(&.{ .byte_length = range.bytes, .alignment = 4096,
            .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write }, &self.reference);
        if (self.last_status != a.gfx_buffer_result_ok) return error.Buffer;
        self.last_status = self.memory.?.bufferMap(&self.reference.reference, a.gfx_buffer_map_write, 0, range.bytes, &self.map);
        if (self.last_status != a.gfx_buffer_result_ok or self.map.lease.id == 0 or self.map.cpu_address == 0 or
            self.map.byte_length != range.bytes or self.map.cpu_address > std.math.maxInt(u64) - @as(u64, range.bytes)) return error.Buffer;
        self.operation = try pramin.Capture.init(.{ .epoch = self.boot.held_generation, .deadline = try self.deadline(),
            .boot0 = boot0, .boot1 = boot1, .vga = try raw.get(.vga), .range = range });
        const output: [*]u8 = @ptrFromInt(self.map.cpu_address);
        while (!try self.operation.?.step(self.port(), output[0..range.bytes])) {}
        // Private reference: no importer is published between these leases.
        self.last_status = self.memory.?.bufferUnmap(&self.map.lease);
        if (self.last_status != a.gfx_buffer_result_ok) return error.Buffer;
        self.map = .{};
        self.last_status = self.memory.?.bufferMap(&self.reference.reference, a.gfx_buffer_map_read, 0, range.bytes, &self.map);
        if (self.last_status != a.gfx_buffer_result_ok or self.map.lease.id == 0 or self.map.cpu_address == 0 or
            self.map.byte_length != range.bytes or self.map.cpu_address > std.math.maxInt(u64) - @as(u64, range.bytes)) return error.Buffer;
        const data: [*]const u8 = @ptrFromInt(self.map.cpu_address);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data[0..range.bytes], &hash, .{});
        self.ready = true;
        return .{ .boot = boot, .range = range, .sha256 = hash, .window_original = self.operation.?.original.?,
            .window_restored = self.operation.?.restored, .window_writes = self.window_writes };
    }

    /// Fresh read-only admission while both snapshots and the common display
    /// hold are still owned. A borrower freezes this observation until release.
    pub fn reobserve(self: *Capture) !state.Raw {
        if (self.self_address != @intFromPtr(self) or !self.ready or self.borrower != 0 or
            self.boot.held_generation == 0 or self.map.lease.id == 0 or
            !self.register_access.valid() or self.registers.borrowedCount() != 1) return error.State;
        const operation = if (self.operation) |*value| value else return error.State;
        if (!operation.restored or operation.phase != .done or operation.failure != null) return error.State;
        const raw = try self.preflight.readShared(&self.context.?, &self.snapshot.?, self.chip.?, &self.registers);
        if (!self.preflight.close()) return error.Cleanup;
        const range = try pramin.workspace(self.chip.?.id, &raw);
        if (range.address != operation.options.range.address or range.bytes != operation.options.range.bytes or
            try raw.get(.vga) != operation.options.vga or try read32(self, 0) != operation.options.boot0 or
            try read32(self, 4) != operation.options.boot1 or try read32(self, pramin.window_register) != operation.original.?) return error.Unstable;
        self.observation = raw;
        try self.checkScanout();
        return raw;
    }

    fn readScanout(self: *Capture) !scanout.Raw {
        const raw = self.scanout_probe.readShared(&self.context.?, &self.snapshot.?, self.chip.?, &self.registers,
            .{ .context = self, .epoch = self.boot.held_generation, .generation = generation }) catch |err| {
            if (!self.scanout_probe.close()) return error.Cleanup;
            return err;
        };
        if (!self.scanout_probe.close()) return error.Cleanup;
        return raw;
    }
    fn checkScanout(self: *Capture) !void {
        const original = self.scanout_original orelse return error.State;
        if (!std.meta.eql(original, try self.readScanout())) return error.ScanoutChanged;
    }

    fn cast(raw: *anyopaque) *Capture { return @ptrCast(@alignCast(raw)); }
    fn port(self: *Capture) pramin.Port {
        return .{ .context = self, .generation = generation, .now_ns = nowNs, .retain = retain, .read32 = read32, .write32 = write32 };
    }
    fn generation(raw: *anyopaque) u64 {
        const self = cast(raw);
        return if (self.self_address == @intFromPtr(self)) self.boot.held_generation else 0;
    }
    fn nowNs(raw: *anyopaque) u64 { return if (cast(raw).clock) |clock| clock.nowNs() else std.math.maxInt(u64); }
    fn deadline(self: *Capture) !u64 {
        const now = nowNs(self);
        if (now == 0 or now == std.math.maxInt(u64)) return error.Clock;
        return std.math.add(u64, now, 5 * std.time.ns_per_s) catch error.Clock;
    }
    fn retain(raw: *anyopaque) !void {
        const self = cast(raw);
        try self.boot.latchEffects();
        self.effects_latched = true;
    }
    fn fence() void { asm volatile ("mfence" ::: .{ .memory = true }); }
    fn pointer(self: *Capture, address: u32) !*volatile u32 {
        if (self.self_address != @intFromPtr(self) or self.boot.held_generation == 0 or address & 3 != 0) return error.Stale;
        if (address != 0 and address != 4 and address != pramin.window_register and address != pramin.vga_register and
            !(address >= pramin.aperture and address < pramin.aperture + pramin.aperture_bytes)) return error.Register;
        const view = try self.register_access.view(address, 4);
        return @ptrFromInt(view.cpu_address);
    }
    fn read32(raw: *anyopaque, address: u32) !u32 {
        const pointer_value = try cast(raw).pointer(address);
        fence();
        const value = pointer_value.*;
        fence();
        return value;
    }
    fn write32(raw: *anyopaque, address: u32, value: u32) !void {
        const self = cast(raw);
        const operation = &(self.operation orelse return error.State);
        if (address != pramin.window_register or !self.effects_latched or operation.original == null or
            (value != operation.original.? and value != operation.selected)) return error.Register;
        const target = try self.pointer(address);
        const flush = try self.pointer(0);
        self.window_writes += 1;
        fence();
        target.* = value;
        fence();
        const boot0 = flush.*; // Drain the same device's posted register write.
        fence();
        if (boot0 != operation.options.boot0) return error.Unstable;
    }

    fn recoverWindow(raw: u64, generation_value: u64, boot: *const a.GfxNativeBootInfo) callconv(.c) i32 {
        const self: *Capture = @ptrFromInt(raw);
        if (self.self_address != raw or generation_value != self.boot.held_generation) return 0;
        const original = self.original_boot orelse return 0;
        if (boot.physical_address != original.physical_address or boot.byte_length != original.byte_length or
            boot.width != original.width or boot.height != original.height or boot.pitch != original.pitch) return 0;
        const operation = if (self.operation) |*value| value else return 0;
        const until = self.deadline() catch return 0;
        self.checkScanout() catch |err| { self.last_error = err; return 0; };
        operation.restore(self.port(), until) catch |err| { self.last_error = err; return 0; };
        // This owner can ONLY select/restore the CPU PRAMIN window. It has no
        // firmware command, device DMA binding or display-programming write.
        // The verified old window and untouched VGA/scanout admit pixel copy.
        return 1;
    }

    pub fn close(self: *Capture) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.borrower != 0 or self.mapping_owner != 0 or self.context_owner != 0) return false;
        if (!self.preflight.close()) return false;
        if (!self.scanout_probe.close()) return false;
        const own_borrow: usize = if (self.register_access.owner != null) 1 else 0;
        if (self.registers.borrowedCount() != own_borrow or
            (own_borrow != 0 and !self.register_access.valid())) return false;
        // Recovery needs all MMIO and snapshot leases. It runs before any
        // resource release; a failed callback retains the common display.
        if (!self.boot.close()) return false;
        if (self.memory) |memory| {
            if (self.map.lease.id != 0) {
                self.last_status = memory.bufferUnmap(&self.map.lease);
                if (self.last_status != a.gfx_buffer_result_ok) return false;
                self.map = .{};
            }
            if (self.reference.reference.id != 0) {
                self.last_status = memory.bufferRelease(&self.reference.reference);
                if (self.last_status != a.gfx_buffer_result_ok) return false;
                self.reference = .{};
            }
        }
        if (!self.register_access.release()) return false;
        if (!self.registers.close()) { self.last_status = self.registers.last_status; return false; }
        self.* = .{ .registers = .{ .serial = self.registers.serial } };
        return true;
    }
};
