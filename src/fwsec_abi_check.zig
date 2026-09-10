// Explicit host preparation step only; never part of NVIDIA.R4D.
const preparation = @import("fwsec_prepare.zig");
extern fn r4nv_fwsec_abi_check([*]const u8, usize, c_uint, [*]const u8, usize, c_uint) c_int;
pub fn main() !void {
    const sb = try preparation.commandBytes(.sb);
    const frts = try preparation.commandBytes(.{ .frts = 0x123456000 });
    if (r4nv_fwsec_abi_check(&sb.data, sb.length, sb.id, &frts.data, frts.length, frts.id) != 0) return error.OriginalAbiMismatch;
}
