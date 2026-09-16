// C56F GPFIFO and completion encoding, from the pinned NVIDIA 570.144
// src/common/sdk/nvidia/inc/class/clc56f.h (MIT). Original R4OS implementation.
// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const wire = @import("gsp_copy_wire.zig");
pub const Error = wire.Error;
pub const ring_entries: u32 = 512;
// Keep one empty ring slot and one driver-owned completion entry. A group of
// incomplete methods is never split across publications by this producer.
pub const capacity: usize = ring_entries - 2;
pub const Push = struct {
    address: u64,
    bytes: u32,
    incomplete: bool = false,
    no_prefetch: bool = false,
};
pub fn entry(push: Push) Error![2]u32 {
    if (push.bytes == 0 or push.bytes >= 1 << 23 or (push.address | push.bytes) & 3 != 0)
        return error.Bounds;
    try wire.extent(push.address, push.bytes, 40);
    // External NVK pushes are subroutine-level GPFIFO entries. SYNC_WAIT
    // suppresses prefetch for pushbuffers modified by earlier GPU commands.
    return .{ @truncate(push.address), @as(u32, @intCast(push.address >> 32)) |
        (1 << 9) | ((push.bytes / 4) << 10) | (@as(u32, @intFromBool(push.no_prefetch)) << 31) };
}
pub fn validate(pushes: []const Push) Error!void {
    if (pushes.len > capacity) return error.Bounds;
    if (pushes.len != 0 and pushes[pushes.len - 1].incomplete) return error.Bounds;
    for (pushes) |push| _ = try entry(push);
}
pub const completion_words = 13;
pub fn completion(address: u64, point: u32) Error![completion_words]u32 {
    if (point == 0 or address & 3 != 0) return error.Bounds;
    try wire.extent(address, 4, 40);
    // Complete preceding engine work, order system-visible writes, then
    // release one private 32-bit value. GP_GET/USERD are never completion.
    // This is the explicit WFI + SYS_MEMBAR ordering of the pinned host HAL;
    // it does not replace Vulkan's resource/cache barriers inside the batch.
    return .{
        wire.inc(0x78, 1), 1,                 // WFI_SCOPE_ALL
        wire.inc(0x28, 4), 0, 0, 0, 5 << 27, // MEM_OP_D_OPERATION_MEMBAR
        wire.inc(0x5c, 5), @truncate(address), @intCast(address >> 32), point, 0,
        1, // SEM_EXECUTE_RELEASE, 32-bit payload, no timestamp; WFI was explicit.
    };
}
