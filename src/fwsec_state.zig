// GA106 pre-start observations, not a reset, ownership or execution grant.
// Register facts: pinned NVIDIA 570.144 and Nouveau's nvkm/falcon/base.c.
const load = @import("fwsec_load.zig");
pub const Error = error{ MissingRegister, ProtectedRegister, Capacity, Framebuffer, WprRange };
pub const Register = enum(u4) { hwcfg, hwcfg2, cpuctl, dmactl, dmacmd, engine, riscv_cpuctl, bcr, fb_mb, wpr_lo, wpr_hi, display_fuse, vga };
pub const addresses = [_]u32{ 0x110108, 0x1100f4, 0x110100, 0x11010c, 0x110118, 0x1103c0, 0x111388, 0x111668, 0x1183a4, 0x1fa824, 0x1fa828, 0x820c04, 0x625f04 };
pub const pages = [_]u32{ 0x110000, 0x111000, 0x118000, 0x1fa000, 0x820000, 0x625000 };

pub fn readable(value: u32) bool {
    return value != 0xffffffff and value & 0xffff0000 != 0xbadf0000;
}
pub const Raw = struct {
    values: [addresses.len]u32 = @splat(0),
    present: u16 = 0,

    pub fn has(self: *const Raw, reg: Register) bool {
        return self.present & (@as(u16, 1) << @intFromEnum(reg)) != 0;
    }
    pub fn put(self: *Raw, reg: Register, value: u32) void {
        self.values[@intFromEnum(reg)] = value;
        self.present |= @as(u16, 1) << @intFromEnum(reg);
    }
    pub fn get(self: *const Raw, reg: Register) Error!u32 {
        if (!self.has(reg)) return error.MissingRegister;
        const value = self.values[@intFromEnum(reg)];
        if (!readable(value)) return error.ProtectedRegister;
        return value;
    }
    pub fn riscvEnabled(self: *const Raw) bool {
        return (self.get(.hwcfg2) catch return false) & (1 << 10) != 0;
    }
    pub fn displayEnabled(self: *const Raw) bool {
        return (self.get(.display_fuse) catch return false) & 1 == 0;
    }
};

pub const State = struct {
    imem_bytes: u32,
    dmem_bytes: u32,
    reset_asserted: bool,
    // NVIDIA documents a hardware bug: this bit is only a hint, not a gate.
    reset_ready_hint: bool,
    scrubbing: bool,
    falcon_halted: bool,
    dma_idle: bool,
    dma_full: bool,
    riscv_enabled: bool,
    riscv_selected: bool,
    riscv_active: bool,
    riscv_halted: bool,
    bcr_valid: bool,
    fb_bytes: u64,
    wpr_up: bool,
    // Address fields in 4-KB units; HI is not a half-open range end.
    wpr_lo: u64,
    wpr_hi: u64,
    display_enabled: bool,
    vga_valid: bool,
    vga_base: u64,
    vga_relocation_needed: bool,
    // Conservative upper bound, retaining the CURRENT VGA workspace.
    // No GSP/FRTS allocation may be inferred from this observation.
    reserved_base: u64,

    pub fn checkTcm(self: *const State, plan: *const load.Plan) Error!void {
        if (plan.imem.bytes == 0 or plan.dmem.bytes == 0 or
            @as(u64, plan.imem.destination) + plan.imem.bytes > self.imem_bytes or
            @as(u64, plan.dmem.destination) + plan.dmem.bytes > self.dmem_bytes) return error.Capacity;
    }
};

pub fn decode(raw: *const Raw) Error!State {
    const hwcfg = try raw.get(.hwcfg);
    const hwcfg2 = try raw.get(.hwcfg2);
    const cpuctl = try raw.get(.cpuctl);
    _ = try raw.get(.dmactl);
    const dmacmd = try raw.get(.dmacmd);
    const engine = try raw.get(.engine);
    const imem = (hwcfg & 0x1ff) << 8;
    const dmem = (hwcfg & 0x3fe00) >> 1; // Nouveau nvkm_falcon_oneinit.
    if (imem == 0 or dmem == 0) return error.Capacity;
    const riscv = raw.riscvEnabled();
    const riscv_cpu = if (riscv) try raw.get(.riscv_cpuctl) else 0;
    const bcr = if (riscv) try raw.get(.bcr) else 0;
    const fb = @as(u64, try raw.get(.fb_mb)) << 20;
    // Both the VGA and WPR address fields span 40 bits. BAR1 is an aperture,
    // never a substitute for the devinit-published usable framebuffer size.
    if (fb < 0x100000 or fb > (@as(u64, 1) << 40)) return error.Framebuffer;
    const wpr_lo = @as(u64, (try raw.get(.wpr_lo)) >> 4) << 12;
    const wpr_hi = @as(u64, (try raw.get(.wpr_hi)) >> 4) << 12;
    const wpr_up = wpr_hi != 0;
    if (wpr_up and (wpr_lo > wpr_hi or wpr_hi >= fb)) return error.WprRange;
    _ = try raw.get(.display_fuse);
    const display = raw.displayEnabled();
    const vga = if (display) try raw.get(.vga) else 0;
    const vga_valid = vga & 8 != 0;
    const vga_base = @as(u64, vga >> 8) << 16;
    if (vga_valid and vga_base >= fb) return error.Framebuffer;
    // GA106 selects the no-MMU-lock HAL. Do not read GA100 lock registers.
    return .{
        .imem_bytes = imem,
        .dmem_bytes = dmem,
        .reset_asserted = engine & 1 != 0,
        .reset_ready_hint = hwcfg2 & 0x80000000 != 0,
        .scrubbing = hwcfg2 & 0x1000 != 0,
        .falcon_halted = cpuctl & 0x10 != 0,
        .dma_idle = dmacmd & 2 != 0,
        .dma_full = dmacmd & 1 != 0,
        .riscv_enabled = riscv,
        .riscv_selected = bcr & 0x10 != 0,
        .bcr_valid = bcr & 1 != 0,
        .riscv_active = riscv_cpu & 0x80 != 0,
        .riscv_halted = riscv_cpu & 0x10 != 0,
        .fb_bytes = fb,
        .wpr_up = wpr_up,
        .wpr_lo = wpr_lo,
        .wpr_hi = wpr_hi,
        .display_enabled = display,
        .vga_valid = vga_valid,
        .vga_base = vga_base,
        .vga_relocation_needed = vga_valid and vga_base < fb - 0x100000,
        .reserved_base = if (vga_valid) vga_base else fb - 0x100000,
    };
}
