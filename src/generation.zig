//! Independent chip, firmware, display, copy and render identities.
//! Profiles describe an implementation, never observed hardware qualification.
//! Source mapping: NVIDIA570.144 g_kernel_gsp_nvoc.c and nvkms-hal.c;
//! original headers and exact source hashes are retained in GFX/0.79.33.
const std = @import("std");
pub const Family = enum { turing, ampere, ada, blackwell };
pub const Boot = enum { tu102, tu116, ga102, ad102, gb202_fsp };
pub const Status = enum { unavailable, implementation_ready, hardware_verified };
pub const Display = struct { root: u32, core: u32, window: u32, immediate: u32, cursor: u32 };
pub const Profile = struct {
    id: u16,
    name: []const u8,
    family: Family,
    boot: Boot,
    display: Display,
    copy: [2]u32,
    render: u32,
    sm: u16,
    status: Status,
    restriction: []const u8,
    pub fn computeClass(self: *const Profile) u32 {
        return switch (self.sm) { 86 => 0xc7c0, 89 => 0xc9c0, else => 0 };
    }
};
fn display(root: u32, window: u32) Display {
    return .{ .root = root | 0x70, .core = root | 0x7d, .window = window | 0x7e,
        .immediate = window | 0x7b, .cursor = window | 0x7a };
}
fn row(id: u16, name: []const u8, family: Family, boot: Boot, scanout: Display, copy: [2]u32,
    render: u32, sm: u16, status: Status, restriction: []const u8) Profile
{
    return .{ .id=id, .name=name, .family=family, .boot=boot, .display=scanout,
        .copy=copy, .render=render, .sm=sm, .status=status, .restriction=restriction };
}
const ampere_note = "experimental native only; physical firmware/display/render/reset qualification open";
const turing_note = "native direct-HS/TU102 boot not integrated; C5B5 and SM75 encoding available";
const ada_note = "experimental native only; physical firmware/display/render/reset qualification open";
const blackwell_note = "native FSP/FMC bootstrap and CA display not integrated; linear CE and SM120 encoding available";
pub const profiles = [_]Profile{
    row(0x162,"TU102",.turing,.tu102,display(0xc500,0xc500),.{0xc5b5,0},0xc597,75,.unavailable,turing_note),
    row(0x164,"TU104",.turing,.tu102,display(0xc500,0xc500),.{0xc5b5,0},0xc597,75,.unavailable,turing_note),
    row(0x166,"TU106",.turing,.tu102,display(0xc500,0xc500),.{0xc5b5,0},0xc597,75,.unavailable,turing_note),
    row(0x167,"TU117",.turing,.tu116,display(0xc500,0xc500),.{0xc5b5,0},0xc597,75,.unavailable,turing_note),
    row(0x168,"TU116",.turing,.tu116,display(0xc500,0xc500),.{0xc5b5,0},0xc597,75,.unavailable,turing_note),
    row(0x172,"GA102",.ampere,.ga102,display(0xc600,0xc600),.{0xc7b5,0xc6b5},0xc797,86,.implementation_ready,ampere_note),
    row(0x173,"GA103",.ampere,.ga102,display(0xc600,0xc600),.{0xc7b5,0xc6b5},0xc797,86,.implementation_ready,ampere_note),
    row(0x174,"GA104",.ampere,.ga102,display(0xc600,0xc600),.{0xc7b5,0xc6b5},0xc797,86,.implementation_ready,ampere_note),
    row(0x176,"GA106",.ampere,.ga102,display(0xc600,0xc600),.{0xc7b5,0xc6b5},0xc797,86,.implementation_ready,ampere_note),
    row(0x177,"GA107",.ampere,.ga102,display(0xc600,0xc600),.{0xc7b5,0xc6b5},0xc797,86,.implementation_ready,ampere_note),
    row(0x192,"AD102",.ada,.ad102,display(0xc700,0xc600),.{0xc7b5,0xc6b5},0xc997,89,.implementation_ready,ada_note),
    row(0x193,"AD103",.ada,.ad102,display(0xc700,0xc600),.{0xc7b5,0xc6b5},0xc997,89,.implementation_ready,ada_note),
    row(0x194,"AD104",.ada,.ad102,display(0xc700,0xc600),.{0xc7b5,0xc6b5},0xc997,89,.implementation_ready,ada_note),
    row(0x196,"AD106",.ada,.ad102,display(0xc700,0xc600),.{0xc7b5,0xc6b5},0xc997,89,.implementation_ready,ada_note),
    row(0x197,"AD107",.ada,.ad102,display(0xc700,0xc600),.{0xc7b5,0xc6b5},0xc997,89,.implementation_ready,ada_note),
    row(0x1b2,"GB202",.blackwell,.gb202_fsp,display(0xca00,0xca00),.{0xcab5,0xc9b5},0xcd97,120,.unavailable,blackwell_note),
    row(0x1b3,"GB203",.blackwell,.gb202_fsp,display(0xca00,0xca00),.{0xcab5,0xc9b5},0xcd97,120,.unavailable,blackwell_note),
    row(0x1b5,"GB205",.blackwell,.gb202_fsp,display(0xca00,0xca00),.{0xcab5,0xc9b5},0xcd97,120,.unavailable,blackwell_note),
    row(0x1b6,"GB206",.blackwell,.gb202_fsp,display(0xca00,0xca00),.{0xcab5,0xc9b5},0xcd97,120,.unavailable,blackwell_note),
    row(0x1b7,"GB207",.blackwell,.gb202_fsp,display(0xca00,0xca00),.{0xcab5,0xc9b5},0xcd97,120,.unavailable,blackwell_note),
};
pub fn get(id: u16) ?*const Profile {
    for (&profiles) |*profile| if (profile.id == id) return profile;
    return null;
}
/// Shared GA102 HALs, assets and native engine methods have a complete owner.
/// Callers still validate their actual PCI/BAR/firmware/class/receipt evidence.
pub fn ga10x(id: u16) bool {
    const profile = get(id) orelse return false;
    return profile.family == .ampere and profile.boot == .ga102 and profile.status == .implementation_ready;
}
/// Ada shares the GA102 PKC/Falcon and GSP transport register HALs, but
/// selects its own boot assets, C77D display core and SM89 graphics class.
pub fn ga102Hal(id: u16) bool {
    const profile = get(id) orelse return false;
    return profile.boot == .ga102 or profile.boot == .ad102;
}
pub fn bootId(boot0: u32) u16 { return @intCast(((boot0 >> 20) & 0x1ff) | ((boot0 & 0x100) << 1)); }
comptime {
    for (profiles, 0..) |profile, index| {
        if (profile.restriction.len == 0) @compileError("Every profile requires its exact qualification boundary");
        for (profiles[0..index]) |previous| if (profile.id == previous.id or std.mem.eql(u8,profile.name,previous.name))
            @compileError("Duplicate NVIDIA chip profile");
    }
}
